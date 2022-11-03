(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
(* Copyright (c) 2022 Marigold, <contact@marigold.dev>                       *)
(* Copyright (c) 2022 Oxhead Alpha <info@oxhead-alpha.com>                   *)
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

open Protocol.Apply_results
open Protocol.Apply_internal_results
open Tezos_shell_services
open Protocol_client_context
open Protocol
open Alpha_context
open Error

let parse_tx_rollup_l2_address :
    Script.node -> Protocol.Tx_rollup_l2_address.Indexable.value tzresult =
  let open Protocol in
  let open Micheline in
  function
  | Bytes (loc, bytes) (* As unparsed with [Optimized]. *) -> (
      match Tx_rollup_l2_address.of_bytes_opt bytes with
      | Some txa -> ok (Tx_rollup_l2_address.Indexable.value txa)
      | None -> error (Error.Tx_rollup_invalid_l2_address loc))
  | String (loc, str) (* As unparsed with [Readable]. *) -> (
      match Tx_rollup_l2_address.of_b58check_opt str with
      | Some txa -> ok (Tx_rollup_l2_address.Indexable.value txa)
      | None -> error (Error.Tx_rollup_invalid_l2_address loc))
  | Int (loc, _) | Prim (loc, _, _, _) | Seq (loc, _) ->
      error (Error.Tx_rollup_invalid_l2_address loc)

let parse_ticketer : Script.node -> Contract.t tzresult =
  let open Micheline in
  function
  | Bytes (_loc, bytes) (* As unparsed with [Optimized]. *) ->
      Result.of_option ~error:[Wrong_deposit_parameters]
      @@ Data_encoding.Binary.of_bytes_opt Contract.encoding bytes
  | String (_loc, str) (* As unparsed with [Readable]. *) ->
      Environment.wrap_tzresult @@ Contract.of_b58check str
  | Int _ | Prim _ | Seq _ -> error Wrong_deposit_parameters

let parse_tx_rollup_deposit_parameters :
    Script.expr ->
    (Contract.t
    * Script.expr
    * Script.expr
    * Protocol.Tx_rollup_l2_qty.t
    * Protocol.Script_typed_ir.tx_rollup_l2_address)
    tzresult =
 fun parameters ->
  let open Result_syntax in
  let open Micheline in
  let open Protocol in
  (* /!\ This pattern matching needs to remain in sync with the deposit
     parameters. See the transaction to Tx_rollup case in
     Protocol.Apply.Apply.apply_internal_operation_contents *)
  match root parameters with
  | Seq
      ( _,
        [
          Prim
            ( _,
              D_Pair,
              [
                Prim
                  ( _,
                    D_Pair,
                    [ticketer; Prim (_, D_Pair, [contents; amount], _)],
                    _ );
                bls;
              ],
              _ );
          ty;
        ] ) ->
      let* destination = parse_tx_rollup_l2_address bls in
      let* amount =
        match amount with
        | Int (_, v)
          when Compare.Z.(Z.zero < v && v <= Z.of_int64 Int64.max_int) ->
            ok @@ Tx_rollup_l2_qty.of_int64_exn (Z.to_int64 v)
        | Int (_, invalid_amount) ->
            error (Error.Tx_rollup_invalid_ticket_amount invalid_amount)
        | _expr -> error Error.Tx_rollup_invalid_deposit
      in
      let* ticketer = parse_ticketer ticketer in
      let ty = strip_locations ty in
      let contents = strip_locations contents in
      return (ticketer, ty, contents, amount, destination)
  | _expr -> error Error.Tx_rollup_invalid_deposit

let extract_messages_from_block block_info rollup_id =
  let managed_operation =
    List.nth_opt
      block_info.Alpha_block_services.operations
      State.rollup_operation_index
  in
  let add_message_ticket (msg, _size) new_ticket (messages, tickets) =
    let tickets =
      match new_ticket with None -> tickets | Some ticket -> ticket :: tickets
    in
    (msg :: messages, tickets)
  in
  let get_messages_of_internal_operation ~source messages_tickets
      (Internal_operation_result
        ( {
            operation;
            source = _use_the_source_of_the_external_operation;
            nonce = _;
          },
          result )) =
    match (operation, result) with
    | ( Transaction
          {amount = _; parameters; destination = Tx_rollup dst; entrypoint},
        Applied
          (ITransaction_result
            (Transaction_to_tx_rollup_result {ticket_hash; _})) )
      when Tx_rollup.equal dst rollup_id
           && Entrypoint.(entrypoint = Entrypoint.deposit) ->
        (* Deposit message *)
        ( Option.bind (Data_encoding.force_decode parameters)
        @@ fun parameters ->
          parse_tx_rollup_deposit_parameters parameters |> Result.to_option )
        |> Option.fold
             ~none:messages_tickets
             ~some:(fun (ticketer, ty, contents, amount, destination) ->
               let deposit =
                 Tx_rollup_message.make_deposit
                   source
                   destination
                   ticket_hash
                   amount
               in
               add_message_ticket
                 deposit
                 (Some Ticket.{ticketer; ty; contents; hash = ticket_hash})
                 messages_tickets)
    | _ -> messages_tickets
  in
  let get_messages :
      type kind.
      source:public_key_hash ->
      kind manager_operation ->
      kind manager_operation_result ->
      packed_internal_operation_result list ->
      Tx_rollup_message.t list * Ticket.t list ->
      Tx_rollup_message.t list * Ticket.t list =
   fun ~source op result internal_operation_results messages_tickets ->
    let acc =
      match (op, result) with
      | ( Tx_rollup_submit_batch {tx_rollup; content; burn_limit = _},
          Applied (Tx_rollup_submit_batch_result _) )
        when Tx_rollup.equal rollup_id tx_rollup ->
          (* Batch message *)
          add_message_ticket
            (Tx_rollup_message.make_batch content)
            None
            messages_tickets
      | _, _ -> messages_tickets
    in
    (* Add messages from internal operations *)
    List.fold_left
      (get_messages_of_internal_operation ~source)
      acc
      internal_operation_results
  in
  let rec get_related_messages :
      type kind.
      Tx_rollup_message.t list * Ticket.t list ->
      kind contents_and_result_list ->
      Tx_rollup_message.t list * Ticket.t list =
   fun acc -> function
    | Single_and_result
        ( Manager_operation {operation; source; _},
          Manager_operation_result
            {operation_result; internal_operation_results; _} ) ->
        get_messages
          ~source
          operation
          operation_result
          internal_operation_results
          acc
    | Single_and_result (_, _) -> acc
    | Cons_and_result
        ( Manager_operation {operation; source; _},
          Manager_operation_result
            {operation_result; internal_operation_results; _},
          rest ) ->
        let acc =
          get_messages
            ~source
            operation
            operation_result
            internal_operation_results
            acc
        in
        get_related_messages acc rest
  in
  let finalize_receipt acc operation =
    match Alpha_block_services.(operation.protocol_data, operation.receipt) with
    | ( Operation_data {contents = operation_contents; _},
        Receipt (Operation_metadata {contents = result_contents}) ) -> (
        match kind_equal_list operation_contents result_contents with
        | Some Eq ->
            let operation_and_result =
              pack_contents_list operation_contents result_contents
            in
            ok (get_related_messages acc operation_and_result)
        | None ->
            (* Should not happen *)
            ok acc)
    | _, Receipt No_operation_metadata | _, Empty | _, Too_large ->
        error (Tx_rollup_no_operation_metadata operation.hash)
  in
  match managed_operation with
  | None -> ok ([], [])
  | Some managed_operations ->
      let open Result_syntax in
      let+ rev_messages, new_tickets =
        List.fold_left_e finalize_receipt ([], []) managed_operations
      in
      (List.rev rev_messages, new_tickets)

let check_inbox state tezos_block level inbox =
  let open Lwt_result_syntax in
  trace (Error.Tx_rollup_cannot_check_inbox level)
  @@ let* proto_inbox =
       Protocol.Tx_rollup_services.inbox
         state.State.cctxt
         (state.State.cctxt#chain, `Hash (tezos_block, 0))
         state.State.rollup_info.rollup_id
         level
     in
     let*? protocol_inbox =
       Result.of_option
         ~error:[Error.Tx_rollup_no_proto_inbox (level, tezos_block)]
         proto_inbox
     in
     let reconstructed_inbox = Inbox.to_proto inbox in
     fail_unless
       Tx_rollup_inbox.(reconstructed_inbox = protocol_inbox)
       (Error.Tx_rollup_inbox_mismatch
          {level; reconstructed_inbox; protocol_inbox})

let commit_block_on_l1 state block =
  match state.State.signers.operator with
  | None -> return_unit
  | Some operator ->
      Committer.commit_block ~operator state.State.rollup_info.rollup_id block

let store_indexes ctxt contents =
  let open Lwt_syntax in
  let register_indexes_from_result ctxt result =
    let indexes =
      let open Protocol.Tx_rollup_l2_apply.Message_result in
      match result with
      | Deposit_result (Deposit_success indexes) -> indexes
      | Batch_V1_result (Batch_result {indexes; _}) -> indexes
      | _ -> assert false
    in
    List.fold_left_s
      (fun ctxt (address, index) -> Context.register_address ctxt index address)
      ctxt
      indexes.address_indexes
  in

  List.fold_left_s
    (fun ctxt Inbox.{result; _} ->
      match result with
      | Interpreted (result, _) -> register_indexes_from_result ctxt result
      | Discarded _ -> return ctxt)
    ctxt
    contents

let process_messages_and_inboxes (state : State.t)
    ~(predecessor : L2block.t option) ?predecessor_context block_info =
  let open Lwt_result_syntax in
  let current_hash = block_info.Alpha_block_services.hash in
  let*? messages, new_tickets =
    extract_messages_from_block block_info state.State.rollup_info.rollup_id
  in
  let*! () = Event.(emit messages_application) (List.length messages) in
  let* predecessor_context =
    match predecessor_context with
    | Some context -> return context
    | None -> (
        match predecessor with
        | None ->
            let*! ctxt = Context.init_context state.context_index in
            return ctxt
        | Some predecessor ->
            Context.checkout state.context_index predecessor.header.context)
  in
  let parameters =
    Protocol.Tx_rollup_l2_apply.
      {
        tx_rollup_max_withdrawals_per_batch =
          state.constants.parametric.tx_rollup.max_withdrawals_per_batch;
      }
  in
  let context = predecessor_context in
  let* context, contents =
    Interpreter.interpret_messages
      context
      parameters
      ~rejection_max_proof_size:
        state.constants.parametric.tx_rollup.rejection_max_proof_size
      messages
  in
  let* context =
    List.fold_left_es
      (fun context ticket ->
        let* ticket_index =
          Context.Ticket_index.get context ticket.Ticket.hash
        in
        match ticket_index with
        | None ->
            (* Can only happen if the interpretation of the corresponding deposit
               fails (with an overflow on amounts or indexes). *)
            return context
        | Some ticket_index ->
            let*! context =
              Context.register_ticket context ticket_index ticket
            in
            return context)
      context
      new_tickets
  in
  match contents with
  | None ->
      (* No inbox at this block *)
      return (`Old predecessor, predecessor_context)
  | Some inbox ->
      let*! context = store_indexes context inbox in
      let*! context_hash = Context.commit context in
      let level, predecessor_hash =
        match predecessor with
        | None -> (Tx_rollup_level.root, None)
        | Some {hash; header = {level; _}; _} ->
            (Tx_rollup_level.succ level, Some hash)
      in
      let* () = check_inbox state current_hash level inbox in
      let commitment = Committer.commitment_of_inbox ~predecessor level inbox in
      let header : L2block.header =
        {
          level;
          tezos_block = current_hash;
          predecessor = predecessor_hash;
          context = context_hash;
          commitment =
            Tx_rollup_commitment.(Compact.hash (Full.compact commitment));
        }
      in
      let hash = L2block.hash_header header in
      let block = L2block.{hash; header; inbox; commitment} in
      let*! () = State.save_block state block in
      let*! () =
        Event.(emit rollup_block) (header.level, hash, header.tezos_block)
      in
      return (`New block, context)

let set_head state head =
  let open Lwt_result_syntax in
  let* _l2_reorg = State.set_head state head in
  let*! new_head_batcher = Batcher.new_head head in
  match new_head_batcher with
  | Error [No_batcher] -> return_unit
  | Ok () -> return_unit
  | Error _ as res -> Lwt.return res

let originated_in_block rollup_id block =
  let check_origination_content_result : type kind. kind contents_result -> bool
      = function
    | Manager_operation_result
        {
          operation_result =
            Applied (Tx_rollup_origination_result {originated_tx_rollup; _});
          _;
        } ->
        Tx_rollup.(originated_tx_rollup = rollup_id)
    | _ -> false
  in
  let rec check_origination_content_result_list :
      type kind. kind contents_result_list -> bool = function
    | Single_result x -> check_origination_content_result x
    | Cons_result (x, xs) ->
        check_origination_content_result x
        || check_origination_content_result_list xs
  in
  let manager_operations =
    List.nth_opt
      block.Alpha_block_services.operations
      State.rollup_operation_index
  in
  let has_rollup_origination operation =
    match operation.Alpha_block_services.receipt with
    | Receipt (Operation_metadata {contents}) ->
        check_origination_content_result_list contents
    | Receipt No_operation_metadata | Empty | Too_large -> false
  in
  match manager_operations with
  | None -> false
  | Some ops -> List.exists has_rollup_origination ops

let rec process_block state current_hash =
  let open Lwt_result_syntax in
  let rollup_id = state.State.rollup_info.rollup_id in
  let*! l2_block = State.tezos_block_already_processed state current_hash in
  match l2_block with
  | `Known maybe_l2_block ->
      (* Already processed *)
      let*! () = Event.(emit block_already_processed) current_hash in
      let* () =
        match maybe_l2_block with
        | Some l2_block -> set_head state l2_block
        | None -> return_unit
      in
      return (maybe_l2_block, None, [])
  | `Unknown ->
      state.State.sync.synchronized <- false ;
      let* block_info = State.fetch_tezos_block state current_hash in
      let predecessor_hash = block_info.header.shell.predecessor in
      let block_level = block_info.header.shell.level in
      let* () =
        match state.State.rollup_info.origination_level with
        | Some origination_level when block_level < origination_level ->
            tzfail Tx_rollup_originated_in_fork
        | _ -> return_unit
      in
      (* Handle predecessor Tezos block first *)
      let*! () =
        Event.(emit processing_block_predecessor)
          (predecessor_hash, Int32.pred block_level)
      in
      let* l2_predecessor, predecessor_context, blocks_to_commit =
        if originated_in_block rollup_id block_info then
          let*! () =
            Event.(emit detected_origination) (rollup_id, current_hash)
          in
          let* () =
            State.set_rollup_info state rollup_id ~origination_level:block_level
          in
          return (None, None, [])
        else process_block state predecessor_hash
      in
      let*! () =
        Event.(emit processing_block) (current_hash, predecessor_hash)
      in
      let* l2_block, context =
        process_messages_and_inboxes
          state
          ~predecessor:l2_predecessor
          ?predecessor_context
          block_info
      in
      let blocks_to_commit =
        match l2_block with
        | `Old _ -> blocks_to_commit
        | `New l2_block -> l2_block :: blocks_to_commit
      in
      let*! () =
        let maybe_l2_block_hash =
          match l2_block with
          | `Old None -> None
          | `Old (Some l2_block) | `New l2_block -> Some l2_block.hash
        in
        State.save_tezos_block_info
          state
          current_hash
          maybe_l2_block_hash
          ~level:block_info.header.shell.level
          ~predecessor:block_info.header.shell.predecessor
      in
      let* l2_block =
        match l2_block with
        | `Old None -> return_none
        | `Old (Some l2_block) | `New l2_block ->
            let* () = set_head state l2_block in
            return_some l2_block
      in
      State.notify_processed_tezos_level state block_info.header.shell.level ;
      let*! () =
        Event.(emit tezos_block_processed) (current_hash, block_level)
      in
      return (l2_block, Some context, blocks_to_commit)

let batch () = if Batcher.active () then Batcher.batch () else return_unit

let notify_head state head reorg =
  let open Lwt_result_syntax in
  let* head = State.fetch_tezos_block state head in
  let*! () = Injector.new_tezos_head head reorg in
  return_unit

let queue_gc_operations state =
  let open Lwt_result_syntax in
  let tx_rollup = state.State.rollup_info.rollup_id in
  let queue_finalize_commitment state =
    match state.State.signers.finalize_commitment with
    | None -> return_unit
    | Some source ->
        Injector.add_pending_operation
          ~source
          (Tx_rollup_finalize_commitment {tx_rollup})
  in
  let queue_remove_commitment state =
    match state.State.signers.remove_commitment with
    | None -> return_unit
    | Some source ->
        Injector.add_pending_operation
          ~source
          (Tx_rollup_remove_commitment {tx_rollup})
  in
  let* () = queue_finalize_commitment state in
  queue_remove_commitment state

let time_until_next_block state (header : Tezos_base.Block_header.t) =
  let open Result_syntax in
  let Constants.Parametric.{minimal_block_delay; delay_increment_per_round; _} =
    state.State.constants.parametric
  in
  let next_level_timestamp =
    let* durations =
      Round.Durations.create
        ~first_round_duration:minimal_block_delay
        ~delay_increment_per_round
    in
    let* predecessor_round = Fitness.round_from_raw header.shell.fitness in
    Round.timestamp_of_round
      durations
      ~predecessor_timestamp:header.shell.timestamp
      ~predecessor_round
      ~round:Round.zero
  in
  let next_level_timestamp =
    Result.value
      next_level_timestamp
      ~default:
        (WithExceptions.Result.get_ok
           ~loc:__LOC__
           Timestamp.(header.shell.timestamp +? minimal_block_delay))
  in
  Ptime.diff
    (Time.System.of_protocol_exn next_level_timestamp)
    (Time.System.now ())

let trigger_injection state header =
  let open Lwt_syntax in
  (* Queue request for injection of operation that must be delayed *)
  (* Waiting only half the time until next block to allow for propagation *)
  let promise =
    let delay =
      Ptime.Span.to_float_s (time_until_next_block state header) /. 2.
    in
    let* () =
      if delay <= 0. then return_unit
      else
        let* () = Event.(emit inject_wait) delay in
        Lwt_unix.sleep delay
    in
    Injector.inject ~strategy:`Delay_block ()
  in
  ignore promise ;
  (* Queue request for injection of operation that must be injected each block *)
  Injector.inject ~strategy:`Each_block ()

let dispatch_withdrawals_on_l1 state level =
  let open Lwt_result_syntax in
  match state.State.signers.dispatch_withdrawals with
  | None -> return_unit
  | Some source -> (
      let*! block = State.get_level_l2_block state level in
      match block with
      | None -> return_unit
      | Some block -> Dispatcher.dispatch_withdrawals ~source state block)

let reject_bad_commitment state commitment =
  let open Lwt_result_syntax in
  match state.State.signers.rejection with
  | None -> return_unit
  | Some source -> Accuser.reject_bad_commitment ~source state commitment

let fail_when_slashed (type kind) state l1_operation
    (result : kind manager_operation_result) =
  let open Lwt_result_syntax in
  let open Apply_results in
  match state.State.signers.operator with
  | None -> return_unit
  | Some operator -> (
      (* This function handles external operations only. Internal operations have
         to be handled in [handle] in [handle_l1_operation] below. *)
      match result with
      | Applied result ->
          let balance_updates =
            match result with
            | Tx_rollup_commit_result {balance_updates; _}
            | Tx_rollup_rejection_result {balance_updates; _} ->
                (* These are the only two operations which can slash a bond. *)
                balance_updates
            | _ -> []
          in
          let frozen_debit, punish =
            List.fold_left
              (fun (frozen_debit, punish) -> function
                | Receipt.(Tx_rollup_rejection_punishments, Credited _, _) ->
                    (* Someone was punished *)
                    (frozen_debit, true)
                | Frozen_bonds (committer, _), Debited _, _
                  when Contract.(committer = Implicit operator) ->
                    (* Our frozen bonds are gone *)
                    (true, punish)
                | _ -> (frozen_debit, punish))
              (false, false)
              balance_updates
          in
          fail_when
            (frozen_debit && punish)
            (Error.Tx_rollup_deposit_slashed l1_operation)
      | _ -> return_unit)

let process_op (type kind) (state : State.t) l1_block l1_operation ~source:_
    (op : kind manager_operation) (result : kind manager_operation_result)
    (acc : 'acc) : 'acc tzresult Lwt.t =
  let open Lwt_result_syntax in
  let is_my_rollup tx_rollup =
    Tx_rollup.equal state.rollup_info.rollup_id tx_rollup
  in
  let* () = fail_when_slashed state l1_operation result in
  (* This function handles external operations only. Internal operations have
     to be handled in [handle] in [handle_l1_operation] below. *)
  match (op, result) with
  | ( Tx_rollup_commit {commitment; tx_rollup},
      Applied (Tx_rollup_commit_result _) )
    when is_my_rollup tx_rollup ->
      let commitment_hash =
        Tx_rollup_commitment.(Compact.hash (Full.compact commitment))
      in
      let*! () =
        State.set_commitment_included
          state
          commitment_hash
          l1_block
          l1_operation
      in
      let* () = reject_bad_commitment state commitment in
      return acc
  | ( Tx_rollup_finalize_commitment {tx_rollup},
      Applied (Tx_rollup_finalize_commitment_result {level; _}) )
    when is_my_rollup tx_rollup ->
      let* () = dispatch_withdrawals_on_l1 state level in
      State.set_finalized_level state level
  | _, _ -> return acc

let rollback_op (type kind) (state : State.t) _l1_block _l1_operation ~source:_
    (op : kind manager_operation) (result : kind manager_operation_result)
    (acc : 'acc) : 'acc tzresult Lwt.t =
  let open Lwt_result_syntax in
  let is_my_rollup tx_rollup =
    Tx_rollup.equal state.rollup_info.rollup_id tx_rollup
  in
  (* This function handles external operations only. Internal operations have
     to be handled in [handle] in [handle_l1_operation] below. *)
  match (op, result) with
  | ( Tx_rollup_commit {commitment; tx_rollup},
      Applied (Tx_rollup_commit_result _) )
    when is_my_rollup tx_rollup ->
      let commitment_hash =
        Tx_rollup_commitment.(Compact.hash (Full.compact commitment))
      in
      let*! () = State.unset_commitment_included state commitment_hash in
      return acc
  | ( Tx_rollup_finalize_commitment {tx_rollup},
      Applied (Tx_rollup_finalize_commitment_result {level; _}) )
    when is_my_rollup tx_rollup -> (
      match Tx_rollup_level.pred level with
      | None ->
          let*! () = State.delete_finalized_level state in
          return_unit
      | Some level -> State.set_finalized_level state level)
  | _, _ -> return acc

let handle_l1_operation direction (block : Alpha_block_services.block_info)
    state acc (operation : Alpha_block_services.operation) =
  let open Lwt_result_syntax in
  let handle_op =
    match direction with `Rollback -> rollback_op | `Process -> process_op
  in
  let handle :
      type kind.
      source:public_key_hash ->
      kind manager_operation ->
      kind manager_operation_result ->
      packed_internal_operation_result list ->
      'acc ->
      'acc tzresult Lwt.t =
   fun ~source op result _internal_operation_results acc ->
    handle_op state ~source block.hash operation.hash op result acc
   (* There are no messages to handle for internal operations for now. *)
  in
  let rec handle_list :
      type kind. 'acc -> kind contents_and_result_list -> 'acc tzresult Lwt.t =
   fun acc -> function
    | Single_and_result
        ( Manager_operation {operation; source; _},
          Manager_operation_result
            {operation_result; internal_operation_results; _} ) ->
        handle ~source operation operation_result internal_operation_results acc
    | Single_and_result (_, _) -> return acc
    | Cons_and_result
        ( Manager_operation {operation; source; _},
          Manager_operation_result
            {operation_result; internal_operation_results; _},
          rest ) ->
        let* acc =
          handle
            ~source
            operation
            operation_result
            internal_operation_results
            acc
        in
        handle_list acc rest
  in
  match (operation.protocol_data, operation.receipt) with
  | _, Receipt No_operation_metadata | _, Empty | _, Too_large ->
      fail [Tx_rollup_no_operation_metadata operation.hash]
  | ( Operation_data {contents = operation_contents; _},
      Receipt (Operation_metadata {contents = result_contents}) ) -> (
      match kind_equal_list operation_contents result_contents with
      | None ->
          let*! () = Debug_events.(emit should_not_happen) __LOC__ in
          return acc
      | Some Eq ->
          let operation_and_result =
            pack_contents_list operation_contents result_contents
          in
          handle_list acc operation_and_result)

let handle_l1_block direction state acc block =
  List.fold_left_es
    (List.fold_left_es (handle_l1_operation direction block state))
    acc
    block.Alpha_block_services.operations

let handle_l1_reorg state acc reorg =
  let open Lwt_result_syntax in
  let* acc =
    List.fold_left_es
      (handle_l1_block `Rollback state)
      acc
      (List.rev reorg.Injector_common.old_chain)
  in
  let* acc =
    List.fold_left_es
      (handle_l1_block `Process state)
      acc
      reorg.Injector_common.new_chain
  in
  return acc

let notify_synchronized state =
  let old_value = state.State.sync.synchronized in
  state.State.sync.synchronized <- true ;
  if old_value = false then
    Lwt_condition.broadcast state.State.sync.on_synchronized ()

let process_head ?(notify_sync = true) state
    (current_hash, (current_header : Tezos_base.Block_header.t option)) =
  let open Lwt_result_syntax in
  (if notify_sync then
   match current_header with
   | None -> ()
   | Some current_header ->
       State.set_known_tezos_level state current_header.shell.level) ;
  let*! () = Event.(emit new_block) current_hash in
  let* _, _, blocks_to_commit = process_block state current_hash in
  let* l1_reorg = State.set_tezos_head state current_hash in
  if notify_sync then notify_synchronized state ;
  let* () = handle_l1_reorg state () l1_reorg in
  let* () = List.iter_es (commit_block_on_l1 state) blocks_to_commit in
  let* () = batch () in
  let* () = queue_gc_operations state in
  let* () = notify_head state current_hash l1_reorg in
  let*! () =
    match current_header with
    | None -> Lwt.return_unit
    | Some current_header -> trigger_injection state current_header
  in
  return_unit

let look_for_origination_block state block_list =
  let open Lwt_result_syntax in
  let rollup_id = state.State.rollup_info.rollup_id in
  state.State.sync.synchronized <- false ;
  let rec loop = function
    | [] -> return_none
    | block_hash :: rest as block_list ->
        let* block = State.fetch_tezos_block state block_hash in
        let*! () =
          Event.(emit look_for_origination)
            (block.hash, block.header.shell.level)
        in
        if originated_in_block rollup_id block then return_some block_list
        else (
          State.notify_processed_tezos_level state block.header.shell.level ;
          loop rest)
  in
  loop block_list

let catch_up_on_commitments state =
  let open Lwt_result_syntax in
  let*! () = Event.(emit catch_up_commitments) () in
  let* proto_rollup_state =
    Protocol.Tx_rollup_services.state
      state.State.cctxt
      (state.State.cctxt#chain, `Head 0)
      state.State.rollup_info.rollup_id
  and* tezos_head =
    Shell_services.Blocks.Header.shell_header
      state.State.cctxt
      ~chain:state.State.cctxt#chain
      ~block:(`Head 0)
      ()
  in
  (* TODO/TORU: https://gitlab.com/tezos/tezos/-/issues/2957
     We have to serialize the state to access the required information *)
  let proto_rollup_state =
    let open Data_encoding.Binary in
    to_bytes_exn Tx_rollup_state.encoding proto_rollup_state
    |> of_bytes_exn Tx_rollup_state_repr.encoding
  in
  let next_commitment_level =
    match
      Tx_rollup_state_repr.next_commitment_level
        proto_rollup_state
        (* Next commitment will be included in next block *)
        Raw_level_repr.(succ @@ of_int32_exn tezos_head.level)
    with
    | Ok l -> Some l
    | Error _ ->
        (* TODO/TORU: https://gitlab.com/tezos/tezos/-/issues/2957
           We assume the error is Tx_rollup_errors.No_uncommitted_inbox as we
           cannot match on it. *)
        None
  in
  match next_commitment_level with
  | None -> return_unit
  | Some next_commitment_level ->
      let rec missing_commitments to_commit block =
        let open Lwt_syntax in
        match block with
        | None -> return to_commit
        | Some ({L2block.header = {level; _}; _} as block) ->
            if
              Tx_rollup_level.to_int32 level
              < Tx_rollup_level_repr.to_int32 next_commitment_level
            then
              (* We have iterated over all missing commitments *)
              return to_commit
            else
              let*! predecessor =
                Option.filter_map_s
                  (State.get_block state)
                  block.header.predecessor
              in
              missing_commitments (block :: to_commit) predecessor
      in
      let head = State.get_head state in
      let*! to_commit = missing_commitments [] head in
      List.iter_es (commit_block_on_l1 state) to_commit

let catch_up_on_blocks (state : State.t) origination_level =
  let open Lwt_result_syntax in
  let* head = Alpha_block_services.Header.shell_header state.cctxt () in
  let* last_tezos_block = State.get_tezos_head state in
  let first_handle_level =
    match last_tezos_block with
    | Some b -> Some (Int32.succ b.header.shell.level)
    | None -> origination_level
  in
  match first_handle_level with
  | None -> return_unit
  | Some first_handle_level ->
      let missing_levels =
        Int32.to_int head.level - Int32.to_int first_handle_level + 1
      in
      let*! () = Event.(emit missing_blocks) missing_levels in
      if missing_levels <= 0 then return_unit
      else
        let* missing_blocks =
          Chain_services.Blocks.list state.cctxt ~length:missing_levels ()
        in
        let missing_blocks =
          match missing_blocks with
          | missing_blocks :: _ -> List.rev missing_blocks
          | [] -> []
        in
        State.set_known_tezos_level state head.level ;
        let* missing_blocks =
          match State.get_head state with
          | Some _ -> return missing_blocks
          | None -> (
              (* No L2 blocks processed yet, look for origination first *)
              let* missing_blocks =
                look_for_origination_block state missing_blocks
              in
              match missing_blocks with
              | None -> tzfail Tx_rollup_originated_in_fork
              | Some missing_blocks -> return missing_blocks)
        in
        let+ () =
          List.iter_es
            (fun block ->
              let*! res = process_head ~notify_sync:false state (block, None) in
              match res with
              | Error (Tx_rollup_originated_in_fork :: _) -> return_unit
              | _ -> Lwt.return res)
            missing_blocks
        in
        notify_synchronized state

let catch_up state =
  let open Lwt_result_syntax in
  let* () = catch_up_on_commitments state in
  catch_up_on_blocks state state.State.rollup_info.origination_level
(* TODO/TORU: https://gitlab.com/tezos/tezos/-/issues/2958
   We may also need to catch up on finalization/removal of commitments here. *)

let check_operator_deposit state config =
  let open Lwt_result_syntax in
  match state.State.signers.operator with
  | None ->
      (* No operator for this node, no commitments will be made. *)
      return_unit
  | Some operator ->
      let* has_deposit =
        Plugin.RPC.Tx_rollup.has_bond
          state.State.cctxt
          (state.State.cctxt#chain, `Head 0)
          state.State.rollup_info.rollup_id
          operator
      in
      if has_deposit then
        (* The operator already has a deposit for this rollup, no other check
           necessary. *)
        return_unit
      else
        (* Operator never made a deposit for this rollup, ensure they are ready to
           make one. *)
        fail_unless
          config.Node_config.allow_deposit
          Error.Tx_rollup_deposit_not_allowed

let main_exit_callback state rpc_server _exit_status =
  let open Lwt_syntax in
  let* () = state.State.cctxt#message "Stopping RPC server ..." in
  let* () = RPC_server.shutdown rpc_server in
  let* () = state.State.cctxt#message "Stopping injector ..." in
  let* () = Injector.shutdown () in
  let* () = state.State.cctxt#message "Stopping batcher ..." in
  let* () = Batcher.shutdown () in
  let* () = state.State.cctxt#message "Closing stores ..." in
  let* () = Stores.close state.State.stores in
  let* () = state.State.cctxt#message "Closing context ..." in
  let* () = Context.close state.State.context_index in
  let* () = state.State.cctxt#message "Shutting down" in
  return_unit

let rec connect ~delay cctxt =
  let open Lwt_syntax in
  let* res = Monitor_services.heads cctxt cctxt#chain in
  match res with
  | Ok (stream, stopper) -> return_ok (stream, stopper)
  | Error _ ->
      let* () = Event.(emit cannot_connect) delay in
      let* () = Lwt_unix.sleep delay in
      connect ~delay cctxt

let is_connection_error trace =
  List.exists
    (function
      | RPC_client_errors.(Request_failed {error = Connection_failed _; _}) ->
          true
      | _ -> false)
    trace

(* TODO/TORU: https://gitlab.com/tezos/tezos/-/issues/1845
   Clean exit *)
let run configuration cctxt =
  let open Lwt_result_syntax in
  let*! () = Event.(emit starting_node) () in
  let {Node_config.signers; reconnection_delay; rollup_id; batch_burn_limit; _}
      =
    configuration
  in
  let* state = State.init cctxt configuration in
  let* () = check_operator_deposit state configuration in
  let* () =
    Injector.init
      state.cctxt
      ~data_dir:configuration.data_dir
      state
      ~signers:
        (List.filter_map
           (function
             | None, _, _ -> None
             | Some x, strategy, tags -> Some (x, strategy, tags))
           [
             (signers.operator, `Each_block, [Injector.Commitment]);
             (* Batches of L2 operations are submitted with a delay after each
                block, to allow for more operations to arrive and be included in
                the following block. *)
             (signers.submit_batch, `Delay_block, [Submit_batch]);
             (signers.finalize_commitment, `Each_block, [Finalize_commitment]);
             (signers.remove_commitment, `Each_block, [Remove_commitment]);
             (signers.rejection, `Each_block, [Rejection]);
             (signers.dispatch_withdrawals, `Each_block, [Dispatch_withdrawals]);
           ])
  in
  let* () =
    Option.iter_es
      (fun signer ->
        Batcher.init
          ~rollup:rollup_id
          ~signer
          ~batch_burn_limit
          state.State.context_index
          state.State.constants)
      signers.submit_batch
  in
  let* rpc_server = RPC.start_server configuration state in
  let _ =
    (* Register cleaner callback *)
    Lwt_exit.register_clean_up_callback
      ~loc:__LOC__
      (main_exit_callback state rpc_server)
  in
  let*! () = Event.(emit node_is_ready) () in
  let* () = catch_up state in
  let rec loop () =
    let* () =
      Lwt.catch
        (fun () ->
          let* block_stream, interupt =
            connect ~delay:reconnection_delay cctxt
          in
          let*! () =
            Lwt_stream.iter_s
              (fun (head, header) ->
                let*! r = process_head state (head, Some header) in
                match r with
                | Ok _ -> Lwt.return ()
                | Error trace when is_connection_error trace ->
                    Format.eprintf
                      "@[<v 2>Connection error:@ %a@]@."
                      pp_print_trace
                      trace ;
                    interupt () ;
                    Lwt.return ()
                | Error e ->
                    Format.eprintf "%a@.Exiting.@." pp_print_trace e ;
                    Lwt_exit.exit_and_raise 1)
              block_stream
          in
          let*! () = Event.(emit connection_lost) () in
          loop ())
        fail_with_exn
    in
    Lwt_utils.never_ending ()
  in
  loop ()
