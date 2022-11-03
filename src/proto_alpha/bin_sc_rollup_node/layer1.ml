(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs, <contact@nomadic-labs.com>               *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

open Configuration
open Protocol.Alpha_context
open Plugin
open Injector_common

(**

    Errors
    ======

*)
let synchronization_failure e =
  Format.eprintf
    "Error during synchronization: @[%a@]"
    Error_monad.(TzTrace.pp_print_top pp)
    e ;
  Lwt_exit.exit_and_raise 1

type error += Cannot_find_block of Block_hash.t

let () =
  register_error_kind
    ~id:"sc_rollup.node.cannot_find_block"
    ~title:"Cannot find block from L1"
    ~description:"A block couldn't be found from the L1 node"
    ~pp:(fun ppf hash ->
      Format.fprintf
        ppf
        "Block with hash %a was not found on the L1 node."
        Block_hash.pp
        hash)
    `Temporary
    Data_encoding.(obj1 (req "hash" Block_hash.encoding))
    (function Cannot_find_block hash -> Some hash | _ -> None)
    (fun hash -> Cannot_find_block hash)

(**

   State
   =====

*)

type block_hash = Block_hash.t

type block = Block of {predecessor : block_hash; level : int32}

let block_encoding =
  Data_encoding.(
    conv
      (fun (Block {predecessor; level}) -> (predecessor, level))
      (fun (predecessor, level) -> Block {predecessor; level})
      (obj2
         (req "predecessor" Block_hash.encoding)
         (req "level" Data_encoding.int32)))

type head = Head of {hash : block_hash; level : int32}

let head_encoding =
  Data_encoding.(
    conv
      (fun (Head {hash; level}) -> (hash, level))
      (fun (hash, level) -> Head {hash; level})
      (obj2 (req "hash" Block_hash.encoding) (req "level" Data_encoding.int32)))

module State = struct
  (* TODO: https://gitlab.com/tezos/tezos/-/issues/3433
     Check what the actual value of `reorganization_window_length`
     should be, and if we want to make it configurable.
  *)
  let reorganization_window_length = 10

  module Store = struct
    module Blocks = Store_utils.Make_append_only_map (struct
      let path = ["tezos"; "blocks"]

      let keep_last_n_entries_in_memory = reorganization_window_length

      type key = block_hash

      let string_of_key = Block_hash.to_b58check

      type value = block

      let value_encoding = block_encoding
    end)

    module Head = Store_utils.Make_mutable_value (struct
      let path = ["tezos"; "head"]

      type value = head

      let value_encoding = head_encoding
    end)

    module Levels = Store_utils.Make_updatable_map (struct
      let path = ["tezos"; "levels"]

      let keep_last_n_entries_in_memory = reorganization_window_length

      type key = int32

      let string_of_key = Int32.to_string

      type value = block_hash

      let value_encoding = Block_hash.encoding
    end)

    module ProcessedHashes = Store_utils.Make_append_only_map (struct
      let path = ["tezos"; "processed_blocks"]

      let keep_last_n_entries_in_memory = reorganization_window_length

      type key = block_hash

      let string_of_key = Block_hash.to_b58check

      type value = unit

      let value_encoding = Data_encoding.unit
    end)

    module LastProcessedHead = Store_utils.Make_mutable_value (struct
      let path = ["tezos"; "processed_head"]

      type value = head

      let value_encoding = head_encoding
    end)

    module Heads_seen_but_not_finalized = Store_utils.Make_mutable_value (struct
      let path = ["heads"; "not_finalized"]

      type value = head list

      let value_encoding = Data_encoding.list head_encoding
    end)
  end

  let last_seen_head = Store.Head.find

  let set_new_head = Store.Head.set

  let store_block = Store.Blocks.add

  let block_of_hash = Store.Blocks.get

  module Blocks_cache =
    Ringo_lwt.Functors.Make_opt
      ((val Ringo.(
              map_maker ~replacement:LRU ~overflow:Strong ~accounting:Precise))
         (Block_hash))

  let mark_processed_head store (Head {hash; _} as head) =
    let open Lwt_syntax in
    let* () = Store.ProcessedHashes.add store hash () in
    Store.LastProcessedHead.set store head

  let is_processed = Store.ProcessedHashes.mem

  let last_processed_head = Store.LastProcessedHead.find

  let hash_of_level = Store.Levels.get

  let set_hash_of_level = Store.Levels.add

  let set_heads_not_finalized store heads =
    Store.Heads_seen_but_not_finalized.set store heads

  let get_heads_not_finalized store =
    let open Lwt_syntax in
    let+ heads_opt = Store.Heads_seen_but_not_finalized.find store in
    Option.value ~default:[] heads_opt
end

type blocks_cache =
  Protocol_client_context.Alpha_block_services.block_info State.Blocks_cache.t

(**

   Chain events
   ============

*)

type chain_event =
  | SameBranch of {new_head : head; intermediate_heads : head list}
  | Rollback of {new_head : head}

let same_branch new_head intermediate_heads =
  SameBranch {new_head; intermediate_heads}

let rollback new_head = Rollback {new_head}

type t = {
  blocks_cache : blocks_cache;
  events : chain_event Lwt_stream.t;
  cctxt : Protocol_client_context.full;
  stopper : RPC_context.stopper;
  genesis_info : Sc_rollup.Commitment.genesis_info;
}

(**

   Helpers
   =======

*)

let genesis_hash =
  Block_hash.of_b58check_exn
    "BLockGenesisGenesisGenesisGenesisGenesisf79b5d1CoW2"

let chain_event_head_hash = function
  | SameBranch {new_head = Head {hash; _}; _}
  | Rollback {new_head = Head {hash; _}} ->
      hash

(** [blocks_of_heads base heads] given a list of successive heads
   connected to [base], returns an associative list mapping block hash
   to block. This list is only used for traversal, not lookup. The
   newer blocks come first in that list. *)
let blocks_of_heads base heads =
  let rec aux predecessor accu = function
    | [] -> accu
    | Head {hash; level} :: xs ->
        let block = Block {predecessor; level} in
        aux hash ((hash, block) :: accu) xs
  in
  aux base [] heads

(** [store_chain_event event] updates the persistent state to take a
    chain event into account. *)
let store_chain_event store base =
  let open Lwt_syntax in
  function
  | SameBranch {new_head = Head {hash; level} as head; intermediate_heads} ->
      let* () = Layer1_event.setting_new_head hash level in
      let* () = State.set_new_head store head in
      blocks_of_heads base (intermediate_heads @ [head])
      |> List.iter_s (fun (hash, (Block {level; _} as block)) ->
             let* () = State.store_block store hash block in
             State.set_hash_of_level store level hash)
  | Rollback {new_head = Head {hash; level} as base} ->
      let* () = Layer1_event.rollback hash level in
      State.set_new_head store base

(** [predecessors_of_blocks hashes] given a list of successive hashes,
    returns an associative list that associates a hash to its
    predecessor in this list. *)
let predecessors_of_blocks hashes =
  let rec aux next = function [] -> [] | x :: xs -> (next, x) :: aux x xs in
  match hashes with [] -> [] | x :: xs -> aux x xs

(** [get_predecessor block_hash] returns the predecessor block hash of
    some [block_hash] through an RPC to the Tezos node. To limit the
    number of RPCs, this information is requested for a batch of hashes
    and cached locally. *)
let get_predecessor =
  let max_cached = 1023 and max_read = 8 in
  let (module HMF : Ringo.MAP_MAKER) =
    Ringo.(map_maker ~replacement:FIFO ~overflow:Strong ~accounting:Precise)
  in
  let module HM = HMF (Block_hash) in
  let cache = HM.create max_cached in
  fun cctxt (chain : Tezos_shell_services.Chain_services.chain) ancestor ->
    match HM.find_opt cache ancestor with
    | Some pred -> Lwt.return (Some pred)
    | None -> (
        Tezos_shell_services.Chain_services.Blocks.list
          cctxt
          ~chain
          ~heads:[ancestor]
          ~length:max_read
          ()
        >>= function
        | Error e -> synchronization_failure e
        | Ok blocks -> (
            match blocks with
            | [ancestors] -> (
                List.iter
                  (fun (h, p) -> HM.replace cache h p)
                  (predecessors_of_blocks ancestors) ;
                match HM.find_opt cache ancestor with
                | None ->
                    (* We have just updated the cache with that information. *)
                    assert false
                | Some predecessor -> Lwt.return (Some predecessor))
            | _ -> Lwt.return None))

let get_predecessor_head cctxt chain (Head {level; hash}) =
  let open Lwt_syntax in
  let level = Int32.pred level in
  let+ hash' = get_predecessor cctxt chain hash in
  Option.map (fun hash' -> Head {level; hash = hash'}) hash'

(** [catch_up cctxt chain last_seen_head predecessor new_head]
   classifies the [new_head] (with some given [predecessor]) in two
   distinct categories:

   - If [new_head] has an ancestor which is the [last_seen_head],
   returns [SameBranch { new_head; intermediate_heads }] where
   [intermediate_heads] are the blocks between [last_seen_head] and
   [new_head] in order of increasing levels.

   - If [new_head] has an ancestor that is an ancestor [base] of
   [last_seen_head] then returns [Rollback { new_head }].

   This function also returns the block hash to which the current
   branch is rooted.
*)
let catch_up cctxt store chain last_seen_head new_head =
  let (Head {hash; _}) = last_seen_head in

  (* [heads] is the list of intermediate heads between
     the predecessor of [ancestor] and the [new_head]. [level]
     is the level of [ancestor]. *)
  let rec aux heads (Head {hash = ancestor_hash; level} as ancestor) =
    if Block_hash.equal ancestor_hash hash then
      (* We have reconnected to the last seen head. *)
      Lwt.return (ancestor_hash, [same_branch new_head heads])
    else
      State.is_processed store ancestor_hash >>= function
      | true ->
          (* We have reconnected to a previously known head.
             [new_head] and [last_seen_head] are not the same branch. *)
          Lwt.return
            (ancestor_hash, [rollback ancestor; same_branch new_head heads])
      | false -> (
          (* We have never seen this head. *)
          let heads = ancestor :: heads in
          get_predecessor cctxt chain ancestor_hash >>= function
          | Some ancestor' when Block_hash.(ancestor_hash <> ancestor') ->
              aux heads (Head {level = Int32.pred level; hash = ancestor'})
          | _ ->
              (* We have reconnected with the genesis head and it was
                 unknown until now. *)
              Lwt.return (ancestor_hash, [same_branch new_head heads]))
  in
  get_predecessor_head cctxt chain new_head >>= function
  | None ->
      (* [new_head] is the genesis head. It is not new. *)
      Lwt.return (genesis_hash, [])
  | Some predecessor -> aux [] predecessor

let chain_events cctxt store chain =
  let open Lwt_result_syntax in
  let on_head (hash, (block_header : Tezos_base.Block_header.t)) =
    let level = block_header.shell.level in
    let new_head = Head {hash; level} in
    let*! last_seen_head = State.last_seen_head store in
    let last_seen_head =
      match last_seen_head with
      | None -> Head {hash = genesis_hash; level = 0l}
      | Some last_seen_head -> last_seen_head
    in
    let*! base, events = catch_up cctxt store chain last_seen_head new_head in
    let*! () = List.iter_s (store_chain_event store base) events in
    Lwt.return events
  in
  let+ heads, stopper =
    Tezos_shell_services.Monitor_services.heads cctxt chain
  in
  (Lwt_stream.map_list_s on_head heads, stopper)

(** [discard_pre_origination_blocks info chain_events] filters [chain_events] in order to
    discard all heads that occur before the SC rollup origination. *)
let discard_pre_origination_blocks
    (genesis_info : Sc_rollup.Commitment.genesis_info) chain_events =
  let origination_level = Raw_level.to_int32 genesis_info.level in
  let at_or_after_origination event =
    match event with
    | SameBranch {new_head = Head {level; _} as new_head; intermediate_heads}
      when level >= origination_level ->
        let intermediate_heads =
          List.filter
            (fun (Head {level; _}) -> level >= origination_level)
            intermediate_heads
        in
        Some (SameBranch {new_head; intermediate_heads})
    | Rollback {new_head = Head {level; _}} when level >= origination_level ->
        Some event
    | _ -> None
  in
  Lwt_stream.filter_map at_or_after_origination chain_events

let rec connect ?(count = 0) ~delay cctxt genesis_info store =
  let open Lwt_syntax in
  let* () =
    if count = 0 then return_unit
    else
      let fcount = float_of_int (count - 1) in
      (* Randomized exponential backoff capped to 1.5h: 1.5^count * delay ± 50% *)
      let delay = delay *. (1.5 ** fcount) in
      let delay = min delay 3600. in
      let randomization_factor = 0.5 (* 50% *) in
      let delay =
        delay
        +. Random.float (delay *. 2. *. randomization_factor)
        -. (delay *. randomization_factor)
      in
      let* () = Event.wait_reconnect delay in
      Lwt_unix.sleep delay
  in
  let* res = chain_events cctxt store `Main in
  match res with
  | Ok (event_stream, stopper) ->
      let events = discard_pre_origination_blocks genesis_info event_stream in
      return_ok (events, stopper)
  | Error e ->
      let* () = Event.cannot_connect ~count e in
      connect ~delay ~count:(count + 1) cctxt genesis_info store

let start configuration (cctxt : Protocol_client_context.full) store =
  let open Lwt_result_syntax in
  let*! () = Layer1_event.starting () in
  let* kind =
    RPC.Sc_rollup.kind
      cctxt
      (cctxt#chain, cctxt#block)
      configuration.sc_rollup_address
      ()
  in
  let*! () = Event.rollup_exists ~addr:configuration.sc_rollup_address ~kind in
  let* genesis_info =
    RPC.Sc_rollup.genesis_info
      cctxt
      (cctxt#chain, cctxt#block)
      configuration.sc_rollup_address
  in
  let+ events, stopper =
    connect ~delay:configuration.reconnection_delay cctxt genesis_info store
  in
  ( {
      cctxt;
      events;
      blocks_cache = State.Blocks_cache.create 32;
      stopper;
      genesis_info;
    },
    kind )

let reconnect configuration l1_ctxt store =
  let open Lwt_result_syntax in
  let* events, stopper =
    connect
      ~count:1
      ~delay:configuration.reconnection_delay
      l1_ctxt.cctxt
      l1_ctxt.genesis_info
      store
  in
  return {l1_ctxt with events; stopper}

let current_head_hash store =
  let open Lwt_syntax in
  let+ head = State.last_seen_head store in
  Option.map (fun (Head {hash; _}) -> hash) head

let current_level store =
  let open Lwt_syntax in
  let+ head = State.last_seen_head store in
  Option.map (fun (Head {level; _}) -> level) head

let hash_of_level = State.hash_of_level

let level_of_hash store hash =
  let open Lwt_syntax in
  let* (Block {level; _}) = State.block_of_hash store hash in
  return level

let predecessor store (Head {hash; _}) =
  let open Lwt_syntax in
  let+ (Block {predecessor; _}) = State.block_of_hash store hash in
  predecessor

let processed_head (Head {hash; level}) =
  Layer1_event.new_head_processed hash level

let processed = function
  | SameBranch {new_head; intermediate_heads} ->
      List.iter_s processed_head (intermediate_heads @ [new_head])
  | Rollback {new_head} -> processed_head new_head

let mark_processed_head store head = State.mark_processed_head store head

let last_processed_head_hash store =
  let open Lwt_syntax in
  let+ info = State.last_processed_head store in
  Option.map (fun (Head {hash; _}) -> hash) info

let set_heads_not_finalized = State.set_heads_not_finalized

let get_heads_not_finalized = State.get_heads_not_finalized

(* We forget about the last seen heads that are not processed so that
   the rollup node can process them when restarted. Notice that this
   does prevent skipping heads when the node is interrupted in a bad
   way. *)

(* FIXME: https://gitlab.com/tezos/tezos/-/issues/3205

   More generally, the rollup node should be able to restart properly
   after an abnormal interruption at every point of its process.
   Currently, the state is not persistent enough and the processing is
   not idempotent enough to achieve that property. *)
let shutdown store =
  let open Lwt_syntax in
  let* last_processed_head = State.last_processed_head store in
  match last_processed_head with
  | None -> return_unit
  | Some head -> State.set_new_head store head

(** [fetch_tezos_block l1_ctxt hash] returns a block info given a block
    hash. Looks for the block in the blocks cache first, and fetches it from the
    L1 node otherwise. *)
let fetch_tezos_block l1_ctxt hash =
  trace (Cannot_find_block hash)
  @@ fetch_tezos_block
       l1_ctxt.cctxt
       hash
       ~find_in_cache:(State.Blocks_cache.find_or_replace l1_ctxt.blocks_cache)

(** Returns the reorganization of L1 blocks (if any) for [new_head]. *)
let get_tezos_reorg_for_new_head l1_state store new_head_hash =
  let open Lwt_result_syntax in
  let*! old_head_hash = current_head_hash store in
  match old_head_hash with
  | None ->
      (* No known tezos head, consider the new head as being on top of a previous
         tezos block. *)
      let+ new_head = fetch_tezos_block l1_state new_head_hash in
      {old_chain = []; new_chain = [new_head]}
  | Some old_head_hash ->
      tezos_reorg (fetch_tezos_block l1_state) ~old_head_hash ~new_head_hash
