(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

open Protocol
open Alpha_context

type lcc = {commitment : Sc_rollup.Commitment.Hash.t; level : Raw_level.t}

type 'a store = 'a Store.t

type 'a t = {
  cctxt : Protocol_client_context.full;
  dal_cctxt : Dal_node_client.cctxt;
  data_dir : string;
  l1_ctxt : Layer1.t;
  rollup_address : Sc_rollup.t;
  operators : Configuration.operators;
  genesis_info : Sc_rollup.Commitment.genesis_info;
  injector_retention_period : int;
  block_finality_time : int;
  kind : Sc_rollup.Kind.t;
  fee_parameters : Configuration.fee_parameters;
  protocol_constants : Constants.t;
  loser_mode : Loser_mode.t;
  store : 'a store;
  context : 'a Context.index;
  mutable lcc : lcc;
  mutable lpc : Sc_rollup.Commitment.t option;
}

type rw = [`Read | `Write] t

type ro = [`Read] t

let get_operator node_ctxt purpose =
  Configuration.Operator_purpose_map.find purpose node_ctxt.operators

let is_operator node_ctxt pkh =
  Configuration.Operator_purpose_map.exists
    (fun _ operator -> Signature.Public_key_hash.(operator = pkh))
    node_ctxt.operators

let get_fee_parameter node_ctxt purpose =
  Configuration.Operator_purpose_map.find purpose node_ctxt.fee_parameters
  |> Option.value ~default:(Configuration.default_fee_parameter ~purpose ())

(* TODO: https://gitlab.com/tezos/tezos/-/issues/2901
   The constants are retrieved from the latest tezos block. These constants can
   be different from the ones used at the creation at the rollup because of a
   protocol amendment that modifies some of them. This need to be fixed when the
   rollup nodes will be able to handle the migration of protocol.
*)
let retrieve_constants cctxt =
  Protocol.Constants_services.all cctxt (cctxt#chain, cctxt#block)

let get_last_cemented_commitment (cctxt : Protocol_client_context.full)
    rollup_address =
  let open Lwt_result_syntax in
  let+ commitment, level =
    Plugin.RPC.Sc_rollup.last_cemented_commitment_hash_with_level
      cctxt
      (cctxt#chain, `Head 0)
      rollup_address
  in
  {commitment; level}

let get_last_published_commitment (cctxt : Protocol_client_context.full)
    rollup_address operator =
  let open Lwt_result_syntax in
  let*! res =
    Plugin.RPC.Sc_rollup.staked_on_commitment
      cctxt
      (cctxt#chain, `Head 0)
      rollup_address
      operator
  in
  match res with
  | Error trace
    when TzTrace.fold
           (fun exists -> function
             | Environment.Ecoproto_error Sc_rollup_errors.Sc_rollup_not_staked
               ->
                 true
             | _ -> exists)
           false
           trace ->
      return_none
  | Error trace -> fail trace
  | Ok None -> return_none
  | Ok (Some (_staked_hash, staked_commitment)) -> return_some staked_commitment

let init (cctxt : Protocol_client_context.full) dal_cctxt ~data_dir mode
    Configuration.(
      {
        sc_rollup_address = rollup_address;
        sc_rollup_node_operators = operators;
        fee_parameters;
        loser_mode;
        _;
      } as configuration) =
  let open Lwt_result_syntax in
  let* store = Store.load mode Configuration.(default_storage_dir data_dir) in
  let*! context =
    Context.load mode (Configuration.default_context_dir data_dir)
  in
  let* l1_ctxt, kind = Layer1.start configuration cctxt in
  let publisher = Configuration.Operator_purpose_map.find Publish operators in
  let* protocol_constants = retrieve_constants cctxt
  and* lcc = get_last_cemented_commitment cctxt rollup_address
  and* lpc =
    Option.filter_map_es
      (get_last_published_commitment cctxt rollup_address)
      publisher
  in
  return
    {
      cctxt;
      dal_cctxt;
      data_dir;
      l1_ctxt;
      rollup_address;
      operators;
      genesis_info = l1_ctxt.Layer1.genesis_info;
      lcc;
      lpc;
      kind;
      injector_retention_period = 0;
      block_finality_time = 2;
      fee_parameters;
      protocol_constants;
      loser_mode;
      store;
      context;
    }

let close {cctxt; store; context; l1_ctxt; _} =
  let open Lwt_result_syntax in
  let message = cctxt#message in
  let*! () = message "Shutting down L1@." in
  let*! () = Layer1.shutdown l1_ctxt in
  let*! () = message "Closing context@." in
  let*! () = Context.close context in
  let*! () = message "Closing store@." in
  let* () = Store.close store in
  return_unit

let checkout_context node_ctxt block_hash =
  let open Lwt_result_syntax in
  let* l2_header =
    Store.L2_blocks.header node_ctxt.store.l2_blocks block_hash
  in
  let*? context_hash =
    match l2_header with
    | None ->
        error (Sc_rollup_node_errors.Cannot_checkout_context (block_hash, None))
    | Some {context; _} -> ok context
  in
  let*! ctxt = Context.checkout node_ctxt.context context_hash in
  match ctxt with
  | None ->
      tzfail
        (Sc_rollup_node_errors.Cannot_checkout_context
           (block_hash, Some context_hash))
  | Some ctxt -> return ctxt

let metadata node_ctxt =
  let address = node_ctxt.rollup_address in
  let origination_level = node_ctxt.genesis_info.Sc_rollup.Commitment.level in
  Sc_rollup.Metadata.{address; origination_level}

let dal_enabled node_ctxt =
  node_ctxt.protocol_constants.parametric.dal.feature_enable

let readonly (node_ctxt : _ t) =
  {
    node_ctxt with
    store = Store.readonly node_ctxt.store;
    context = Context.readonly node_ctxt.context;
  }

type 'a delayed_write = ('a, rw) Delayed_write_monad.t

(** Abstraction over store  *)

let trace_lwt_with x =
  Format.kasprintf
    (fun s p -> trace (Exn (Failure s)) @@ protect @@ fun () -> p >>= return)
    x

let trace_lwt_result_with x =
  Format.kasprintf
    (fun s p -> trace (Exn (Failure s)) @@ protect @@ fun () -> p)
    x

let hash_of_level_opt {store; cctxt; _} level =
  let open Lwt_result_syntax in
  let* hash = Store.Levels_to_hashes.find store.levels_to_hashes level in
  match hash with
  | Some hash -> return_some hash
  | None ->
      let*! hash =
        Tezos_shell_services.Shell_services.Blocks.hash
          cctxt
          ~chain:cctxt#chain
          ~block:(`Level level)
          ()
      in
      return (Result.to_option hash)

let hash_of_level node_ctxt level =
  let open Lwt_result_syntax in
  let* hash = hash_of_level_opt node_ctxt level in
  match hash with
  | Some h -> return h
  | None -> failwith "Cannot retrieve hash of level %ld" level

let level_of_hash {l1_ctxt; store; _} hash =
  let open Lwt_result_syntax in
  let* l2_header = Store.L2_blocks.header store.l2_blocks hash in
  match l2_header with
  | Some {level; _} -> return (Raw_level.to_int32 level)
  | None ->
      let+ {level; _} = Layer1.fetch_tezos_shell_header l1_ctxt hash in
      level

let save_level {store; _} Layer1.{hash; level} =
  Store.Levels_to_hashes.add store.levels_to_hashes level hash

let save_l2_head {store; _} (head : Sc_rollup_block.t) =
  let open Lwt_result_syntax in
  let head_info = {head with header = (); content = ()} in
  let* () =
    Store.L2_blocks.append
      store.l2_blocks
      ~key:head.header.block_hash
      ~header:head.header
      ~value:head_info
  in
  Store.L2_head.write store.l2_head head

let is_processed {store; _} head = Store.L2_blocks.mem store.l2_blocks head

let last_processed_head_opt {store; _} = Store.L2_head.read store.l2_head

let mark_finalized_head {store; _} head_hash =
  let open Lwt_result_syntax in
  let* block = Store.L2_blocks.read store.l2_blocks head_hash in
  match block with
  | None -> return_unit
  | Some (block_info, header) ->
      let block = {block_info with header} in
      Store.Last_finalized_head.write store.last_finalized_head block

let get_finalized_head_opt {store; _} =
  Store.Last_finalized_head.read store.last_finalized_head

(* TODO: https://gitlab.com/tezos/tezos/-/issues/4532
   Make this logarithmic, by storing pointers to muliple predecessor and
   by dichotomy. *)
let block_before {store; _} tick =
  let open Lwt_result_syntax in
  let* head = Store.L2_head.read store.l2_head in
  match head with
  | None -> return_none
  | Some head ->
      let rec search block_hash =
        let* block = Store.L2_blocks.read store.l2_blocks block_hash in
        match block with
        | None -> failwith "Missing block %a" Block_hash.pp block_hash
        | Some (info, header) ->
            if Sc_rollup.Tick.(info.initial_tick <= tick) then
              return_some {info with header}
            else search header.predecessor
      in
      search head.header.block_hash

let get_l2_block {store; _} block_hash =
  let open Lwt_result_syntax in
  let* block = Store.L2_blocks.read store.l2_blocks block_hash in
  match block with
  | None ->
      failwith "Could not retrieve L2 block for %a" Block_hash.pp block_hash
  | Some (info, header) -> return {info with Sc_rollup_block.header}

let find_l2_block {store; _} block_hash =
  let open Lwt_result_syntax in
  let+ block = Store.L2_blocks.read store.l2_blocks block_hash in
  Option.map (fun (info, header) -> {info with Sc_rollup_block.header}) block

let get_l2_block_by_level node_ctxt level =
  let open Lwt_result_syntax in
  trace_lwt_result_with "Could not retrieve L2 block at level %ld" level
  @@ let* block_hash = hash_of_level node_ctxt level in
     get_l2_block node_ctxt block_hash

let find_l2_block_by_level node_ctxt level =
  let open Lwt_result_syntax in
  let* block_hash = hash_of_level_opt node_ctxt level in
  match block_hash with
  | None -> return_none
  | Some block_hash -> find_l2_block node_ctxt block_hash

let get_commitment {store; _} commitment_hash =
  let open Lwt_result_syntax in
  let* commitment = Store.Commitments.find store.commitments commitment_hash in
  match commitment with
  | None ->
      failwith
        "Could not retrieve commitment %a"
        Sc_rollup.Commitment.Hash.pp
        commitment_hash
  | Some c -> return c

let find_commitment {store; _} hash =
  Store.Commitments.find store.commitments hash

let commitment_exists {store; _} hash =
  Store.Commitments.mem store.commitments hash

let save_commitment {store; _} commitment =
  let open Lwt_result_syntax in
  let hash = Sc_rollup.Commitment.hash_uncarbonated commitment in
  let+ () = Store.Commitments.add store.commitments hash commitment in
  hash

let commitment_published_at_level {store; _} commitment =
  Store.Commitments_published_at_level.find
    store.commitments_published_at_level
    commitment

let set_commitment_published_at_level {store; _} =
  Store.Commitments_published_at_level.add store.commitments_published_at_level

type commitment_source = Anyone | Us

let commitment_was_published {store; _} ~source commitment_hash =
  let open Lwt_result_syntax in
  match source with
  | Anyone ->
      Store.Commitments_published_at_level.mem
        store.commitments_published_at_level
        commitment_hash
  | Us -> (
      let+ info =
        Store.Commitments_published_at_level.find
          store.commitments_published_at_level
          commitment_hash
      in
      match info with
      | Some {published_at_level = Some _; _} -> true
      | _ -> false)

let get_inbox {store; _} inbox_hash =
  let open Lwt_result_syntax in
  let* inbox = Store.Inboxes.read store.inboxes inbox_hash in
  match inbox with
  | None ->
      failwith "Could not retrieve inbox %a" Sc_rollup.Inbox.Hash.pp inbox_hash
  | Some (i, ()) -> return i

let find_inbox {store; _} hash =
  let open Lwt_result_syntax in
  let+ inbox = Store.Inboxes.read store.inboxes hash in
  Option.map fst inbox

let save_inbox {store; _} inbox =
  let open Lwt_result_syntax in
  let hash = Sc_rollup.Inbox.hash inbox in
  let+ () = Store.Inboxes.append store.inboxes ~key:hash ~value:inbox in
  hash

let find_inbox_by_block_hash ({store; _} as node_ctxt) block_hash =
  let open Lwt_result_syntax in
  let* header = Store.L2_blocks.header store.l2_blocks block_hash in
  match header with
  | None -> return_none
  | Some {inbox_hash; _} -> find_inbox node_ctxt inbox_hash

let genesis_inbox node_ctxt =
  let genesis_level = Raw_level.to_int32 node_ctxt.genesis_info.level in
  Plugin.RPC.Sc_rollup.inbox
    node_ctxt.cctxt
    (node_ctxt.cctxt#chain, `Level genesis_level)

let inbox_of_head node_ctxt Layer1.{hash = block_hash; level = block_level} =
  let open Lwt_result_syntax in
  let* possible_inbox = find_inbox_by_block_hash node_ctxt block_hash in
  (* Pre-condition: forall l. (l > genesis_level) => inbox[l] <> None. *)
  match possible_inbox with
  | None ->
      (* The inbox exists for each tezos block the rollup should care about.
         That is, every block after the origination level. We then join
         the bandwagon and build the inbox on top of the protocol's inbox
         at the end of the origination level. *)
      let genesis_level = Raw_level.to_int32 node_ctxt.genesis_info.level in
      if block_level = genesis_level then genesis_inbox node_ctxt
      else if block_level > genesis_level then
        (* Invariant broken, the inbox for this level should exist. *)
        failwith
          "The inbox for block hash %a (level = %ld) is missing."
          Block_hash.pp
          block_hash
          block_level
      else
        (* The rollup node should not care about levels before the genesis
           level. *)
        failwith
          "Asking for the inbox before the genesis level (i.e. %ld), out of \
           the scope of the rollup's node"
          block_level
  | Some inbox -> return inbox

let get_inbox_by_block_hash node_ctxt hash =
  let open Lwt_result_syntax in
  let* level = level_of_hash node_ctxt hash in
  inbox_of_head node_ctxt {hash; level}

type messages_info = {
  predecessor : Block_hash.t;
  predecessor_timestamp : Timestamp.t;
  messages : Sc_rollup.Inbox_message.t list;
}

let get_messages {store; _} messages_hash =
  let open Lwt_result_syntax in
  let* msg = Store.Messages.read store.messages messages_hash in
  match msg with
  | None ->
      failwith
        "Could not retrieve messages with payloads merkelized hash %a"
        Sc_rollup.Inbox_merkelized_payload_hashes.Hash.pp
        messages_hash
  | Some (messages, (predecessor, predecessor_timestamp)) ->
      return {predecessor; predecessor_timestamp; messages}

let find_messages {store; _} hash =
  let open Lwt_result_syntax in
  let+ msgs = Store.Messages.read store.messages hash in
  Option.map
    (fun (messages, (predecessor, predecessor_timestamp)) ->
      {predecessor; predecessor_timestamp; messages})
    msgs

let save_messages {store; _} key {predecessor; predecessor_timestamp; messages}
    =
  Store.Messages.append
    store.messages
    ~key
    ~header:(predecessor, predecessor_timestamp)
    ~value:messages

let get_full_l2_block node_ctxt block_hash =
  let open Lwt_result_syntax in
  let* block = get_l2_block node_ctxt block_hash in
  let* inbox = get_inbox node_ctxt block.header.inbox_hash
  and* {messages; _} = get_messages node_ctxt block.header.inbox_witness
  and* commitment =
    Option.map_es (get_commitment node_ctxt) block.header.commitment_hash
  in
  return {block with content = {Sc_rollup_block.inbox; messages; commitment}}

let get_slot_header {store; _} ~published_in_block_hash slot_index =
  trace_lwt_with
    "Could not retrieve slot header for slot index %a published in block %a"
    Dal.Slot_index.pp
    slot_index
    Block_hash.pp
    published_in_block_hash
  @@ Store.Dal_slots_headers.get
       store.irmin_store
       ~primary_key:published_in_block_hash
       ~secondary_key:slot_index

let get_all_slot_headers {store; _} ~published_in_block_hash =
  Store.Dal_slots_headers.list_values
    store.irmin_store
    ~primary_key:published_in_block_hash

let get_slot_indexes {store; _} ~published_in_block_hash =
  Store.Dal_slots_headers.list_secondary_keys
    store.irmin_store
    ~primary_key:published_in_block_hash

let save_slot_header {store; _} ~published_in_block_hash
    (slot_header : Dal.Slot.Header.t) =
  Store.Dal_slots_headers.add
    store.irmin_store
    ~primary_key:published_in_block_hash
    ~secondary_key:slot_header.id.index
    slot_header

let processed_slot {store; _} ~confirmed_in_block_hash slot_index =
  Store.Dal_processed_slots.find
    store.irmin_store
    ~primary_key:confirmed_in_block_hash
    ~secondary_key:slot_index

let list_slot_pages {store; _} ~confirmed_in_block_hash =
  Store.Dal_slot_pages.list_secondary_keys_with_values
    store.irmin_store
    ~primary_key:confirmed_in_block_hash

let find_slot_page {store; _} ~confirmed_in_block_hash ~slot_index ~page_index =
  Store.Dal_slot_pages.find
    store.irmin_store
    ~primary_key:confirmed_in_block_hash
    ~secondary_key:(slot_index, page_index)

let save_unconfirmed_slot {store; _} current_block_hash slot_index =
  (* No page is actually saved *)
  Store.Dal_processed_slots.add
    store.irmin_store
    ~primary_key:current_block_hash
    ~secondary_key:slot_index
    `Unconfirmed

let save_confirmed_slot {store; _} current_block_hash slot_index pages =
  (* Adding multiple entries with the same primary key amounts to updating the
     contents of an in-memory map, hence pages must be added sequentially. *)
  let open Lwt_syntax in
  let* () =
    List.iteri_s
      (fun page_number page ->
        Store.Dal_slot_pages.add
          store.irmin_store
          ~primary_key:current_block_hash
          ~secondary_key:(slot_index, page_number)
          page)
      pages
  in
  Store.Dal_processed_slots.add
    store.irmin_store
    ~primary_key:current_block_hash
    ~secondary_key:slot_index
    `Confirmed

let find_confirmed_slots_history {store; _} =
  Store.Dal_confirmed_slots_history.find store.irmin_store

let save_confirmed_slots_history {store; _} =
  Store.Dal_confirmed_slots_history.add store.irmin_store

let find_confirmed_slots_histories {store; _} =
  Store.Dal_confirmed_slots_histories.find store.irmin_store

let save_confirmed_slots_histories {store; _} =
  Store.Dal_confirmed_slots_histories.add store.irmin_store
