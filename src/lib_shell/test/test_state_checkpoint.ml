(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

open Filename.Infix

(** Basic blocks *)

let genesis_block =
  Block_hash.of_b58check_exn
    "BLockGenesisGenesisGenesisGenesisGenesisGeneskvg68z"

let genesis_protocol =
  Protocol_hash.of_b58check_exn
    "ProtoDemoNoopsDemoNoopsDemoNoopsDemoNoopsDemo6XBoYp"

let genesis_time = Time.Protocol.of_seconds 0L

let proto =
  match Registered_protocol.get genesis_protocol with
  | None ->
      assert false
  | Some proto ->
      proto

module Proto = (val proto)

let genesis : Genesis.t =
  {
    Genesis.time = genesis_time;
    block = genesis_block;
    protocol = genesis_protocol;
  }

let incr_fitness fitness =
  let new_fitness =
    match fitness with
    | [fitness] ->
        Data_encoding.Binary.of_bytes_opt Data_encoding.int64 fitness
        |> Option.value ~default:0L |> Int64.succ
        |> Data_encoding.Binary.to_bytes_exn Data_encoding.int64
    | _ ->
        Data_encoding.Binary.to_bytes_exn Data_encoding.int64 1L
  in
  [new_fitness]

let incr_timestamp timestamp =
  Time.Protocol.add timestamp (Int64.add 1L (Random.int64 10L))

let operation op =
  let op : Operation.t =
    {shell = {branch = genesis_block}; proto = Bytes.of_string op}
  in
  (Operation.hash op, op, Data_encoding.Binary.to_bytes Operation.encoding op)

let block_header_data_encoding =
  Data_encoding.(obj1 (req "proto_block_header" string))

let block _state ?(context = Context_hash.zero) ?(operations = [])
    (pred : State.Block.t) name : Block_header.t =
  let operations_hash =
    Operation_list_list_hash.compute [Operation_list_hash.compute operations]
  in
  let pred_header = State.Block.shell_header pred in
  let fitness = incr_fitness pred_header.fitness in
  let timestamp = incr_timestamp pred_header.timestamp in
  let protocol_data =
    Data_encoding.Binary.to_bytes_exn block_header_data_encoding name
  in
  {
    shell =
      {
        level = Int32.succ pred_header.level;
        proto_level = pred_header.proto_level;
        predecessor = State.Block.hash pred;
        validation_passes = 1;
        timestamp;
        operations_hash;
        fitness;
        context;
      };
    protocol_data;
  }

let parsed_block ({shell; protocol_data} : Block_header.t) =
  let protocol_data =
    Data_encoding.Binary.of_bytes_exn
      Proto.block_header_data_encoding
      protocol_data
  in
  ({shell; protocol_data} : Proto.block_header)

let zero = Bytes.create 0

let block_header_data_encoding =
  Data_encoding.(obj1 (req "proto_block_header" string))

let build_valid_chain state vtbl pred names =
  Lwt_list.fold_left_s
    (fun pred name ->
      State.Block.context_exn pred
      >>= fun predecessor_context ->
      let max_trials = 100 in
      let rec attempt trials context =
        (let (oph, op, _bytes) = operation name in
         let block = block ?context state ~operations:[oph] pred name in
         let hash = Block_header.hash block in
         let pred_header = State.Block.header pred in
         (let predecessor_context =
            Shell_context.wrap_disk_context predecessor_context
          in
          Proto.begin_application
            ~chain_id:Chain_id.zero
            ~predecessor_context
            ~predecessor_timestamp:pred_header.shell.timestamp
            ~predecessor_fitness:pred_header.shell.fitness
            (parsed_block block)
          >>=? fun vstate ->
          (* no operations *)
          Proto.finalize_block vstate)
         >>=? fun (result, _metadata) ->
         let context = Shell_context.unwrap_disk_context result.context in
         Context.commit
           ~time:(Time.System.to_protocol (Systime_os.now ()))
           ?message:result.message
           context
         >>= fun context_hash ->
         let validation_store =
           ( {
               context_hash;
               message = result.message;
               max_operations_ttl = result.max_operations_ttl;
               last_allowed_fork_level = result.last_allowed_fork_level;
             }
             : Tezos_validation.Block_validation.validation_store )
         in
         let block_metadata = zero in
         let block_metadata_hash =
           Option.some @@ Block_metadata_hash.hash_bytes [block_metadata]
         in
         let operations_metadata = [[zero]] in
         let operations_metadata_hashes =
           Some [[Operation_metadata_hash.hash_bytes [zero]]]
         in
         State.Block.store
           state
           block
           block_metadata
           [[op]]
           operations_metadata
           block_metadata_hash
           operations_metadata_hashes
           validation_store
           ~forking_testchain:false
         >>=? fun _vblock ->
         State.Block.read state hash
         >>=? fun vblock ->
         String.Hashtbl.add vtbl name vblock ;
         return vblock)
        >>= function
        | Ok v ->
            if trials < max_trials then
              Format.eprintf
                "Took %d trials to build valid chain"
                (max_trials - trials + 1) ;
            Lwt.return v
        | Error (Validation_errors.Inconsistent_hash (got, _) :: _) ->
            (* Kind of a hack, but at least it tests idempotence to some extent. *)
            if trials <= 0 then assert false
            else (
              Format.eprintf
                "Inconsistent context hash: got %a, retrying (%d)\n"
                Context_hash.pp
                got
                trials ;
              attempt (trials - 1) (Some got) )
        | Error err ->
            Format.eprintf "Error: %a\n" Error_monad.pp_print_error err ;
            assert false
      in
      attempt max_trials None)
    pred
    names
  >>= fun _ -> Lwt.return_unit

type state = {
  vblock : State.Block.t String.Hashtbl.t;
  state : State.t;
  chain : State.Chain.t;
}

let vblock s k = Option.get @@ String.Hashtbl.find s.vblock k

exception Found of string

let vblocks s =
  String.Hashtbl.fold (fun k v acc -> (k, v) :: acc) s.vblock []
  |> List.sort Stdlib.compare

(*******************************************************)
(*

    Genesis - A1 - A2 - A3 - A4 - A5
                    \
                     B1 - B2 - B3 - B4 - B5
*)

let build_example_tree chain =
  let vtbl = String.Hashtbl.create 23 in
  Chain.genesis chain
  >>= fun genesis ->
  String.Hashtbl.add vtbl "Genesis" genesis ;
  let c = ["A1"; "A2"; "A3"; "A4"; "A5"] in
  build_valid_chain chain vtbl genesis c
  >>= fun () ->
  let a2 = Option.get @@ String.Hashtbl.find vtbl "A2" in
  let c = ["B1"; "B2"; "B3"; "B4"; "B5"] in
  build_valid_chain chain vtbl a2 c >>= fun () -> Lwt.return vtbl

let wrap_state_init f base_dir =
  let store_root = base_dir // "store" in
  let context_root = base_dir // "context" in
  State.init
    ~store_mapsize:4_096_000_000L
    ~context_mapsize:4_096_000_000L
    ~store_root
    ~context_root
    genesis
  >>=? fun (state, chain, _index, _history_mode) ->
  build_example_tree chain
  >>= fun vblock -> f {state; chain; vblock} >>=? fun () -> return_unit

(** State.Chain.checkpoint *)

(*
- Valid branch are kept after setting a checkpoint. Bad branch are cut
- Setting a checkpoint in the future does not remove anything
- Reaching a checkpoint in the future with the right block keeps that
block and remove any concurrent branch
- Reaching a checkpoint in the future with a bad block remove that block and
does not prevent a future good block from correctly being reached
- There are no bad quadratic behaviours *)

let test_basic_checkpoint s =
  let block = vblock s "A1" in
  let header = State.Block.header block in
  State.Chain.set_checkpoint s.chain header
  >>= fun () ->
  State.Chain.checkpoint s.chain
  >>= fun checkpoint_header ->
  let c_level = checkpoint_header.shell.level in
  let c_block = Block_header.hash checkpoint_header in
  if
    (not (Block_hash.equal c_block (State.Block.hash block)))
    && Int32.equal c_level (State.Block.level block)
  then Assert.fail_msg "unexpected checkpoint"
  else return_unit

(*
   - cp: checkpoint

  Genesis - A1 - A2 (cp) - A3 - A4 - A5
                  \
                   B1 - B2 - B3 - B4 - B5
  *)

(* State.Chain.acceptable_block:
   will the block is compatible with the current checkpoint? *)

let test_acceptable_block s =
  let block = vblock s "A2" in
  let header = State.Block.header block in
  (* let level = State.Block.level block in
   * let block_hash = State.Block.hash block  in *)
  State.Chain.set_checkpoint s.chain header
  >>= fun () ->
  (* it is accepted only if the current head is lower than the checkpoint *)
  let block_1 = vblock s "A1" in
  Chain.set_head s.chain block_1
  >>=? fun head ->
  let header = State.Block.header head in
  State.Chain.acceptable_block s.chain header
  >>= fun is_accepted_block ->
  if is_accepted_block then return_unit
  else Assert.fail_msg "unacceptable block"

(*
  Genesis - A1 - A2 (cp) - A3 - A4 - A5
                  \
                   B1 - B2 - B3 - B4 - B5
  *)

(* State.Block.is_valid_for_checkpoint :
   is the block still valid for a given checkpoint ? *)

let test_is_valid_checkpoint s =
  let block = vblock s "A2" in
  let header = State.Block.header block in
  (* let block_hash = State.Block.hash block in
   * let level = State.Block.level block in *)
  State.Chain.set_checkpoint s.chain header
  >>= fun () ->
  State.Chain.checkpoint s.chain
  >>= fun checkpoint_header ->
  (* "b3" is valid because:
     a1 - a2 (checkpoint) - b1 - b2 - b3
     it is not valid when the checkpoint change to a pick different than a2.
  *)
  State.Block.is_valid_for_checkpoint (vblock s "B3") checkpoint_header
  >>= fun is_valid ->
  if is_valid then return_unit else Assert.fail_msg "invalid checkpoint"

(* return a block with the best fitness amongst the known blocks which
    are compatible with the given checkpoint *)

let test_best_know_head_for_checkpoint s =
  let block = vblock s "A2" in
  let checkpoint = State.Block.header block in
  State.Chain.set_checkpoint s.chain checkpoint
  >>= fun () ->
  Chain.set_head s.chain (vblock s "B3")
  >>= fun _head ->
  State.best_known_head_for_checkpoint s.chain checkpoint
  >>= fun _block ->
  (* the block returns with the best fitness is B3 at level 5 *)
  return_unit

(*
   setting checkpoint in the future does not remove anything

   Genesis - A1 - A2(cp) - A3 - A4 - A5
                  \
                  B1 - B2 - B3 - B4 - B5
*)

let test_future_checkpoint s =
  let block = vblock s "A2" in
  let block_hash = State.Block.hash block in
  let level = State.Block.level block in
  let header = State.Block.header block in
  State.Chain.set_checkpoint s.chain header
  >>= fun () ->
  State.Chain.checkpoint s.chain
  >>= fun checkpoint_header ->
  let c_level = checkpoint_header.shell.level in
  let c_block = Block_header.hash checkpoint_header in
  if Int32.equal c_level level && not (Block_hash.equal c_block block_hash)
  then Assert.fail_msg "unexpected checkpoint"
  else return_unit

(*
   setting checkpoint in the future does not remove anything
   - iv = invalid
  - (0): level of this block in the chain

  Two examples:
    * Genesis (0)- A1 (1) - A2(2) - A3(3) - A4(4) - A5(5) (invalid)
                            \
                            B1(3) - B2(4) - B3 (5)(cp) - B4(6) - B5(7)

    * Genesis - A1 - A2 - A3 - A4 - A5 (cp)
                      \
                      B1 - B2 - B3 (iv)- B4 (iv) - B5 (iv)
*)

let test_future_checkpoint_bad_good_block s =
  let block = vblock s "A5" in
  let block_hash = State.Block.hash block in
  let level = State.Block.level block in
  let header = State.Block.header block in
  State.Chain.set_checkpoint s.chain header
  >>= fun () ->
  State.Chain.checkpoint s.chain
  >>= fun checkpoint_header ->
  let c_level = checkpoint_header.shell.level in
  let c_block = Block_header.hash checkpoint_header in
  if Int32.equal c_level level && not (Block_hash.equal c_block block_hash)
  then Assert.fail_msg "unexpected checkpoint"
  else
    State.Block.is_valid_for_checkpoint (vblock s "B2") checkpoint_header
    >>= fun is_valid ->
    if is_valid then return_unit else Assert.fail_msg "invalid checkpoint"

(* check if the checkpoint can be reached

   Genesis - A1 (cp) - A2 (head) - A3 - A4 - A5
                        \
                        B1 - B2 - B3 - B4 - B5

*)

let test_reach_checkpoint s =
  let mem s x = Chain.mem s.chain (State.Block.hash @@ vblock s x) in
  let test_mem s x =
    mem s x
    >>= function
    | true -> Lwt.return_unit | false -> Assert.fail_msg "mem %s" x
  in
  let test_not_mem s x =
    mem s x
    >>= function
    | false -> Lwt.return_unit | true -> Assert.fail_msg "not (mem %s)" x
  in
  let block = vblock s "A1" in
  let block_hash = State.Block.hash block in
  let header = State.Block.header block in
  State.Chain.set_checkpoint s.chain header
  >>= fun () ->
  State.Chain.checkpoint s.chain
  >>= fun checkpoint_header ->
  if Clock_drift.is_not_too_far_in_the_future header.shell.timestamp then
    let checkpoint_hash = Block_header.hash checkpoint_header in
    if
      Int32.equal header.shell.level checkpoint_header.shell.level
      && not (Block_hash.equal checkpoint_hash block_hash)
    then Assert.fail_msg "checkpoint error"
    else
      Chain.set_head s.chain (vblock s "A2")
      >>= fun _ ->
      Chain.head s.chain
      >>= fun head ->
      let checkpoint_reached =
        (State.Block.header head).shell.level >= checkpoint_header.shell.level
      in
      if checkpoint_reached then
        (* if reached the checkpoint, every block before the checkpoint
           must be the part of the chain *)
        if header.shell.level <= checkpoint_header.shell.level then
          test_mem s "Genesis"
          >>= fun () ->
          test_mem s "A1"
          >>= fun () ->
          test_mem s "A2"
          >>= fun () ->
          test_not_mem s "A3"
          >>= fun () -> test_not_mem s "B1" >>= fun () -> return_unit
        else Assert.fail_msg "checkpoint error"
      else Assert.fail_msg "checkpoint error"
  else Assert.fail_msg "fail future block header"

(*
   Chain.Validator function may_update_checkpoint

   - ncp: new checkpoint

   Genesis - A1 - A2 - A3 (cp) - A4 - A5
                  \
                  B1 - B2 - B3 - B4 - B5

   Genesis - A1 (ncp) - A2 - A3 (cp) - A4 (ncp) - A5
                       \
                       B1 - B2 - B3 - B4 - B5
*)

let may_update_checkpoint chain_state new_head =
  State.Chain.checkpoint chain_state
  >>= fun checkpoint_header ->
  (* FIXME: the new level is always return 0l even
     if the new_head is A4 at level 4l
     Or TODO: set a level where allow to have a fork
  *)
  let old_level = checkpoint_header.shell.level in
  State.Block.last_allowed_fork_level new_head
  >>=? fun new_level ->
  if new_level <= old_level then return_unit
  else
    let head_level = State.Block.level new_head in
    State.Block.predecessor_n
      new_head
      (Int32.to_int (Int32.sub head_level new_level))
    >>= function
    | None ->
        return @@ Assert.fail_msg "Unexpected None in predecessor query"
    | Some hash -> (
        State.Block.read_opt chain_state hash
        >>= function
        | None ->
            assert false
        | Some b ->
            State.Chain.set_checkpoint chain_state (State.Block.header b)
            >>= fun () -> return_unit )

let test_may_update_checkpoint s =
  let block = vblock s "A3" in
  let checkpoint = State.Block.header block in
  State.Chain.set_checkpoint s.chain checkpoint
  >>= fun () ->
  State.Chain.checkpoint s.chain
  >>= fun _ ->
  Chain.set_head s.chain (vblock s "A4")
  >>= fun _ ->
  Chain.head s.chain
  >>= fun head -> may_update_checkpoint s.chain head >>=? fun () -> return ()

(* Check function may_update_checkpoint in Node.ml

   Genesis - A1 - A2 (cp) - A3 - A4 - A5
                  \
                  B1 - B2 - B3 - B4 - B5

   chain after update:
   Genesis - A1 - A2 - A3(cp) - A4 - A5
                  \
                  B1 - B2 - B3 - B4 - B5
*)

let note_may_update_checkpoint chain_state checkpoint =
  match checkpoint with
  | None ->
      Lwt.return_unit
  | Some checkpoint ->
      State.best_known_head_for_checkpoint chain_state checkpoint
      >>= fun new_head ->
      Chain.set_head chain_state new_head
      >>= fun _ -> State.Chain.set_checkpoint chain_state checkpoint

let test_note_may_update_checkpoint s =
  (* set checkpoint at (2l, A2) *)
  let block = vblock s "A2" in
  let header = State.Block.header block in
  State.Chain.set_checkpoint s.chain header
  >>= fun () ->
  (* set new checkpoint at (3l, A3) *)
  let block = vblock s "A3" in
  let checkpoint = State.Block.header block in
  note_may_update_checkpoint s.chain (Some checkpoint)
  >>= fun () -> return_unit

(****************************************************************************)

let tests : (string * (state -> unit tzresult Lwt.t)) list =
  [ ("basic checkpoint", test_basic_checkpoint);
    ("is valid checkpoint", test_is_valid_checkpoint);
    ("acceptable block", test_acceptable_block);
    ("best know head", test_best_know_head_for_checkpoint);
    ("future checkpoint", test_future_checkpoint);
    ("future checkpoint bad/good block", test_future_checkpoint_bad_good_block);
    ("test_reach_checkpoint", test_reach_checkpoint);
    ("update checkpoint", test_may_update_checkpoint);
    ("update checkpoint in node", test_note_may_update_checkpoint) ]

let wrap (n, f) =
  Alcotest_lwt.test_case n `Quick (fun _ () ->
      Lwt_utils_unix.with_tempdir "tezos_test_" (fun dir ->
          wrap_state_init f dir
          >>= function
          | Ok () ->
              Lwt.return_unit
          | Error error ->
              Format.kasprintf Stdlib.failwith "%a" pp_print_error error))

let tests = List.map wrap tests
