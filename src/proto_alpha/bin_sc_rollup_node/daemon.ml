(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

module Make (PVM : Pvm.S) = struct
  module Components = Components.Make (PVM)
  open Protocol
  open Alpha_context
  open Apply_results

  (** Process an L1 SCORU operation (for the node's rollup) which is included
      for the first time. {b Note}: this function does not process inboxes for
      the rollup, which is done instead by {!Inbox.process_head}. *)
  let process_included_l1_operation (type kind) (node_ctxt : Node_context.rw)
      head ~source (operation : kind manager_operation)
      (result : kind successful_manager_operation_result) =
    let open Lwt_result_syntax in
    match (operation, result) with
    | ( Sc_rollup_publish {commitment; _},
        Sc_rollup_publish_result {published_at_level; _} )
      when Node_context.is_operator node_ctxt source ->
        (* Published commitment --------------------------------------------- *)
        let save_lpc =
          match node_ctxt.lpc with
          | None -> true
          | Some lpc -> Raw_level.(commitment.inbox_level >= lpc.inbox_level)
        in
        if save_lpc then node_ctxt.lpc <- Some commitment ;
        let commitment_hash =
          Sc_rollup.Commitment.hash_uncarbonated commitment
        in
        let*! () =
          Store.Commitments_published_at_level.add
            node_ctxt.store
            commitment_hash
            {
              first_published_at_level = published_at_level;
              published_at_level = Raw_level.of_int32_exn head.Layer1.level;
            }
        in

        return_unit
    | Sc_rollup_cement {commitment; _}, Sc_rollup_cement_result {inbox_level; _}
      ->
        (* Cemented commitment ---------------------------------------------- *)
        let* inbox_block_hash =
          State.hash_of_level node_ctxt (Raw_level.to_int32 inbox_level)
        in
        let*! inbox_block =
          Store.L2_blocks.get node_ctxt.store inbox_block_hash
        in
        let*? () =
          (* We stop the node if we disagree with a cemented commitment *)
          error_unless
            (Option.equal
               Sc_rollup.Commitment.Hash.( = )
               inbox_block.header.commitment_hash
               (Some commitment))
            (Sc_rollup_node_errors.Disagree_with_cemented
               {
                 inbox_level;
                 ours = inbox_block.header.commitment_hash;
                 on_l1 = commitment;
               })
        in
        let*! () =
          if Raw_level.(inbox_level > node_ctxt.lcc.level) then (
            node_ctxt.lcc <- {commitment; level = inbox_level} ;
            Commitment_event.last_cemented_commitment_updated
              commitment
              inbox_level)
          else Lwt.return_unit
        in
        return_unit
    | ( Sc_rollup_refute _,
        Sc_rollup_refute_result
          {game_status = Ended (Loser {reason; loser}); balance_updates; _} )
      when Node_context.is_operator node_ctxt loser ->
        let*? slashed_amount =
          List.fold_left_e
            (fun slashed -> function
              | ( Receipt.Sc_rollup_refutation_punishments,
                  Receipt.Credited amount,
                  _ ) ->
                  Environment.wrap_tzresult Tez.(slashed +? amount)
              | _ -> Ok slashed)
            Tez.zero
            balance_updates
        in
        tzfail (Sc_rollup_node_errors.Lost_game (loser, reason, slashed_amount))
    | Dal_publish_slot_header _, Dal_publish_slot_header_result {slot_header; _}
      ->
        assert (Node_context.dal_enabled node_ctxt) ;
        let*! () =
          Store.Dal_slots_headers.add
            node_ctxt.store
            ~primary_key:head.Layer1.hash
            ~secondary_key:slot_header.id.index
            slot_header
        in
        return_unit
    | _, _ ->
        (* Other manager operations *)
        return_unit

  (** Process an L1 SCORU operation (for the node's rollup) which is finalized
      for the first time. *)
  let process_finalized_l1_operation (type kind) _node_ctxt _head ~source:_
      (_operation : kind manager_operation)
      (_result : kind successful_manager_operation_result) =
    return_unit

  let process_l1_operation (type kind) ~finalized node_ctxt head ~source
      (operation : kind manager_operation)
      (result : kind Apply_results.manager_operation_result) =
    let open Lwt_result_syntax in
    let is_for_my_rollup : type kind. kind manager_operation -> bool = function
      | Sc_rollup_add_messages _ -> true
      | Sc_rollup_cement {rollup; _}
      | Sc_rollup_publish {rollup; _}
      | Sc_rollup_refute {rollup; _}
      | Sc_rollup_timeout {rollup; _}
      | Sc_rollup_execute_outbox_message {rollup; _}
      | Sc_rollup_recover_bond {sc_rollup = rollup; staker = _} ->
          Sc_rollup.Address.(rollup = node_ctxt.Node_context.rollup_address)
      | Dal_publish_slot_header _ -> true
      | Reveal _ | Transaction _ | Origination _ | Delegation _
      | Update_consensus_key _ | Register_global_constant _
      | Set_deposits_limit _ | Increase_paid_storage _ | Tx_rollup_origination
      | Tx_rollup_submit_batch _ | Tx_rollup_commit _ | Tx_rollup_return_bond _
      | Tx_rollup_finalize_commitment _ | Tx_rollup_remove_commitment _
      | Tx_rollup_rejection _ | Tx_rollup_dispatch_tickets _ | Transfer_ticket _
      | Sc_rollup_originate _ | Zk_rollup_origination _ | Zk_rollup_publish _
      | Zk_rollup_update _ ->
          false
    in
    if not (is_for_my_rollup operation) then return_unit
    else
      (* Only look at operations that are for the node's rollup *)
      let*! () = Daemon_event.included_operation ~finalized operation result in
      match result with
      | Applied success_result ->
          let process =
            if finalized then process_finalized_l1_operation
            else process_included_l1_operation
          in
          process node_ctxt head ~source operation success_result
      | _ ->
          (* No action for non successful operations  *)
          return_unit

  let process_l1_block_operations ~finalized node_ctxt
      (Layer1.{hash; _} as head) =
    let open Lwt_result_syntax in
    let* block = Layer1.fetch_tezos_block node_ctxt.Node_context.l1_ctxt hash in
    let apply (type kind) accu ~source (operation : kind manager_operation)
        result =
      let open Lwt_result_syntax in
      let* () = accu in
      process_l1_operation ~finalized node_ctxt head ~source operation result
    in
    let apply_internal (type kind) accu ~source:_
        (_operation : kind Apply_internal_results.internal_operation)
        (_result : kind Apply_internal_results.internal_operation_result) =
      accu
    in
    let* () =
      Layer1_services.process_manager_operations
        return_unit
        block.operations
        {apply; apply_internal}
    in
    return_unit

  let before_origination (node_ctxt : _ Node_context.t) Layer1.{level; _} =
    let origination_level = Raw_level.to_int32 node_ctxt.genesis_info.level in
    level < origination_level

  let rec processed_finalized_block (node_ctxt : _ Node_context.t)
      Layer1.({hash; level} as block) =
    let open Lwt_result_syntax in
    let*! last_finalized = State.get_finalized_head_opt node_ctxt.store in
    let already_finalized =
      match last_finalized with
      | Some finalized -> level <= Raw_level.to_int32 finalized.header.level
      | None -> false
    in
    unless (already_finalized || before_origination node_ctxt block)
    @@ fun () ->
    let* predecessor = Layer1.get_predecessor_opt node_ctxt.l1_ctxt block in
    let* () =
      Option.iter_es (processed_finalized_block node_ctxt) predecessor
    in
    let*! () = Daemon_event.head_processing hash level ~finalized:true in
    let* () = process_l1_block_operations ~finalized:true node_ctxt block in
    let*! () = State.mark_finalized_head node_ctxt.store hash in
    return_unit

  let process_head (node_ctxt : _ Node_context.t) Layer1.({hash; level} as head)
      =
    let open Lwt_result_syntax in
    let*! () = Daemon_event.head_processing hash level ~finalized:false in
    let*! () = State.save_level node_ctxt.store head in
    let* inbox_hash, inbox, inbox_witness, messages, ctxt =
      Inbox.process_head node_ctxt head
    in
    let* () =
      when_ (Node_context.dal_enabled node_ctxt) @@ fun () ->
      Dal_slots_tracker.process_head node_ctxt head
    in
    let* () = process_l1_block_operations ~finalized:false node_ctxt head in
    (* Avoid storing and publishing commitments if the head is not final. *)
    (* Avoid triggering the pvm execution if this has been done before for
       this head. *)
    let* ctxt, _num_messages, num_ticks, initial_tick =
      Components.Interpreter.process_head node_ctxt ctxt head (inbox, messages)
    in
    let*! context_hash = Context.commit ctxt in
    let* {Layer1.hash = predecessor; _} =
      Layer1.get_predecessor node_ctxt.l1_ctxt head
    in
    let* commitment_hash =
      Components.Commitment.process_head node_ctxt ~predecessor head ctxt
    in
    let level = Raw_level.of_int32_exn level in
    let* previous_commitment_hash =
      if level = node_ctxt.genesis_info.Sc_rollup.Commitment.level then
        (* Previous commitment for rollup genesis is itself. *)
        return node_ctxt.genesis_info.Sc_rollup.Commitment.commitment_hash
      else
        let*! pred = Store.L2_blocks.find node_ctxt.store predecessor in
        match pred with
        | None ->
            failwith
              "Missing L2 predecessor %a for previous commitment"
              Block_hash.pp
              predecessor
        | Some pred ->
            return (Sc_rollup_block.most_recent_commitment pred.header)
    in
    let header =
      Sc_rollup_block.
        {
          block_hash = hash;
          level;
          predecessor;
          commitment_hash;
          previous_commitment_hash;
          context = context_hash;
          inbox_witness;
          inbox_hash;
        }
    in
    let l2_block =
      Sc_rollup_block.{header; content = (); num_ticks; initial_tick}
    in
    let* finalized_block, _ =
      Layer1.nth_predecessor
        node_ctxt.l1_ctxt
        node_ctxt.block_finality_time
        head
    in
    let* () = processed_finalized_block node_ctxt finalized_block in
    let*! () = State.save_l2_block node_ctxt.store l2_block in
    let*! () =
      Daemon_event.new_head_processed hash (Raw_level.to_int32 level)
    in
    return_unit

  let notify_injector {Node_context.l1_ctxt; _} new_head
      (reorg : Layer1.head Injector_common.reorg) =
    let open Lwt_result_syntax in
    let open Layer1 in
    let* new_chain =
      List.map_ep
        (fun {hash; _} -> fetch_tezos_block l1_ctxt hash)
        reorg.new_chain
    and* old_chain =
      List.map_ep
        (fun {hash; _} -> fetch_tezos_block l1_ctxt hash)
        reorg.old_chain
    in
    let*! () = Injector.new_tezos_head new_head {new_chain; old_chain} in
    return_unit

  (* [on_layer_1_head node_ctxt head] processes a new head from the L1. It
     also processes any missing blocks that were not processed. Every time a
     head is processed we also process head~2 as finalized (which may recursively
     imply the processing of head~3, etc). *)
  let on_layer_1_head node_ctxt head =
    let open Lwt_result_syntax in
    let*! old_head =
      State.last_processed_head_opt node_ctxt.Node_context.store
    in
    let old_head =
      match old_head with
      | Some h ->
          `Head
            Layer1.
              {
                hash = h.header.block_hash;
                level = Raw_level.to_int32 h.header.level;
              }
      | None ->
          (* if no head has been processed yet, we want to handle all blocks
             since, and including, the rollup origination. *)
          let origination_level =
            Raw_level.to_int32 node_ctxt.genesis_info.level
          in
          `Level (Int32.pred origination_level)
    in
    let* reorg =
      Layer1.get_tezos_reorg_for_new_head node_ctxt.l1_ctxt old_head head
    in
    (* TODO: https://gitlab.com/tezos/tezos/-/issues/3348
       Rollback state information on reorganization, i.e. for
       reorg.old_chain. *)
    let* new_head =
      Layer1.fetch_tezos_block node_ctxt.l1_ctxt head.Layer1.hash
    in
    let header =
      Block_header.(
        raw
          {
            shell = new_head.header.shell;
            protocol_data = new_head.header.protocol_data;
          })
    in
    let*! () = Daemon_event.processing_heads_iteration reorg.new_chain in
    let* () = List.iter_es (process_head node_ctxt) reorg.new_chain in
    let* () = Components.Commitment.publish_commitments node_ctxt in
    let* () = Components.Commitment.cement_commitments node_ctxt in
    let* () = notify_injector node_ctxt new_head reorg in
    let*! () = Daemon_event.new_heads_processed reorg.new_chain in
    let* () = Components.Refutation_game.process head node_ctxt in
    let* () = Components.Batcher.batch () in
    let* () = Components.Batcher.new_head head in
    let*! () = Injector.inject ~header () in
    return_unit

  let is_connection_error trace =
    TzTrace.fold
      (fun yes error ->
        yes
        ||
        match error with
        | Tezos_rpc_http.RPC_client_errors.(
            Request_failed {error = Connection_failed _; _}) ->
            true
        | _ -> false)
      false
      trace

  (* TODO: https://gitlab.com/tezos/tezos/-/issues/2895
     Use Lwt_stream.fold_es once it is exposed. *)
  let daemonize configuration (node_ctxt : _ Node_context.t) =
    let open Lwt_result_syntax in
    let rec loop (l1_ctxt : Layer1.t) =
      let*! () =
        Lwt_stream.iter_s
          (fun head ->
            let open Lwt_syntax in
            let* res = on_layer_1_head node_ctxt head in
            match res with
            | Ok () -> return_unit
            | Error trace when is_connection_error trace ->
                Format.eprintf
                  "@[<v 2>Connection error:@ %a@]@."
                  pp_print_trace
                  trace ;
                l1_ctxt.stopper () ;
                return_unit
            | Error e ->
                Format.eprintf "%a@.Exiting.@." pp_print_trace e ;
                let* _ = Lwt_exit.exit_and_wait 1 in
                return_unit)
          l1_ctxt.heads
      in
      let*! () = Event.connection_lost () in
      let* l1_ctxt =
        Layer1.reconnect configuration node_ctxt.l1_ctxt node_ctxt.store
      in
      loop l1_ctxt
    in
    protect @@ fun () -> Lwt.no_cancel @@ loop node_ctxt.l1_ctxt

  let install_finalizer {Node_context.l1_ctxt; store; _} rpc_server =
    let open Lwt_syntax in
    Lwt_exit.register_clean_up_callback ~loc:__LOC__ @@ fun exit_status ->
    let message = l1_ctxt.cctxt#message in
    let* () = message "Shutting down L1@." in
    let* () = Layer1.shutdown l1_ctxt in
    let* () = message "Shutting down RPC server@." in
    let* () = Components.RPC_server.shutdown rpc_server in
    let* () = message "Shutting down Injector@." in
    let* () = Injector.shutdown () in
    let* () = message "Shutting down Batcher@." in
    let* () = Components.Batcher.shutdown () in
    let* () = message "Closing store@." in
    let* () = Store.close store in
    let* () = Event.shutdown_node exit_status in
    Tezos_base_unix.Internal_event_unix.close ()

  let check_initial_state_hash {Node_context.cctxt; rollup_address; _} =
    let open Lwt_result_syntax in
    let* l1_reference_initial_state_hash =
      RPC.Sc_rollup.initial_pvm_state_hash
        cctxt
        (cctxt#chain, cctxt#block)
        rollup_address
    in
    let*! s = PVM.initial_state ~empty:(PVM.State.empty ()) in
    let*! l2_initial_state_hash = PVM.state_hash s in
    if
      not
        Sc_rollup.State_hash.(
          l1_reference_initial_state_hash = l2_initial_state_hash)
    then
      let*! () =
        Daemon_event.wrong_initial_pvm_state_hash
          l2_initial_state_hash
          l1_reference_initial_state_hash
      in
      Lwt_exit.exit_and_raise 1
    else return_unit

  let run node_ctxt configuration =
    let open Lwt_result_syntax in
    let* () = check_initial_state_hash node_ctxt in
    let start () =
      let* rpc_server = Components.RPC_server.start node_ctxt configuration in
      let (_ : Lwt_exit.clean_up_callback_id) =
        install_finalizer node_ctxt rpc_server
      in
      let*! () = Inbox.start () in
      let*! () = Components.Commitment.start () in
      let signers =
        Configuration.Operator_purpose_map.bindings node_ctxt.operators
        |> List.fold_left
             (fun acc (purpose, operator) ->
               let purposes =
                 match Signature.Public_key_hash.Map.find operator acc with
                 | None -> [purpose]
                 | Some ps -> purpose :: ps
               in
               Signature.Public_key_hash.Map.add operator purposes acc)
             Signature.Public_key_hash.Map.empty
        |> Signature.Public_key_hash.Map.bindings
        |> List.map (fun (operator, purposes) ->
               let strategy =
                 match purposes with
                 | [Configuration.Add_messages] -> `Delay_block 0.5
                 | _ -> `Each_block
               in
               (operator, strategy, purposes))
      in
      let* () =
        Injector.init
          node_ctxt.cctxt
          (Node_context.readonly node_ctxt)
          ~data_dir:node_ctxt.data_dir
          ~signers
          ~retention_period:configuration.injector_retention_period
      in
      let* () =
        match
          Configuration.Operator_purpose_map.find
            Add_messages
            node_ctxt.operators
        with
        | None -> return_unit
        | Some signer ->
            Components.Batcher.init configuration.batcher ~signer node_ctxt
      in
      Lwt.dont_wait
        (fun () ->
          let*! r = Metrics.metrics_serve configuration.metrics_addr in
          match r with
          | Ok () -> Lwt.return_unit
          | Error err ->
              Event.(metrics_ended (Format.asprintf "%a" pp_print_trace err)))
        (fun exn -> Event.(metrics_ended_dont_wait (Printexc.to_string exn))) ;

      let*! () =
        Event.node_is_ready
          ~rpc_addr:configuration.rpc_addr
          ~rpc_port:configuration.rpc_port
      in
      daemonize configuration node_ctxt
    in
    Metrics.Info.init_rollup_node_info
      ~id:node_ctxt.rollup_address
      ~mode:configuration.mode
      ~genesis_level:node_ctxt.genesis_info.level
      ~genesis_hash:node_ctxt.genesis_info.commitment_hash
      ~pvm_kind:node_ctxt.kind ;
    start ()
end

let run ~data_dir (configuration : Configuration.t)
    (cctxt : Protocol_client_context.full) =
  let open Lwt_result_syntax in
  Random.self_init () (* Initialize random state (for reconnection delays) *) ;
  let*! () = Event.starting_node () in
  let dal_cctxt =
    Dal_node_client.make_unix_cctxt
      ~addr:configuration.dal_node_addr
      ~port:configuration.dal_node_port
  in
  let open Configuration in
  let* () =
    (* Check that the operators are valid keys. *)
    Operator_purpose_map.iter_es
      (fun _purpose operator ->
        let+ _pkh, _pk, _skh = Client_keys.get_key cctxt operator in
        ())
      configuration.sc_rollup_node_operators
  in
  let*! store =
    Store.load Read_write Configuration.(default_storage_dir data_dir)
  in
  let*! context =
    Context.load Read_write (Configuration.default_context_dir data_dir)
  in
  let* l1_ctxt, kind = Layer1.start configuration cctxt store in
  let* node_ctxt =
    Node_context.init
      cctxt
      dal_cctxt
      ~data_dir
      l1_ctxt
      configuration.sc_rollup_address
      kind
      configuration.sc_rollup_node_operators
      configuration.fee_parameters
      ~loser_mode:configuration.loser_mode
      store
      context
  in
  let module Daemon = Make ((val Components.pvm_of_kind node_ctxt.kind)) in
  Daemon.run node_ctxt configuration
