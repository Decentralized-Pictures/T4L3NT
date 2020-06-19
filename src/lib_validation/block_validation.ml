(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018 Nomadic Labs. <nomadic@tezcore.com>                    *)
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

open Block_validator_errors

type validation_store = {
  context_hash : Context_hash.t;
  message : string option;
  max_operations_ttl : int;
  last_allowed_fork_level : Int32.t;
}

let validation_store_encoding =
  let open Data_encoding in
  conv
    (fun {context_hash; message; max_operations_ttl; last_allowed_fork_level} ->
      (context_hash, message, max_operations_ttl, last_allowed_fork_level))
    (fun (context_hash, message, max_operations_ttl, last_allowed_fork_level) ->
      {context_hash; message; max_operations_ttl; last_allowed_fork_level})
    (obj4
       (req "context_hash" Context_hash.encoding)
       (req "message" (option string))
       (req "max_operations_ttl" int31)
       (req "last_allowed_fork_level" int32))

type result = {
  validation_store : validation_store;
  block_metadata : Bytes.t;
  ops_metadata : Bytes.t list list;
  forking_testchain : bool;
}

let update_testchain_status ctxt predecessor_header timestamp =
  Context.get_test_chain ctxt
  >>= function
  | Not_running ->
      return ctxt
  | Running {expiration; _} ->
      if Time.Protocol.(expiration <= timestamp) then
        Context.set_test_chain ctxt Not_running >>= fun ctxt -> return ctxt
      else return ctxt
  | Forking {protocol; expiration} ->
      let predecessor_hash = Block_header.hash predecessor_header in
      let genesis = Context.compute_testchain_genesis predecessor_hash in
      let chain_id = Chain_id.of_block_hash genesis in
      (* legacy semantics *)
      Context.set_test_chain
        ctxt
        (Running {chain_id; genesis; protocol; expiration})
      >>= fun ctxt -> return ctxt

let is_testchain_forking ctxt =
  Context.get_test_chain ctxt
  >>= function
  | Not_running | Running _ -> Lwt.return_false | Forking _ -> Lwt.return_true

let init_test_chain ctxt forked_header =
  Context.get_test_chain ctxt
  >>= function
  | Not_running | Running _ ->
      assert false
  | Forking {protocol; _} ->
      ( match Registered_protocol.get protocol with
      | Some proto ->
          return proto
      | None ->
          fail (Missing_test_protocol protocol) )
      >>=? fun (module Proto_test) ->
      let test_ctxt = Shell_context.wrap_disk_context ctxt in
      Proto_test.init test_ctxt forked_header.Block_header.shell
      >>=? fun {context = test_ctxt; _} ->
      let test_ctxt = Shell_context.unwrap_disk_context test_ctxt in
      Context.set_test_chain test_ctxt Not_running
      >>= fun test_ctxt ->
      Context.set_protocol test_ctxt protocol
      >>= fun test_ctxt ->
      Context.commit_test_chain_genesis test_ctxt forked_header
      >>= fun genesis_header -> return genesis_header

let result_encoding =
  let open Data_encoding in
  conv
    (fun {validation_store; block_metadata; ops_metadata; forking_testchain} ->
      (validation_store, block_metadata, ops_metadata, forking_testchain))
    (fun (validation_store, block_metadata, ops_metadata, forking_testchain) ->
      {validation_store; block_metadata; ops_metadata; forking_testchain})
    (obj4
       (req "validation_store" validation_store_encoding)
       (req "block_metadata" bytes)
       (req "ops_metadata" (list @@ list @@ bytes))
       (req "forking_testchain" bool))

let may_force_protocol_upgrade ~user_activated_upgrades ~level
    (validation_result : Tezos_protocol_environment.validation_result) =
  match
    Block_header.get_forced_protocol_upgrade ~user_activated_upgrades ~level
  with
  | None ->
      Lwt.return validation_result
  | Some hash ->
      let context =
        Shell_context.unwrap_disk_context validation_result.context
      in
      Context.set_protocol context hash
      >>= fun context ->
      let context = Shell_context.wrap_disk_context context in
      Lwt.return {validation_result with context}

(** Applies user activated updates based either on block level or on
    voted protocols *)
let may_patch_protocol ~user_activated_upgrades
    ~user_activated_protocol_overrides ~level
    (validation_result : Tezos_protocol_environment.validation_result) =
  let context = Shell_context.unwrap_disk_context validation_result.context in
  Context.get_protocol context
  >>= fun protocol ->
  match
    Block_header.get_voted_protocol_overrides
      ~user_activated_protocol_overrides
      protocol
  with
  | None ->
      may_force_protocol_upgrade
        ~user_activated_upgrades
        ~level
        validation_result
  | Some replacement_protocol ->
      Context.set_protocol context replacement_protocol
      >>= fun context ->
      let context = Shell_context.wrap_disk_context context in
      Lwt.return {validation_result with context}

module Make (Proto : Registered_protocol.T) = struct
  let check_block_header ~(predecessor_block_header : Block_header.t) hash
      (block_header : Block_header.t) =
    let validation_passes = List.length Proto.validation_passes in
    fail_unless
      ( Int32.succ predecessor_block_header.shell.level
      = block_header.shell.level )
      ( invalid_block hash
      @@ Invalid_level
           {
             expected = Int32.succ predecessor_block_header.shell.level;
             found = block_header.shell.level;
           } )
    >>=? fun () ->
    fail_unless
      Time.Protocol.(
        predecessor_block_header.shell.timestamp < block_header.shell.timestamp)
      (invalid_block hash Non_increasing_timestamp)
    >>=? fun () ->
    fail_unless
      Fitness.(
        predecessor_block_header.shell.fitness < block_header.shell.fitness)
      (invalid_block hash Non_increasing_fitness)
    >>=? fun () ->
    fail_unless
      (block_header.shell.validation_passes = validation_passes)
      (invalid_block
         hash
         (Unexpected_number_of_validation_passes
            block_header.shell.validation_passes))
    >>=? fun () -> return_unit

  let parse_block_header block_hash (block_header : Block_header.t) =
    match
      Data_encoding.Binary.of_bytes_opt
        Proto.block_header_data_encoding
        block_header.protocol_data
    with
    | None ->
        fail (invalid_block block_hash Cannot_parse_block_header)
    | Some protocol_data ->
        return
          ({shell = block_header.shell; protocol_data} : Proto.block_header)

  let check_operation_quota block_hash operations =
    let invalid_block = invalid_block block_hash in
    iteri2_p
      (fun i ops quota ->
        fail_unless
          (Option.unopt_map
             ~default:true
             ~f:(fun max -> List.length ops <= max)
             quota.Tezos_protocol_environment.max_op)
          (let max = Option.unopt ~default:~-1 quota.max_op in
           invalid_block
             (Too_many_operations {pass = i + 1; found = List.length ops; max}))
        >>=? fun () ->
        iter_p
          (fun op ->
            let size = Data_encoding.Binary.length Operation.encoding op in
            fail_unless
              (size <= Proto.max_operation_data_length)
              (invalid_block
                 (Oversized_operation
                    {
                      operation = Operation.hash op;
                      size;
                      max = Proto.max_operation_data_length;
                    })))
          ops
        >>=? fun () -> return_unit)
      operations
      Proto.validation_passes

  let parse_operations block_hash operations =
    let invalid_block = invalid_block block_hash in
    mapi_s
      (fun pass ->
        map_s (fun op ->
            let op_hash = Operation.hash op in
            match
              Data_encoding.Binary.of_bytes_opt
                Proto.operation_data_encoding
                op.Operation.proto
            with
            | None ->
                fail (invalid_block (Cannot_parse_operation op_hash))
            | Some protocol_data ->
                let op = {Proto.shell = op.shell; protocol_data} in
                let allowed_pass = Proto.acceptable_passes op in
                fail_unless
                  (List.mem pass allowed_pass)
                  (invalid_block
                     (Unallowed_pass {operation = op_hash; pass; allowed_pass}))
                >>=? fun () -> return op))
      operations

  let apply chain_id ~user_activated_upgrades
      ~user_activated_protocol_overrides ~max_operations_ttl
      ~(predecessor_block_header : Block_header.t) ~predecessor_context
      ~(block_header : Block_header.t) operations =
    let block_hash = Block_header.hash block_header in
    let invalid_block = invalid_block block_hash in
    check_block_header ~predecessor_block_header block_hash block_header
    >>=? fun () ->
    parse_block_header block_hash block_header
    >>=? fun block_header ->
    check_operation_quota block_hash operations
    >>=? fun () ->
    update_testchain_status
      predecessor_context
      predecessor_block_header
      block_header.shell.timestamp
    >>=? fun context ->
    parse_operations block_hash operations
    >>=? fun operations ->
    let context = Shell_context.wrap_disk_context context in
    Proto.begin_application
      ~chain_id
      ~predecessor_context:context
      ~predecessor_timestamp:predecessor_block_header.shell.timestamp
      ~predecessor_fitness:predecessor_block_header.shell.fitness
      block_header
    >>=? (fun state ->
           fold_left_s
             (fun (state, acc) ops ->
               fold_left_s
                 (fun (state, acc) op ->
                   Proto.apply_operation state op
                   >>=? fun (state, op_metadata) ->
                   return (state, op_metadata :: acc))
                 (state, [])
                 ops
               >>=? fun (state, ops_metadata) ->
               return (state, List.rev ops_metadata :: acc))
             (state, [])
             operations
           >>=? fun (state, ops_metadata) ->
           let ops_metadata = List.rev ops_metadata in
           Proto.finalize_block state
           >>=? fun (validation_result, block_data) ->
           return (validation_result, block_data, ops_metadata))
    >>= (function
          | Error err ->
              fail (invalid_block (Economic_protocol_error err))
          | Ok o ->
              return o)
    >>=? fun (validation_result, block_data, ops_metadata) ->
    (* reset_test_chain
     *   validation_result.context
     *   current_block_header
     *   ~start_testchain >>=? fun forked_genesis_header -> *)
    let context =
      Shell_context.unwrap_disk_context validation_result.context
    in
    is_testchain_forking context
    >>= fun forking_testchain ->
    may_patch_protocol
      ~user_activated_upgrades
      ~user_activated_protocol_overrides
      ~level:block_header.shell.level
      validation_result
    >>= fun validation_result ->
    let context =
      Shell_context.unwrap_disk_context validation_result.context
    in
    Context.get_protocol context
    >>= fun new_protocol ->
    let expected_proto_level =
      if Protocol_hash.equal new_protocol Proto.hash then
        predecessor_block_header.shell.proto_level
      else (predecessor_block_header.shell.proto_level + 1) mod 256
    in
    fail_when
      (block_header.shell.proto_level <> expected_proto_level)
      (invalid_block
         (Invalid_proto_level
            {
              found = block_header.shell.proto_level;
              expected = expected_proto_level;
            }))
    >>=? fun () ->
    fail_when
      Fitness.(validation_result.fitness <> block_header.shell.fitness)
      (invalid_block
         (Invalid_fitness
            {
              expected = block_header.shell.fitness;
              found = validation_result.fitness;
            }))
    >>=? fun () ->
    ( if Protocol_hash.equal new_protocol Proto.hash then
      return validation_result
    else
      match Registered_protocol.get new_protocol with
      | None ->
          fail
            (Unavailable_protocol {block = block_hash; protocol = new_protocol})
      | Some (module NewProto) ->
          NewProto.init validation_result.context block_header.shell )
    >>=? fun validation_result ->
    let max_operations_ttl =
      max 0 (min (max_operations_ttl + 1) validation_result.max_operations_ttl)
    in
    let validation_result = {validation_result with max_operations_ttl} in
    let block_metadata =
      Data_encoding.Binary.to_bytes_exn
        Proto.block_header_metadata_encoding
        block_data
    in
    ( try
        return
          (List.map
             (List.map (fun receipt ->
                  (* Check that the metadata are
                     serializable/deserializable *)
                  let bytes =
                    Data_encoding.Binary.to_bytes_exn
                      Proto.operation_receipt_encoding
                      receipt
                  in
                  let _ =
                    Data_encoding.Binary.of_bytes_exn
                      Proto.operation_receipt_encoding
                      bytes
                  in
                  bytes))
             ops_metadata)
      with exn ->
        trace
          Validation_errors.Cannot_serialize_operation_metadata
          (fail (Exn exn)) )
    >>=? fun ops_metadata ->
    let context =
      Shell_context.unwrap_disk_context validation_result.context
    in
    Context.commit
      ~time:block_header.shell.timestamp
      ?message:validation_result.message
      context
    >>= fun context_hash ->
    let validation_store =
      {
        context_hash;
        message = validation_result.message;
        max_operations_ttl = validation_result.max_operations_ttl;
        last_allowed_fork_level = validation_result.last_allowed_fork_level;
      }
    in
    return {validation_store; block_metadata; ops_metadata; forking_testchain}
end

let assert_no_duplicate_operations block_hash live_operations operations =
  fold_left_s
    (fold_left_s (fun live_operations op ->
         let oph = Operation.hash op in
         fail_when
           (Operation_hash.Set.mem oph live_operations)
           (invalid_block block_hash @@ Replayed_operation oph)
         >>=? fun () -> return (Operation_hash.Set.add oph live_operations)))
    live_operations
    operations
  >>=? fun _ -> return_unit

let assert_operation_liveness block_hash live_blocks operations =
  iter_s
    (iter_s (fun op ->
         fail_unless
           (Block_hash.Set.mem op.Operation.shell.branch live_blocks)
           ( invalid_block block_hash
           @@ Outdated_operation
                {
                  operation = Operation.hash op;
                  originating_block = op.shell.branch;
                } )))
    operations

let check_liveness ~live_blocks ~live_operations block_hash operations =
  assert_no_duplicate_operations block_hash live_operations operations
  >>=? fun () ->
  assert_operation_liveness block_hash live_blocks operations
  >>=? fun () -> return_unit

let apply chain_id ~user_activated_upgrades ~user_activated_protocol_overrides
    ~max_operations_ttl ~(predecessor_block_header : Block_header.t)
    ~predecessor_context ~(block_header : Block_header.t) operations =
  let block_hash = Block_header.hash block_header in
  Context.get_protocol predecessor_context
  >>= fun pred_protocol_hash ->
  ( match Registered_protocol.get pred_protocol_hash with
  | None ->
      fail
        (Unavailable_protocol
           {block = block_hash; protocol = pred_protocol_hash})
  | Some p ->
      return p )
  >>=? fun (module Proto) ->
  let module Block_validation = Make (Proto) in
  Block_validation.apply
    chain_id
    ~user_activated_upgrades
    ~user_activated_protocol_overrides
    ~max_operations_ttl
    ~predecessor_block_header
    ~predecessor_context
    ~block_header
    operations
  >>= function
  | Error (Exn (Unix.Unix_error (errno, fn, msg)) :: _) ->
      fail (System_error {errno = Unix.error_message errno; fn; msg})
  | (Ok _ | Error _) as res ->
      Lwt.return res
