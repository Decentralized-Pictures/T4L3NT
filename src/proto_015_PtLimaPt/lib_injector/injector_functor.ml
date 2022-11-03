(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Protocol_client_context
open Protocol
open Alpha_context
open Injector_common
open Injector_worker_types
open Injector_sigs
open Injector_errors

(* This is the Tenderbake finality for blocks. *)
(* TODO: https://gitlab.com/tezos/tezos/-/issues/2815
   Centralize this and maybe make it configurable. *)
let confirmations = 2

type injection_strategy = [`Each_block | `Delay_block]

(* TODO/TORU: https://gitlab.com/tezos/tezos/-/issues/2755
   Persist injector data on disk *)

(** Builds a client context from another client context but uses logging instead
    of printing on stdout directly. This client context cannot make the injector
    exit. *)
let injector_context (cctxt : #Protocol_client_context.full) =
  let log _channel msg = Logs_lwt.info (fun m -> m "%s" msg) in
  object
    inherit
      Protocol_client_context.wrap_full
        (new Client_context.proxy_context (cctxt :> Client_context.full))

    inherit! Client_context.simple_printer log

    method! exit code =
      Format.ksprintf Stdlib.failwith "Injector client wants to exit %d" code
  end

module Make (Rollup : PARAMETERS) = struct
  module Tags = Injector_tags.Make (Rollup.Tag)
  module Tags_table = Hashtbl.Make (Rollup.Tag)

  module Op_queue =
    Disk_persistence.Make_queue
      (struct
        let name = "operations_queue"
      end)
      (L1_operation.Hash)
      (L1_operation)

  (** Information stored about an L1 operation that was injected on a Tezos
      node. *)
  type injected_info = {
    op : L1_operation.t;  (** The L1 manager operation. *)
    oph : Operation_hash.t;
        (** The hash of the operation which contains [op] (this can be an L1 batch of
          several manager operations). *)
  }

  module Injected_operations = Disk_persistence.Make_table (struct
    include L1_operation.Hash.Table

    type value = injected_info

    let name = "injected_operations"

    let string_of_key = L1_operation.Hash.to_b58check

    let key_of_string = L1_operation.Hash.of_b58check_opt

    let value_encoding =
      let open Data_encoding in
      conv (fun {op; oph} -> (oph, op)) (fun (oph, op) -> {op; oph})
      @@ merge_objs
           (obj1 (req "oph" Operation_hash.encoding))
           L1_operation.encoding
  end)

  module Injected_ophs = Disk_persistence.Make_table (struct
    include Operation_hash.Table

    type value = L1_operation.Hash.t list

    let name = "injected_ophs"

    let string_of_key = Operation_hash.to_b58check

    let key_of_string = Operation_hash.of_b58check_opt

    let value_encoding = Data_encoding.list L1_operation.Hash.encoding
  end)

  (** The part of the state which gathers information about injected
    operations (but not included). *)
  type injected_state = {
    injected_operations : Injected_operations.t;
        (** A table mapping L1 manager operation hashes to the injection info for that
          operation.  *)
    injected_ophs : Injected_ophs.t;
        (** A mapping of all L1 manager operations contained in a L1 batch (i.e. an L1
          operation). *)
  }

  (** Information stored about an L1 operation that was included in a Tezos
    block. *)
  type included_info = {
    op : L1_operation.t;  (** The L1 manager operation. *)
    oph : Operation_hash.t;
        (** The hash of the operation which contains [op] (this can be an L1 batch of
          several manager operations). *)
    l1_block : Block_hash.t;
        (** The hash of the L1 block in which the operation was included. *)
    l1_level : int32;  (** The level of [l1_block]. *)
  }

  module Included_operations = Disk_persistence.Make_table (struct
    include L1_operation.Hash.Table

    type value = included_info

    let name = "included_operations"

    let string_of_key = L1_operation.Hash.to_b58check

    let key_of_string = L1_operation.Hash.of_b58check_opt

    let value_encoding =
      let open Data_encoding in
      conv
        (fun {op; oph; l1_block; l1_level} -> (op, (oph, l1_block, l1_level)))
        (fun (op, (oph, l1_block, l1_level)) -> {op; oph; l1_block; l1_level})
      @@ merge_objs
           L1_operation.encoding
           (obj3
              (req "oph" Operation_hash.encoding)
              (req "l1_block" Block_hash.encoding)
              (req "l1_level" int32))
  end)

  module Included_in_blocks = Disk_persistence.Make_table (struct
    include Block_hash.Table

    type value = int32 * L1_operation.Hash.t list

    let name = "included_in_blocks"

    let string_of_key = Block_hash.to_b58check

    let key_of_string = Block_hash.of_b58check_opt

    let value_encoding =
      let open Data_encoding in
      obj2 (req "level" int32) (req "l1_ops" (list L1_operation.Hash.encoding))
  end)

  (** The part of the state which gathers information about
    operations which are included in the L1 chain (but not confirmed). *)
  type included_state = {
    included_operations : Included_operations.t;
    included_in_blocks : Included_in_blocks.t;
  }

  (** The internal state of each injector worker.  *)
  type state = {
    cctxt : Protocol_client_context.full;
        (** The client context which is used to perform the injections. *)
    signer : signer;  (** The signer for this worker. *)
    tags : Tags.t;
        (** The tags of this worker, for both informative and identification
          purposes. *)
    strategy : injection_strategy;
        (** The strategy of this worker for injecting the pending operations. *)
    save_dir : string;  (** Path to where save persistent state *)
    queue : Op_queue.t;
        (** The queue of pending operations for this injector. *)
    injected : injected_state;
        (** The information about injected operations. *)
    included : included_state;
        (** The information about included operations. {b Note}: Operations which
          are confirmed are simply removed from the state and do not appear
          anymore. *)
    rollup_node_state : Rollup.rollup_node_state;
        (** The state of the rollup node. *)
  }

  module Event = struct
    include Injector_events.Make (Rollup)

    let emit1 e state x = emit e (state.signer.pkh, state.tags, x)

    let emit2 e state x y = emit e (state.signer.pkh, state.tags, x, y)

    let emit3 e state x y z = emit e (state.signer.pkh, state.tags, x, y, z)
  end

  let init_injector cctxt ~data_dir rollup_node_state ~signer strategy tags =
    let open Lwt_result_syntax in
    let* signer = get_signer cctxt signer in
    let data_dir = Filename.concat data_dir "injector" in
    let*! () = Lwt_utils_unix.create_dir data_dir in
    let filter op_proj op =
      let {L1_operation.manager_operation = Manager op; _} = op_proj op in
      match Rollup.operation_tag op with
      | None -> false
      | Some t -> Tags.mem t tags
    in
    let warn_unreadable =
      (* Warn of corrupted files but don't fail *)
      Some
        (fun file error ->
          Event.(emit corrupted_operation_on_disk)
            (signer.pkh, tags, file, error))
    in
    let emit_event_loaded kind nb =
      Event.(emit loaded_from_disk) (signer.pkh, tags, nb, kind)
    in
    let* queue =
      Op_queue.load_from_disk
        ~warn_unreadable
        ~capacity:50_000
        ~data_dir
        ~filter:(filter (fun op -> op))
    in
    let*! () = emit_event_loaded "operations_queue" @@ Op_queue.length queue in
    (* Very coarse approximation for the number of operation we expect for each
       block *)
    let n =
      Tags.fold (fun t acc -> acc + Rollup.table_estimated_size t) tags 0
    in
    let* injected_operations =
      Injected_operations.load_from_disk
        ~warn_unreadable
        ~initial_size:n
        ~data_dir
        ~filter:(filter (fun (i : injected_info) -> i.op))
    in
    let*! () =
      emit_event_loaded "injected_operations"
      @@ Injected_operations.length injected_operations
    in

    let* included_operations =
      Included_operations.load_from_disk
        ~warn_unreadable
        ~initial_size:(confirmations * n)
        ~data_dir
        ~filter:(filter (fun (i : included_info) -> i.op))
    in
    let*! () =
      emit_event_loaded "included_operations"
      @@ Included_operations.length included_operations
    in
    let* injected_ophs =
      Injected_ophs.load_from_disk
        ~warn_unreadable
        ~initial_size:n
        ~data_dir
        ~filter:(List.exists (Injected_operations.mem injected_operations))
    in
    let*! () =
      emit_event_loaded "injected_ophs" @@ Injected_ophs.length injected_ophs
    in
    let* included_in_blocks =
      Included_in_blocks.load_from_disk
        ~warn_unreadable
        ~initial_size:(confirmations * n)
        ~data_dir
        ~filter:(fun (_, ops) ->
          List.exists (Included_operations.mem included_operations) ops)
    in
    let*! () =
      emit_event_loaded "included_in_blocks"
      @@ Included_in_blocks.length included_in_blocks
    in

    return
      {
        cctxt = injector_context (cctxt :> #Protocol_client_context.full);
        signer;
        tags;
        strategy;
        save_dir = data_dir;
        queue;
        injected = {injected_operations; injected_ophs};
        included = {included_operations; included_in_blocks};
        rollup_node_state;
      }

  (** Add an operation to the pending queue corresponding to the signer for this
    operation.  *)
  let add_pending_operation state op =
    let open Lwt_result_syntax in
    let*! () = Event.(emit1 add_pending) state op in
    Op_queue.replace state.queue op.L1_operation.hash op

  (** Mark operations as injected (in [oph]). *)
  let add_injected_operations state oph operations =
    let open Lwt_result_syntax in
    let infos =
      List.map (fun op -> (op.L1_operation.hash, {op; oph})) operations
    in
    let* () =
      Injected_operations.replace_seq
        state.injected.injected_operations
        (List.to_seq infos)
    in
    Injected_ophs.replace state.injected.injected_ophs oph (List.map fst infos)

  (** [add_included_operations state oph l1_block l1_level operations] marks the
    [operations] as included (in the L1 batch [oph]) in the Tezos block
    [l1_block] of level [l1_level]. *)
  let add_included_operations state oph l1_block l1_level operations =
    let open Lwt_result_syntax in
    let*! () =
      Event.(emit3 included)
        state
        l1_block
        l1_level
        (List.map (fun o -> o.L1_operation.hash) operations)
    in
    let infos =
      List.map
        (fun op -> (op.L1_operation.hash, {op; oph; l1_block; l1_level}))
        operations
    in
    let* () =
      Included_operations.replace_seq
        state.included.included_operations
        (List.to_seq infos)
    in
    Included_in_blocks.replace
      state.included.included_in_blocks
      l1_block
      (l1_level, List.map fst infos)

  (** [remove state oph] removes the operations that correspond to the L1 batch
    [oph] from the injected operations in the injector state. This function is
    used to move operations from injected to included. *)
  let remove_injected_operation state oph =
    let open Lwt_result_syntax in
    match Injected_ophs.find state.injected.injected_ophs oph with
    | None ->
        (* Nothing removed *)
        return []
    | Some mophs ->
        let* () = Injected_ophs.remove state.injected.injected_ophs oph in
        List.fold_left_es
          (fun removed moph ->
            match
              Injected_operations.find state.injected.injected_operations moph
            with
            | None -> return removed
            | Some info ->
                let+ () =
                  Injected_operations.remove
                    state.injected.injected_operations
                    moph
                in
                info :: removed)
          []
          mophs

  (** [remove state block] removes the included operations that correspond to all
    the L1 batches included in [block]. This function is used when [block] is on
    an alternative chain in the case of a reorganization. *)
  let remove_included_operation state block =
    let open Lwt_result_syntax in
    match Included_in_blocks.find state.included.included_in_blocks block with
    | None ->
        (* Nothing removed *)
        return []
    | Some (_level, mophs) ->
        let* () =
          Included_in_blocks.remove state.included.included_in_blocks block
        in
        List.fold_left_es
          (fun removed moph ->
            match
              Included_operations.find state.included.included_operations moph
            with
            | None -> return removed
            | Some info ->
                let+ () =
                  Included_operations.remove
                    state.included.included_operations
                    moph
                in
                info :: removed)
          []
          mophs

  let fee_parameter_of_operations state ops =
    List.fold_left
      (fun acc {L1_operation.manager_operation = Manager op; _} ->
        let param = Rollup.fee_parameter state op in
        Injection.
          {
            minimal_fees = Tez.max acc.minimal_fees param.minimal_fees;
            minimal_nanotez_per_byte =
              Q.max acc.minimal_nanotez_per_byte param.minimal_nanotez_per_byte;
            minimal_nanotez_per_gas_unit =
              Q.max
                acc.minimal_nanotez_per_gas_unit
                param.minimal_nanotez_per_gas_unit;
            force_low_fee = acc.force_low_fee || param.force_low_fee;
            fee_cap =
              WithExceptions.Result.get_ok
                ~loc:__LOC__
                Tez.(acc.fee_cap +? param.fee_cap);
            burn_cap =
              WithExceptions.Result.get_ok
                ~loc:__LOC__
                Tez.(acc.burn_cap +? param.burn_cap);
          })
      Injection.
        {
          minimal_fees = Tez.zero;
          minimal_nanotez_per_byte = Q.zero;
          minimal_nanotez_per_gas_unit = Q.zero;
          force_low_fee = false;
          fee_cap = Tez.zero;
          burn_cap = Tez.zero;
        }
      ops

  (** Returns the first half of the list [ops] if there is more than two
      elements, or [None] otherwise.  *)
  let keep_half ops =
    let total = List.length ops in
    if total <= 1 then None else Some (List.take_n (total / 2) ops)

  (** [simulate_operations ~must_succeed state operations] simulates the
      injection of [operations] and returns a triple [(op, ops, results)] where
      [op] is the packed operation with the adjusted limits, [ops] is the prefix
      of [operations] which was considered (because it did not exceed the
      quotas) and [results] are the results of the simulation. See
      {!inject_operations} for the specification of [must_succeed]. *)
  let rec simulate_operations ~must_succeed state
      (operations : L1_operation.t list) =
    let open Lwt_result_syntax in
    let open Annotated_manager_operation in
    let force =
      match operations with
      | [] -> assert false
      | [_] ->
          (* If there is only one operation, fail when simulation fails *)
          false
      | _ -> (
          (* We want to see which operation failed in the batch if not all must
             succeed *)
          match must_succeed with `All -> false | `At_least_one -> true)
    in
    let*! () = Event.(emit2 simulating_operations) state operations force in
    let fee_parameter =
      fee_parameter_of_operations state.rollup_node_state operations
    in
    let annotated_operations =
      List.map
        (fun {L1_operation.manager_operation = Manager operation; _} ->
          Annotated_manager_operation
            (Injection.prepare_manager_operation
               ~fee:Limit.unknown
               ~gas_limit:Limit.unknown
               ~storage_limit:Limit.unknown
               operation))
        operations
    in
    let (Manager_list annot_op) =
      Annotated_manager_operation.manager_of_list annotated_operations
    in
    let*! simulation_result =
      Injection.inject_manager_operation
        state.cctxt
        ~simulation:true (* Only simulation here *)
        ~force
        ~chain:state.cctxt#chain
        ~block:(`Head 0)
        ~source:state.signer.pkh
        ~src_pk:state.signer.pk
        ~src_sk:state.signer.sk
        ~successor_level:true
          (* Needed to simulate tx_rollup operations in the next block *)
        ~fee:Limit.unknown
        ~gas_limit:Limit.unknown
        ~storage_limit:Limit.unknown
        ~fee_parameter
        annot_op
    in
    match simulation_result with
    | Error trace ->
        let exceeds_quota =
          TzTrace.fold
            (fun exceeds -> function
              | Environment.Ecoproto_error
                  (Gas.Block_quota_exceeded | Gas.Operation_quota_exceeded) ->
                  true
              | _ -> exceeds)
            false
            trace
        in
        if exceeds_quota then
          (* We perform a dichotomy by injecting the first half of the
             operations (we are not looking to maximize the number of operations
             injected because of the cost of simulation). Only the operations
             which are actually injected will be removed from the queue so the
             other half will be reconsidered later. *)
          match keep_half operations with
          | None -> fail trace
          | Some operations ->
              simulate_operations ~must_succeed state operations
        else fail trace
    | Ok (_, op, _, result) ->
        return (op, operations, Apply_results.Contents_result_list result)

  let inject_on_node state ~nb
      {shell; protocol_data = Operation_data {contents; _}} =
    let open Lwt_result_syntax in
    let unsigned_op = (shell, Contents_list contents) in
    let unsigned_op_bytes =
      Data_encoding.Binary.to_bytes_exn Operation.unsigned_encoding unsigned_op
    in
    let* signature =
      Client_keys.sign
        state.cctxt
        ~watermark:Signature.Generic_operation
        state.signer.sk
        unsigned_op_bytes
    in
    let op : _ Operation.t =
      {shell; protocol_data = {contents; signature = Some signature}}
    in
    let op_bytes =
      Data_encoding.Binary.to_bytes_exn Operation.encoding (Operation.pack op)
    in
    Tezos_shell_services.Shell_services.Injection.operation
      state.cctxt
      ~chain:state.cctxt#chain
      op_bytes
    >>=? fun oph ->
    let*! () = Event.(emit2 injected) state nb oph in
    return oph

  (** Inject the given [operations] in an L1 batch. If [must_succeed] is [`All]
    then all the operations must succeed in the simulation of injection. If
    [must_succeed] is [`At_least_one] at least one operation in the list
    [operations] must be successful in the simulation. In any case, only
    operations which are known as successful will be included in the injected L1
    batch. {b Note}: [must_succeed = `At_least_one] allows to incrementally build
    "or-batches" by iteratively removing operations that fail from the desired
    batch. *)
  let rec inject_operations ~must_succeed state
      (operations : L1_operation.t list) =
    let open Lwt_result_syntax in
    let* packed_op, operations, result =
      trace (Step_failed "simulation")
      @@ simulate_operations ~must_succeed state operations
    in
    let results = Apply_results.to_list result in
    let failure = ref false in
    let* rev_non_failing_operations =
      List.fold_left2_s
        ~when_different_lengths:
          [
            Exn
              (Failure
                 "Unexpected error: length of operations and result differ in \
                  simulation");
          ]
        (fun acc op (Apply_results.Contents_result result) ->
          match result with
          | Apply_results.Manager_operation_result
              {
                operation_result =
                  Failed (_, error) | Backtracked (_, Some error);
                _;
              } ->
              let*! () = Event.(emit2 dropping_operation) state op error in
              failure := true ;
              Lwt.return acc
          | Apply_results.Manager_operation_result
              {
                operation_result = Applied _ | Backtracked (_, None) | Skipped _;
                _;
              } ->
              (* Not known to be failing *)
              Lwt.return (op :: acc)
          | _ ->
              (* Only manager operations *)
              assert false)
        []
        operations
        results
    in
    if !failure then
      (* Invariant: must_succeed = `At_least_one, otherwise the simulation would have
         returned an error. We try to inject without the failing operation. *)
      let operations = List.rev rev_non_failing_operations in
      inject_operations ~must_succeed state operations
    else
      (* Inject on node for real *)
      let+ oph =
        trace (Step_failed "injection")
        @@ inject_on_node ~nb:(List.length operations) state packed_op
      in
      (oph, operations)

  (** Returns the (upper bound on) the size of an L1 batch of operations composed
    of the manager operations [rev_ops]. *)
  let size_l1_batch state rev_ops =
    let contents_list =
      List.map
        (fun (op : L1_operation.t) ->
          let (Manager operation) = op.manager_operation in
          let {fee; counter; gas_limit; storage_limit} =
            Rollup.approximate_fee_bound state.rollup_node_state operation
          in
          let contents =
            Manager_operation
              {
                source = state.signer.pkh;
                operation;
                fee;
                counter;
                gas_limit;
                storage_limit;
              }
          in
          Contents contents)
        rev_ops
    in
    let (Contents_list contents) =
      match Operation.of_list contents_list with
      | Error _ ->
          (* Cannot happen: rev_ops is non empty and contains only manager
             operations *)
          assert false
      | Ok packed_contents_list -> packed_contents_list
    in
    let signature =
      match state.signer.pkh with
      | Signature.Ed25519 _ -> Signature.of_ed25519 Ed25519.zero
      | Secp256k1 _ -> Signature.of_secp256k1 Secp256k1.zero
      | P256 _ -> Signature.of_p256 P256.zero
    in
    let branch = Block_hash.zero in
    let operation =
      {
        shell = {branch};
        protocol_data = Operation_data {contents; signature = Some signature};
      }
    in
    Data_encoding.Binary.length Operation.encoding operation

  (** Retrieve as many operations from the queue while remaining below the size
    limit. *)
  let get_operations_from_queue ~size_limit state =
    let exception Reached_limit of L1_operation.t list in
    let rev_ops =
      try
        Op_queue.fold
          (fun _oph op ops ->
            let new_ops = op :: ops in
            let new_size = size_l1_batch state new_ops in
            if new_size > size_limit then raise (Reached_limit ops) ;
            new_ops)
          state.queue
          []
      with Reached_limit ops -> ops
    in
    List.rev rev_ops

  (* Ignore the failures of finalize and remove commitment operations. These
     operations fail when there are either no commitment to finalize or to remove
     (which can happen when there are no inbox for instance). *)
  let ignore_ignorable_failing_operations operations = function
    | Ok res -> Ok (`Injected res)
    | Error _ as res ->
        let open Result_syntax in
        let+ operations_to_drop =
          List.fold_left_e
            (fun to_drop op ->
              let (Manager operation) = op.L1_operation.manager_operation in
              match Rollup.ignore_failing_operation operation with
              | `Don't_ignore -> res
              | `Ignore_keep -> Ok to_drop
              | `Ignore_drop -> Ok (op :: to_drop))
            []
            operations
        in
        `Ignored operations_to_drop

  (** [inject_pending_operations_for ~size_limit state pending] injects
    operations from the pending queue [pending], whose total size does
    not exceed [size_limit]. Upon successful injection, the
    operations are removed from the queue and marked as injected. *)
  let inject_pending_operations
      ?(size_limit = Constants.max_operation_data_length) state =
    let open Lwt_result_syntax in
    (* Retrieve and remove operations from pending *)
    let operations_to_inject = get_operations_from_queue ~size_limit state in
    match operations_to_inject with
    | [] -> return_unit
    | _ -> (
        let*! () =
          Event.(emit1 injecting_pending)
            state
            (List.length operations_to_inject)
        in
        let must_succeed =
          Rollup.batch_must_succeed
          @@ List.map
               (fun op -> op.L1_operation.manager_operation)
               operations_to_inject
        in
        let*! res =
          inject_operations ~must_succeed state operations_to_inject
        in
        let*? res =
          ignore_ignorable_failing_operations operations_to_inject res
        in
        match res with
        | `Injected (oph, injected_operations) ->
            (* Injection succeeded, remove from pending and add to injected *)
            let* () =
              List.iter_es
                (fun op -> Op_queue.remove state.queue op.L1_operation.hash)
                injected_operations
            in
            add_injected_operations state oph injected_operations
        | `Ignored operations_to_drop ->
            (* Injection failed but we ignore the failure. *)
            let* () =
              List.iter_es
                (fun op -> Op_queue.remove state.queue op.L1_operation.hash)
                operations_to_drop
            in
            return_unit)

  (** [register_included_operation state block level oph] marks the manager
    operations contained in the L1 batch [oph] as being included in the [block]
    of level [level], by moving them from the "injected" state to the "included"
    state. *)
  let register_included_operation state block level oph =
    let open Lwt_result_syntax in
    let* rmed = remove_injected_operation state oph in
    match rmed with
    | [] -> return_unit
    | injected_infos ->
        let included_mops =
          List.map (fun (i : injected_info) -> i.op) injected_infos
        in
        add_included_operations state oph block level included_mops

  (** [register_included_operations state block level oph] marks the known (by
    this injector) manager operations contained in [block] as being included. *)
  let register_included_operations state
      (block : Alpha_block_services.block_info) =
    List.iter_es
      (List.iter_es (fun (op : Alpha_block_services.operation) ->
           register_included_operation
             state
             block.hash
             block.header.shell.level
             op.hash
           (* TODO/TORU: Handle operations for rollup_id here with
              callback *)))
      block.Alpha_block_services.operations

  (** [revert_included_operations state block] marks the known (by this injector)
    manager operations contained in [block] as not being included any more,
    typically in the case of a reorganization where [block] is on an alternative
    chain. The operations are put back in the pending queue. *)
  let revert_included_operations state block =
    let open Lwt_result_syntax in
    let* included_infos = remove_included_operation state block in
    let*! () =
      Event.(emit1 revert_operations)
        state
        (List.map (fun o -> o.op.hash) included_infos)
    in
    (* TODO/TORU: https://gitlab.com/tezos/tezos/-/issues/2814
       maybe put at the front of the queue for re-injection. *)
    List.iter_es
      (fun {op; _} ->
        let {L1_operation.manager_operation = Manager mop; _} = op in
        let*! requeue =
          Rollup.requeue_reverted_operation state.rollup_node_state mop
        in
        if requeue then add_pending_operation state op else return_unit)
      included_infos

  (** [register_confirmed_level state confirmed_level] is called when the level
    [confirmed_level] is known as confirmed. In this case, the operations of
    block which are below this level are also considered as confirmed and are
    removed from the "included" state. These operations cannot be part of a
    reorganization so there will be no need to re-inject them anymore. *)
  let register_confirmed_level state confirmed_level =
    let open Lwt_result_syntax in
    let*! () =
      Event.(emit confirmed_level)
        (state.signer.pkh, state.tags, confirmed_level)
    in
    Included_in_blocks.iter_es
      (fun block (level, _operations) ->
        if level <= confirmed_level then
          let* confirmed_ops = remove_included_operation state block in
          let*! () =
            Event.(emit2 confirmed_operations)
              state
              level
              (List.map (fun o -> o.op.hash) confirmed_ops)
          in
          return_unit
        else return_unit)
      state.included.included_in_blocks

  (** [on_new_tezos_head state head reorg] is called when there is a new Tezos
    head (with a potential reorganization [reorg]). It first reverts any blocks
    that are in the alternative branch of the reorganization and then registers
    the effect of the new branch (the newly included operation and confirmed
    operations).  *)
  let on_new_tezos_head state (head : Alpha_block_services.block_info)
      (reorg : Alpha_block_services.block_info reorg) =
    let open Lwt_result_syntax in
    let*! () = Event.(emit1 new_tezos_head) state head.hash in
    let* () =
      List.iter_es
        (fun removed_block ->
          revert_included_operations
            state
            removed_block.Alpha_block_services.hash)
        (List.rev reorg.old_chain)
    in
    let* () =
      List.iter_es
        (fun added_block -> register_included_operations state added_block)
        reorg.new_chain
    in
    (* Head is already included in the reorganization, so no need to process it
       separately. *)
    let confirmed_level =
      Int32.sub
        head.Alpha_block_services.header.shell.level
        (Int32.of_int confirmations)
    in
    if confirmed_level >= 0l then register_confirmed_level state confirmed_level
    else return_unit

  (* The request {Request.Inject} triggers an injection of the operations
     the pending queue. *)
  let on_inject state = inject_pending_operations state

  module Types = struct
    type nonrec state = state

    type parameters = {
      cctxt : Protocol_client_context.full;
      data_dir : string;
      rollup_node_state : Rollup.rollup_node_state;
      strategy : injection_strategy;
      tags : Tags.t;
    }
  end

  (* The worker for the injector. *)
  module Worker = Worker.MakeSingle (Name) (Request) (Types)

  (* The queue for the requests to the injector worker is infinite. *)
  type worker = Worker.infinite Worker.queue Worker.t

  let table = Worker.create_table Queue

  let tags_table = Tags_table.create 7

  module Handlers = struct
    type self = worker

    let on_request :
        type r request_error.
        worker ->
        (r, request_error) Request.t ->
        (r, request_error) result Lwt.t =
     fun w request ->
      let state = Worker.state w in
      match request with
      | Request.Add_pending op ->
          (* The execution of the request handler is protected to avoid stopping the
             worker in case of an exception. *)
          protect @@ fun () -> add_pending_operation state op
      | Request.New_tezos_head (head, reorg) ->
          protect @@ fun () -> on_new_tezos_head state head reorg
      | Request.Inject -> protect @@ fun () -> on_inject state

    type launch_error = error trace

    let on_launch _w signer
        Types.{cctxt; data_dir; rollup_node_state; strategy; tags} =
      trace (Step_failed "initialization")
      @@ init_injector cctxt ~data_dir rollup_node_state ~signer strategy tags

    let on_error (type a b) w st (r : (a, b) Request.t) (errs : b) :
        unit tzresult Lwt.t =
      let open Lwt_result_syntax in
      let state = Worker.state w in
      let request_view = Request.view r in
      let emit_and_return_errors errs =
        (* Errors do not stop the worker but emit an entry in the log. *)
        let*! () = Event.(emit3 request_failed) state request_view st errs in
        return_unit
      in
      match r with
      | Request.Add_pending _ -> emit_and_return_errors errs
      | Request.New_tezos_head _ -> emit_and_return_errors errs
      | Request.Inject -> emit_and_return_errors errs

    let on_completion w r _ st =
      let state = Worker.state w in
      match Request.view r with
      | Request.View (Add_pending _ | New_tezos_head _) ->
          Event.(emit2 request_completed_debug) state (Request.view r) st
      | View Inject ->
          Event.(emit2 request_completed_notice) state (Request.view r) st

    let on_no_request _ = Lwt.return_unit

    let on_close w =
      let state = Worker.state w in
      Tags.iter (Tags_table.remove tags_table) state.tags ;
      Lwt.return_unit
  end

  (* TODO/TORU: https://gitlab.com/tezos/tezos/-/issues/2754
     Injector worker in a separate process *)
  let init (cctxt : #Protocol_client_context.full) ~data_dir rollup_node_state
      ~signers =
    let open Lwt_result_syntax in
    let signers_map =
      List.fold_left
        (fun acc (signer, strategy, tags) ->
          let tags = Tags.of_list tags in
          let strategy, tags =
            match Signature.Public_key_hash.Map.find_opt signer acc with
            | None -> (strategy, tags)
            | Some (other_strategy, other_tags) ->
                let strategy =
                  match (strategy, other_strategy) with
                  | `Each_block, `Each_block -> `Each_block
                  | `Delay_block, _ | _, `Delay_block ->
                      (* Delay_block strategy takes over because we can always wait a
                         little bit more to inject operation which are to be injected
                         "each block". *)
                      `Delay_block
                in
                (strategy, Tags.union other_tags tags)
          in
          Signature.Public_key_hash.Map.add signer (strategy, tags) acc)
        Signature.Public_key_hash.Map.empty
        signers
    in
    Signature.Public_key_hash.Map.iter_es
      (fun signer (strategy, tags) ->
        let+ worker =
          Worker.launch
            table
            signer
            {
              cctxt = (cctxt :> Protocol_client_context.full);
              data_dir;
              rollup_node_state;
              strategy;
              tags;
            }
            (module Handlers)
        in
        ignore worker)
      signers_map

  let worker_of_signer signer_pkh =
    match Worker.find_opt table signer_pkh with
    | None ->
        (* TODO: https://gitlab.com/tezos/tezos/-/issues/2818
           maybe lazily start worker here *)
        error (No_worker_for_source signer_pkh)
    | Some worker -> ok worker

  let worker_of_tag tag =
    match Tags_table.find_opt tags_table tag with
    | None ->
        Format.kasprintf
          (fun s -> error (No_worker_for_tag s))
          "%a"
          Rollup.Tag.pp
          tag
    | Some worker -> ok worker

  let add_pending_operation ?source op =
    let open Lwt_result_syntax in
    let l1_operation = L1_operation.make op in
    let*? w =
      match source with
      | Some source -> worker_of_signer source
      | None -> (
          match Rollup.operation_tag op with
          | None -> error (No_worker_for_operation l1_operation)
          | Some tag -> worker_of_tag tag)
    in
    let*! (_pushed : bool) =
      Worker.Queue.push_request w (Request.Add_pending l1_operation)
    in
    return_unit

  let new_tezos_head h reorg =
    let open Lwt_syntax in
    let workers = Worker.list table in
    List.iter_p
      (fun (_signer, w) ->
        let* (_pushed : bool) =
          Worker.Queue.push_request w (Request.New_tezos_head (h, reorg))
        in
        return_unit)
      workers

  let has_tag_in ~tags state =
    match tags with
    | None ->
        (* Not filtering on tags *)
        true
    | Some tags -> not (Tags.disjoint state.tags tags)

  let has_strategy ~strategy state =
    match strategy with
    | None ->
        (* Not filtering on strategy *)
        true
    | Some strategy -> state.strategy = strategy

  let inject ?tags ?strategy () =
    let workers = Worker.list table in
    let tags = Option.map Tags.of_list tags in
    List.iter_p
      (fun (_signer, w) ->
        let open Lwt_syntax in
        let worker_state = Worker.state w in
        if has_tag_in ~tags worker_state && has_strategy ~strategy worker_state
        then
          let* _pushed = Worker.Queue.push_request w Request.Inject in
          return_unit
        else Lwt.return_unit)
      workers

  let shutdown () =
    let workers = Worker.list table in
    List.iter_p (fun (_signer, w) -> Worker.shutdown w) workers
end
