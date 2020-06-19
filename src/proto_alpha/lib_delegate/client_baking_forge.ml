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

open Protocol
open Alpha_context
open Protocol_client_context

include Internal_event.Legacy_logging.Make_semantic (struct
  let name = Protocol.name ^ ".baking.forge"
end)

open Logging

(* Just proving a point *)
let[@warning "-32"] time_protocol__is__protocol_time :
    Alpha_context.Timestamp.t -> Time.Protocol.t =
 fun x -> x

(* The index of the different components of the protocol's validation passes *)
(* TODO: ideally, we would like this to be more abstract and possibly part of
   the protocol, while retaining the generality of lists *)
(* Hypothesis : we suppose [List.length Protocol.Main.validation_passes = 4] *)
let endorsements_index = 0

let votes_index = 1

let anonymous_index = 2

let managers_index = 3

let default_max_priority = 64

let default_minimal_fees =
  match Tez.of_mutez 100L with None -> assert false | Some t -> t

let default_minimal_nanotez_per_gas_unit = Z.of_int 100

let default_minimal_nanotez_per_byte = Z.of_int 1000

type slot =
  Time.Protocol.t * (Client_baking_blocks.block_info * int * public_key_hash)

type state = {
  context_path : string;
  mutable index : Context.index;
  (* Nonces file location *)
  nonces_location : [`Nonce] Client_baking_files.location;
  (* see [get_delegates] below to find delegates when the list is empty *)
  delegates : public_key_hash list;
  (* lazy-initialisation with retry-on-error *)
  constants : Constants.t;
  (* Minimal operation fee required to include an operation in a block *)
  minimal_fees : Tez.t;
  (* Minimal operation fee per gas required to include an operation in a block *)
  minimal_nanotez_per_gas_unit : Z.t;
  (* Minimal operation fee per byte required to include an operation in a block *)
  minimal_nanotez_per_byte : Z.t;
  (* truly mutable *)
  mutable best_slot : slot option;
}

let create_state ?(minimal_fees = default_minimal_fees)
    ?(minimal_nanotez_per_gas_unit = default_minimal_nanotez_per_gas_unit)
    ?(minimal_nanotez_per_byte = default_minimal_nanotez_per_byte) context_path
    index nonces_location delegates constants =
  {
    context_path;
    index;
    nonces_location;
    delegates;
    constants;
    minimal_fees;
    minimal_nanotez_per_gas_unit;
    minimal_nanotez_per_byte;
    best_slot = None;
  }

let get_delegates cctxt state =
  match state.delegates with
  | [] ->
      Client_keys.get_keys cctxt
      >>=? fun keys -> return (List.map (fun (_, pkh, _, _) -> pkh) keys)
  | _ ->
      return state.delegates

let generate_seed_nonce () =
  match Nonce.of_bytes (Rand.generate Constants.nonce_length) with
  | Error _errs ->
      assert false
  | Ok nonce ->
      nonce

let forge_block_header (cctxt : #Protocol_client_context.full) ~chain block
    delegate_sk shell priority seed_nonce_hash =
  Client_baking_pow.mine cctxt chain block shell (fun proof_of_work_nonce ->
      {Block_header.priority; seed_nonce_hash; proof_of_work_nonce})
  >>=? fun contents ->
  let unsigned_header =
    Data_encoding.Binary.to_bytes_exn
      Alpha_context.Block_header.unsigned_encoding
      (shell, contents)
  in
  Shell_services.Chain.chain_id cctxt ~chain ()
  >>=? fun chain_id ->
  Client_keys.append
    cctxt
    delegate_sk
    ~watermark:(Block_header chain_id)
    unsigned_header

let forge_faked_protocol_data ~priority ~seed_nonce_hash =
  Alpha_context.Block_header.
    {
      contents =
        {
          priority;
          seed_nonce_hash;
          proof_of_work_nonce = Client_baking_pow.empty_proof_of_work_nonce;
        };
      signature = Signature.zero;
    }

let assert_valid_operations_hash shell_header operations =
  let operations_hash =
    Operation_list_list_hash.compute
      (List.map
         Operation_list_hash.compute
         (List.map (List.map Tezos_base.Operation.hash) operations))
  in
  fail_unless
    (Operation_list_list_hash.equal
       operations_hash
       shell_header.Tezos_base.Block_header.operations_hash)
    (failure "Client_baking_forge.inject_block: inconsistent header.")

let compute_endorsing_power cctxt ~chain ~block operations =
  Shell_services.Chain.chain_id cctxt ~chain ()
  >>=? fun chain_id ->
  fold_left_s
    (fun sum -> function
      | { Alpha_context.protocol_data =
            Operation_data {contents = Single (Endorsement _); _};
          _ } as op -> (
          Delegate_services.Endorsing_power.get
            cctxt
            (chain, block)
            op
            chain_id
          >>= function
          | Error _ ->
              (* Filters invalid endorsements *)
              return sum
          | Ok power ->
              return (sum + power) ) | _ -> return sum)
    0
    operations

let inject_block cctxt ?(force = false) ?seed_nonce_hash ~chain ~shell_header
    ~priority ~delegate_pkh ~delegate_sk ~level operations =
  assert_valid_operations_hash shell_header operations
  >>=? fun () ->
  let block = `Hash (shell_header.Tezos_base.Block_header.predecessor, 0) in
  forge_block_header
    cctxt
    ~chain
    block
    delegate_sk
    shell_header
    priority
    seed_nonce_hash
  >>=? fun signed_header ->
  (* Record baked blocks to prevent double baking  *)
  let open Client_baking_highwatermarks in
  cctxt#with_lock (fun () ->
      Client_baking_files.resolve_location cctxt ~chain `Block
      >>=? fun block_location ->
      may_inject_block cctxt block_location ~delegate:delegate_pkh level
      >>=? function
      | true ->
          record_block cctxt block_location ~delegate:delegate_pkh level
          >>=? fun () -> return_true
      | false ->
          lwt_log_error
            Tag.DSL.(
              fun f ->
                f "Level %a : previously baked"
                -% t event "double_bake_near_miss"
                -% a level_tag level)
          >>= fun () -> return force)
  >>=? function
  | false ->
      fail (Level_previously_baked level)
  | true ->
      Shell_services.Injection.block
        cctxt
        ~force
        ~chain
        signed_header
        operations
      >>=? fun block_hash ->
      lwt_log_info
        Tag.DSL.(
          fun f ->
            f "Client_baking_forge.inject_block: inject %a"
            -% t event "inject_baked_block"
            -% a Block_hash.Logging.tag block_hash
            -% t signed_header_tag signed_header
            -% t operations_tag operations)
      >>= fun () -> return block_hash

type error += Failed_to_preapply of Tezos_base.Operation.t * error list

type error += Forking_test_chain

let () =
  register_error_kind
    `Permanent
    ~id:"Client_baking_forge.failed_to_preapply"
    ~title:"Fail to preapply an operation"
    ~description:""
    ~pp:(fun ppf (op, err) ->
      let h = Tezos_base.Operation.hash op in
      Format.fprintf
        ppf
        "@[Failed to preapply %a:@ @[<v 4>%a@]@]"
        Operation_hash.pp_short
        h
        pp_print_error
        err)
    Data_encoding.(
      obj2
        (req "operation" (dynamic_size Tezos_base.Operation.encoding))
        (req "error" RPC_error.encoding))
    (function Failed_to_preapply (hash, err) -> Some (hash, err) | _ -> None)
    (fun (hash, err) -> Failed_to_preapply (hash, err))

let get_manager_operation_gas_and_fee op =
  let {protocol_data = Operation_data {contents; _}; _} = op in
  let open Operation in
  let l = to_list (Contents_list contents) in
  fold_left_s
    (fun ((total_fee, total_gas) as acc) -> function
      | Contents (Manager_operation {fee; gas_limit; _}) ->
          (Lwt.return @@ Environment.wrap_error @@ Tez.(total_fee +? fee))
          >>=? fun total_fee -> return (total_fee, Z.add total_gas gas_limit)
      | _ -> return acc)
    (Tez.zero, Z.zero)
    l

(* Sort operation consisdering potential gas and storage usage.
   Weight = fee / (max ( (size/size_total), (gas/gas_total))) *)
let sort_manager_operations ~max_size ~hard_gas_limit_per_block ~minimal_fees
    ~minimal_nanotez_per_gas_unit ~minimal_nanotez_per_byte
    (operations : packed_operation list) =
  let compute_weight op (fee, gas) =
    let size = Data_encoding.Binary.length Operation.encoding op in
    let size_f = Q.of_int size in
    let gas_f = Q.of_bigint gas in
    let fee_f = Q.of_int64 (Tez.to_mutez fee) in
    let size_ratio = Q.(size_f / Q.of_int max_size) in
    let gas_ratio = Q.(gas_f / Q.of_bigint hard_gas_limit_per_block) in
    (size, gas, Q.(fee_f / max size_ratio gas_ratio))
  in
  filter_map_s
    (fun op ->
      get_manager_operation_gas_and_fee op
      >>=? fun (fee, gas) ->
      if Tez.(fee < minimal_fees) then return_none
      else
        let ((size, gas, _ratio) as weight) = compute_weight op (fee, gas) in
        let open Environment in
        let fees_in_nanotez =
          Z.mul (Z.of_int64 (Tez.to_mutez fee)) (Z.of_int 1000)
        in
        let enough_fees_for_gas =
          let minimal_fees_in_nanotez =
            Z.mul minimal_nanotez_per_gas_unit gas
          in
          Z.compare minimal_fees_in_nanotez fees_in_nanotez <= 0
        in
        let enough_fees_for_size =
          let minimal_fees_in_nanotez =
            Z.mul minimal_nanotez_per_byte (Z.of_int size)
          in
          Z.compare minimal_fees_in_nanotez fees_in_nanotez <= 0
        in
        if enough_fees_for_size && enough_fees_for_gas then
          return_some (op, weight)
        else return_none)
    operations
  >>=? fun operations ->
  (* We sort by the biggest weight *)
  return
    (List.sort
       (fun (_, (_, _, w)) (_, (_, _, w')) -> Q.compare w' w)
       operations)

let retain_operations_up_to_quota operations quota =
  let {Tezos_protocol_environment.max_op; max_size} = quota in
  let operations =
    match max_op with Some n -> List.sub operations n | None -> operations
  in
  let exception Full of packed_operation list in
  let operations =
    try
      List.fold_left
        (fun (ops, size) op ->
          let operation_size =
            Data_encoding.Binary.length Alpha_context.Operation.encoding op
          in
          let new_size = size + operation_size in
          if new_size > max_size then raise (Full ops)
          else (op :: ops, new_size))
        ([], 0)
        operations
      |> fst
    with Full ops -> ops
  in
  List.rev operations

let trim_manager_operations ~max_size ~hard_gas_limit_per_block
    manager_operations =
  map_s
    (fun op ->
      get_manager_operation_gas_and_fee op
      >>=? fun (_fee, gas) ->
      let size = Data_encoding.Binary.length Operation.encoding op in
      return (op, (size, gas)))
    manager_operations
  >>=? fun manager_operations ->
  List.fold_left
    (fun (total_size, total_gas, (good_ops, bad_ops)) (op, (size, gas)) ->
      let new_size = total_size + size in
      let new_gas = Z.(total_gas + gas) in
      if new_size > max_size || Z.gt new_gas hard_gas_limit_per_block then
        (new_size, new_gas, (good_ops, op :: bad_ops))
      else (new_size, new_gas, (op :: good_ops, bad_ops)))
    (0, Z.zero, ([], []))
    manager_operations
  |> fun (_, _, (good_ops, bad_ops)) ->
  (* We keep the overflowing operations, it may be used for client-side validation *)
  return (List.rev good_ops, List.rev bad_ops)

(* We classify operations, sort managers operation by interest and add bad ones at the end *)
(* Hypothesis : we suppose that the received manager operations have a valid gas_limit *)

(** [classify_operations] classify the operation in 4 lists indexed as such :
    - 0 -> Endorsements
    - 1 -> Votes and proposals
    - 2 -> Anonymous operations
    - 3 -> High-priority manager operations.
    Returns two list :
    - A desired set of operations to be included
    - Potentially overflowing operations *)
let classify_operations (cctxt : #Protocol_client_context.full) ~chain ~block
    ~hard_gas_limit_per_block ~minimal_fees ~minimal_nanotez_per_gas_unit
    ~minimal_nanotez_per_byte (ops : packed_operation list) =
  Alpha_block_services.live_blocks cctxt ~chain ~block ()
  >>=? fun live_blocks ->
  (* Remove operations that are too old *)
  let ops =
    List.filter
      (fun {shell = {branch; _}; _} -> Block_hash.Set.mem branch live_blocks)
      ops
  in
  let validation_passes_len = List.length Main.validation_passes in
  let t = Array.make validation_passes_len [] in
  List.iter
    (fun (op : packed_operation) ->
      List.iter
        (fun pass -> t.(pass) <- op :: t.(pass))
        (Main.acceptable_passes op))
    ops ;
  let t = Array.map List.rev t in
  (* Retrieve the optimist maximum paying manager operations *)
  let manager_operations = t.(managers_index) in
  let {Environment.Updater.max_size; _} =
    List.nth Main.validation_passes managers_index
  in
  sort_manager_operations
    ~max_size
    ~hard_gas_limit_per_block
    ~minimal_fees
    ~minimal_nanotez_per_gas_unit
    ~minimal_nanotez_per_byte
    manager_operations
  >>=? fun ordered_operations ->
  (* Greedy heuristic *)
  trim_manager_operations
    ~max_size
    ~hard_gas_limit_per_block
    (List.map fst ordered_operations)
  >>=? fun (desired_manager_operations, overflowing_manager_operations) ->
  t.(managers_index) <- desired_manager_operations ;
  return (Array.to_list t, overflowing_manager_operations)

let forge (op : Operation.packed) : Operation.raw =
  {
    shell = op.shell;
    proto =
      Data_encoding.Binary.to_bytes_exn
        Alpha_context.Operation.protocol_data_encoding
        op.protocol_data;
  }

let ops_of_mempool (ops : Alpha_block_services.Mempool.t) =
  (* We only retain the applied, unprocessed and delayed operations *)
  List.rev
    ( Operation_hash.Map.fold (fun _ op acc -> op :: acc) ops.unprocessed
    @@ Operation_hash.Map.fold
         (fun _ (op, _) acc -> op :: acc)
         ops.branch_delayed
    @@ List.rev_map (fun (_, op) -> op) ops.applied )

let unopt_operations cctxt chain mempool = function
  | None -> (
    match mempool with
    | None ->
        Alpha_block_services.Mempool.pending_operations cctxt ~chain ()
        >>=? fun mpool ->
        let ops = ops_of_mempool mpool in
        return ops
    | Some file ->
        Tezos_stdlib_unix.Lwt_utils_unix.Json.read_file file
        >>=? fun json ->
        let mpool =
          Data_encoding.Json.destruct
            Alpha_block_services.S.Mempool.encoding
            json
        in
        let ops = ops_of_mempool mpool in
        return ops )
  | Some operations ->
      return operations

let all_ops_valid (results : error Preapply_result.t list) =
  let open Operation_hash.Map in
  List.for_all
    (fun (result : error Preapply_result.t) ->
      is_empty result.refused
      && is_empty result.branch_refused
      && is_empty result.branch_delayed)
    results

let decode_priority cctxt chain block ~priority ~endorsing_power =
  match priority with
  | `Set priority ->
      Alpha_services.Delegate.Minimal_valid_time.get
        cctxt
        (chain, block)
        priority
        endorsing_power
      >>=? fun minimal_timestamp -> return (priority, minimal_timestamp)
  | `Auto (src_pkh, max_priority) -> (
      Alpha_services.Helpers.current_level cctxt ~offset:1l (chain, block)
      >>=? fun {level; _} ->
      Alpha_services.Delegate.Baking_rights.get
        cctxt
        ?max_priority
        ~levels:[level]
        ~delegates:[src_pkh]
        (chain, block)
      >>=? fun possibilities ->
      try
        let {Alpha_services.Delegate.Baking_rights.priority = prio; _} =
          List.find
            (fun p -> p.Alpha_services.Delegate.Baking_rights.level = level)
            possibilities
        in
        Alpha_services.Delegate.Minimal_valid_time.get
          cctxt
          (chain, block)
          prio
          endorsing_power
        >>=? fun minimal_timestamp -> return (prio, minimal_timestamp)
      with Not_found ->
        failwith "No slot found at level %a" Raw_level.pp level )

let unopt_timestamp ?(force = false) timestamp minimal_timestamp =
  let timestamp =
    match timestamp with
    | None ->
        minimal_timestamp
    | Some timestamp ->
        timestamp
  in
  if (not force) && timestamp < minimal_timestamp then
    failwith
      "Proposed timestamp %a is earlier than minimal timestamp %a"
      Time.Protocol.pp_hum
      timestamp
      Time.Protocol.pp_hum
      minimal_timestamp
  else return timestamp

let merge_preapps (old : error Preapply_result.t)
    (neu : error Preapply_result.t) =
  let merge _ a b =
    (* merge ops *)
    match (a, b) with
    | (None, None) ->
        None
    | (Some x, None) ->
        Some x
    | (_, Some y) ->
        Some y
  in
  let merge = Operation_hash.Map.merge merge in
  (* merge op maps *)
  (* merge preapplies *)
  {
    Preapply_result.applied = [];
    refused = merge old.refused neu.refused;
    branch_refused = merge old.branch_refused neu.branch_refused;
    branch_delayed = merge old.branch_delayed neu.branch_delayed;
  }

let error_of_op (result : error Preapply_result.t) op =
  let op = forge op in
  let h = Tezos_base.Operation.hash op in
  try
    Some
      (Failed_to_preapply (op, snd @@ Operation_hash.Map.find h result.refused))
  with Not_found -> (
    try
      Some
        (Failed_to_preapply
           (op, snd @@ Operation_hash.Map.find h result.branch_refused))
    with Not_found -> (
      try
        Some
          (Failed_to_preapply
             (op, snd @@ Operation_hash.Map.find h result.branch_delayed))
      with Not_found -> None ) )

let filter_and_apply_operations cctxt state ~chain ~block block_info ~priority
    ?protocol_data
    ((operations : packed_operation list list), overflowing_operations) =
  (* Retrieve the minimal valid time for when the block can be baked with 0 endorsements *)
  Delegate_services.Minimal_valid_time.get cctxt (chain, block) priority 0
  >>=? fun min_valid_timestamp ->
  let open Client_baking_simulator in
  lwt_debug
    Tag.DSL.(
      fun f ->
        f "starting client-side validation after %a"
        -% t event "baking_local_validation_start"
        -% a Block_hash.Logging.tag block_info.Client_baking_blocks.hash)
  >>= fun () ->
  begin_construction
    ~timestamp:min_valid_timestamp
    ?protocol_data
    state.index
    block_info
  >>= (function
        | Ok inc ->
            return inc
        | Error errs ->
            lwt_log_error
              Tag.DSL.(
                fun f ->
                  f "Error while fetching current context : %a"
                  -% t event "context_fetch_error"
                  -% a errs_tag errs)
            >>= fun () ->
            lwt_log_notice
              Tag.DSL.(
                fun f ->
                  f "Retrying to open the context" -% t event "reopen_context")
            >>= fun () ->
            Client_baking_simulator.load_context
              ~context_path:state.context_path
            >>= fun index ->
            begin_construction
              ~timestamp:min_valid_timestamp
              ?protocol_data
              index
              block_info
            >>=? fun inc ->
            state.index <- index ;
            return inc)
  >>=? fun initial_inc ->
  let endorsements = List.nth operations endorsements_index in
  let votes = List.nth operations votes_index in
  let anonymous = List.nth operations anonymous_index in
  let managers = List.nth operations managers_index in
  let validate_operation inc op =
    protect (fun () -> add_operation inc op)
    >>= function
    | Error errs ->
        lwt_debug
          Tag.DSL.(
            fun f ->
              f
                "@[<v 4>Client-side validation: filtered invalid operation %a@\n\
                 %a@]"
              -% t event "baking_rejected_invalid_operation"
              -% a Operation_hash.Logging.tag (Operation.hash_packed op)
              -% a errs_tag errs)
        >>= fun () -> Lwt.return_none
    | Ok (resulting_state, receipt) -> (
      try
        (* Check that the metadata are serializable/deserializable *)
        let _ =
          Data_encoding.Binary.(
            of_bytes_exn
              Protocol.operation_receipt_encoding
              (to_bytes_exn Protocol.operation_receipt_encoding receipt))
        in
        Lwt.return_some resulting_state
      with exn ->
        lwt_debug
          Tag.DSL.(
            fun f ->
              f "Client-side validation: filtered invalid operation %a"
              -% t event "baking_rejected_invalid_operation"
              -% a
                   errs_tag
                   [ Validation_errors.Cannot_serialize_operation_metadata;
                     Exn exn ])
        >>= fun () -> Lwt.return_none )
  in
  let filter_valid_operations inc ops =
    Lwt_list.fold_left_s
      (fun (inc, acc) op ->
        validate_operation inc op
        >>= function
        | None ->
            Lwt.return (inc, acc)
        | Some inc' ->
            Lwt.return (inc', op :: acc))
      (inc, [])
      ops
  in
  (* First pass : we filter out invalid operations by applying them in the correct order *)
  filter_valid_operations initial_inc endorsements
  >>= fun (inc, endorsements) ->
  filter_valid_operations inc votes
  >>= fun (inc, votes) ->
  filter_valid_operations inc anonymous
  >>= fun (manager_inc, anonymous) ->
  (* Retrieve the correct index order *)
  let managers = List.sort Protocol.compare_operations managers in
  let overflowing_operations =
    List.sort Protocol.compare_operations overflowing_operations
  in
  filter_valid_operations manager_inc (managers @ overflowing_operations)
  >>= fun (inc, managers) ->
  finalize_construction inc
  >>=? fun _ ->
  let quota : Environment.Updater.quota list = Main.validation_passes in
  let {Constants.hard_gas_limit_per_block; _} = state.constants.parametric in
  let votes =
    retain_operations_up_to_quota (List.rev votes) (List.nth quota votes_index)
  in
  let anonymous =
    retain_operations_up_to_quota
      (List.rev anonymous)
      (List.nth quota anonymous_index)
  in
  trim_manager_operations
    ~max_size:(List.nth quota managers_index).max_size
    ~hard_gas_limit_per_block
    managers
  >>=? fun (accepted_managers, _overflowing_managers) ->
  (* Retrieve the correct index order *)
  let accepted_managers =
    List.sort Protocol.compare_operations accepted_managers
  in
  (* Second pass : make sure we only keep valid operations *)
  filter_valid_operations manager_inc accepted_managers
  >>= fun (_, accepted_managers) ->
  (* Put the operations back in order *)
  let operations =
    List.map List.rev [endorsements; votes; anonymous; accepted_managers]
  in
  (* Construct a context with the valid operations and a correct timestamp *)
  compute_endorsing_power cctxt ~chain ~block endorsements
  >>=? fun current_endorsing_power ->
  Delegate_services.Minimal_valid_time.get
    cctxt
    (chain, block)
    priority
    current_endorsing_power
  >>=? fun expected_validity ->
  (* Finally, we construct a block with the minimal possible timestamp
     given the endorsing power *)
  begin_construction
    ~timestamp:expected_validity
    ?protocol_data
    state.index
    block_info
  >>=? fun inc ->
  fold_left_s
    (fun inc op -> add_operation inc op >>=? fun (inc, _receipt) -> return inc)
    inc
    (List.flatten operations)
  >>=? fun final_inc ->
  finalize_construction final_inc
  >>=? fun (validation_result, metadata) ->
  return
    (final_inc, (validation_result, metadata), operations, expected_validity)

(* Build the block header : mimics node prevalidation *)
let finalize_block_header shell_header ~timestamp validation_result operations
    =
  let {Tezos_protocol_environment.context; fitness; message; _} =
    validation_result
  in
  let validation_passes = List.length Main.validation_passes in
  let operations_hash : Operation_list_list_hash.t =
    Operation_list_list_hash.compute
      (List.map
         (fun sl ->
           Operation_list_hash.compute (List.map Operation.hash_packed sl))
         operations)
  in
  let context = Shell_context.unwrap_disk_context context in
  Context.get_test_chain context
  >>= (function
        | Not_running ->
            return context
        | Running {expiration; _} ->
            if Time.Protocol.(expiration <= timestamp) then
              Context.set_test_chain context Not_running
              >>= fun context -> return context
            else return context
        | Forking _ ->
            fail Forking_test_chain)
  >>=? fun context ->
  let context = Context.hash ~time:timestamp ?message context in
  let header =
    Tezos_base.Block_header.
      {
        shell_header with
        level = Int32.succ shell_header.level;
        validation_passes;
        operations_hash;
        fitness;
        context;
      }
  in
  return header

let forge_block cctxt ?force ?operations ?(best_effort = operations = None)
    ?(sort = best_effort) ?(minimal_fees = default_minimal_fees)
    ?(minimal_nanotez_per_gas_unit = default_minimal_nanotez_per_gas_unit)
    ?(minimal_nanotez_per_byte = default_minimal_nanotez_per_byte) ?timestamp
    ?mempool ?context_path ?seed_nonce_hash ~chain ~priority ~delegate_pkh
    ~delegate_sk block =
  (* making the arguments usable *)
  unopt_operations cctxt chain mempool operations
  >>=? fun operations_arg ->
  compute_endorsing_power cctxt ~chain ~block operations_arg
  >>=? fun endorsing_power ->
  decode_priority cctxt chain block ~priority ~endorsing_power
  >>=? fun (priority, minimal_timestamp) ->
  unopt_timestamp ?force timestamp minimal_timestamp
  >>=? fun timestamp ->
  (* get basic building blocks *)
  let protocol_data = forge_faked_protocol_data ~priority ~seed_nonce_hash in
  Alpha_services.Constants.all cctxt (chain, block)
  >>=? fun Constants.
             { parametric = {hard_gas_limit_per_block; endorsers_per_block; _};
               _ } ->
  classify_operations
    cctxt
    ~chain
    ~hard_gas_limit_per_block
    ~block
    ~minimal_fees
    ~minimal_nanotez_per_gas_unit
    ~minimal_nanotez_per_byte
    operations_arg
  >>=? fun (operations, overflowing_ops) ->
  (* Ensure that we retain operations up to the quota *)
  let quota : Environment.Updater.quota list = Main.validation_passes in
  let endorsements =
    List.sub (List.nth operations endorsements_index) endorsers_per_block
  in
  let votes =
    retain_operations_up_to_quota
      (List.nth operations votes_index)
      (List.nth quota votes_index)
  in
  let anonymous =
    retain_operations_up_to_quota
      (List.nth operations anonymous_index)
      (List.nth quota anonymous_index)
  in
  (* Size/Gas check already occured in classify operations *)
  let managers = List.nth operations managers_index in
  let operations = [endorsements; votes; anonymous; managers] in
  ( match context_path with
  | None ->
      Alpha_block_services.Helpers.Preapply.block
        cctxt
        ~chain
        ~block
        ~timestamp
        ~sort
        ~protocol_data
        operations
      >>=? fun (shell_header, result) ->
      let operations =
        List.map (fun l -> List.map snd l.Preapply_result.applied) result
      in
      (* everything went well (or we don't care about errors): GO! *)
      if best_effort || all_ops_valid result then
        return (shell_header, operations)
        (* some errors (and we care about them) *)
      else
        let result =
          List.fold_left merge_preapps Preapply_result.empty result
        in
        Lwt.return_error @@ List.filter_map (error_of_op result) operations_arg
  | Some context_path ->
      assert sort ;
      assert best_effort ;
      Context.init ~readonly:true context_path
      >>= fun index ->
      Client_baking_blocks.info cctxt ~chain block
      >>=? fun bi ->
      Alpha_services.Constants.all cctxt (chain, `Head 0)
      >>=? fun constants ->
      Client_baking_files.resolve_location cctxt ~chain `Nonce
      >>=? fun nonces_location ->
      let state =
        {
          context_path;
          index;
          nonces_location;
          constants;
          delegates = [];
          best_slot = None;
          minimal_fees = default_minimal_fees;
          minimal_nanotez_per_gas_unit = default_minimal_nanotez_per_gas_unit;
          minimal_nanotez_per_byte = default_minimal_nanotez_per_byte;
        }
      in
      filter_and_apply_operations
        cctxt
        state
        ~chain
        ~block
        ~priority
        ~protocol_data
        bi
        (operations, overflowing_ops)
      >>=? fun ( final_context,
                 (validation_result, _),
                 operations,
                 min_valid_timestamp ) ->
      let current_protocol = bi.next_protocol in
      let context =
        Shell_context.unwrap_disk_context validation_result.context
      in
      Context.get_protocol context
      >>= fun next_protocol ->
      if Protocol_hash.equal current_protocol next_protocol then
        finalize_block_header
          final_context.header
          ~timestamp:min_valid_timestamp
          validation_result
          operations
        >>= function
        | Error (Forking_test_chain :: _) ->
            Alpha_block_services.Helpers.Preapply.block
              cctxt
              ~chain
              ~block
              ~timestamp:min_valid_timestamp
              ~sort
              ~protocol_data
              operations
            >>=? fun (shell_header, _result) ->
            return (shell_header, List.map (List.map forge) operations)
        | Error _ as errs ->
            Lwt.return errs
        | Ok shell_header ->
            return (shell_header, List.map (List.map forge) operations)
      else
        lwt_log_notice
          Tag.DSL.(
            fun f ->
              f "New protocol detected: using shell validation"
              -% t event "shell_prevalidation_notice")
        >>= fun () ->
        Alpha_block_services.Helpers.Preapply.block
          cctxt
          ~chain
          ~block
          ~timestamp:min_valid_timestamp
          ~sort
          ~protocol_data
          operations
        >>=? fun (shell_header, _result) ->
        return (shell_header, List.map (List.map forge) operations) )
  >>=? fun (shell_header, operations) ->
  (* Now for some logging *)
  let total_op_count = List.length operations_arg in
  let valid_op_count = List.length (List.concat operations) in
  lwt_log_notice
    Tag.DSL.(
      fun f ->
        f
          "found %d valid operations (%d refused) for timestamp %a (fitness %a)"
        -% t event "found_valid_operations"
        -% s valid_ops valid_op_count
        -% s refused_ops (total_op_count - valid_op_count)
        -% a timestamp_tag (Time.System.of_protocol_exn timestamp)
        -% a fitness_tag shell_header.fitness)
  >>= fun () ->
  ( match Environment.wrap_error (Raw_level.of_int32 shell_header.level) with
  | Ok level ->
      return level
  | Error errs as err ->
      lwt_log_error
        Tag.DSL.(
          fun f ->
            f "Error on raw_level conversion : %a"
            -% t event "block_injection_failed"
            -% a errs_tag errs)
      >>= fun () -> Lwt.return err )
  >>=? fun level ->
  inject_block
    cctxt
    ?force
    ~chain
    ~shell_header
    ~priority
    ?seed_nonce_hash
    ~delegate_pkh
    ~delegate_sk
    ~level
    operations
  >>= function
  | Ok hash ->
      return hash
  | Error errs as error ->
      lwt_log_error
        Tag.DSL.(
          fun f ->
            f
              "@[<v 4>Error while injecting block@ @[Included operations : \
               %a@]@ %a@]"
            -% t event "block_injection_failed"
            -% a raw_operations_tag (List.concat operations)
            -% a errs_tag errs)
      >>= fun () -> Lwt.return error

let shell_prevalidation (cctxt : #Protocol_client_context.full) ~chain ~block
    ~timestamp seed_nonce_hash operations
    ((_, (bi, priority, delegate)) as _slot) =
  let protocol_data = forge_faked_protocol_data ~priority ~seed_nonce_hash in
  Alpha_block_services.Helpers.Preapply.block
    cctxt
    ~chain
    ~block
    ~timestamp
    ~sort:true
    ~protocol_data
    operations
  >>= function
  | Error errs ->
      lwt_log_error
        Tag.DSL.(
          fun f ->
            f
              "Shell-side validation: error while prevalidating operations:@\n\
               %a"
            -% t event "built_invalid_block_error"
            -% a errs_tag errs)
      >>= fun () -> return_none
  | Ok (shell_header, operations) ->
      let raw_ops =
        List.map (fun l -> List.map snd l.Preapply_result.applied) operations
      in
      return_some
        (bi, priority, shell_header, raw_ops, delegate, seed_nonce_hash)

let filter_outdated_endorsements expected_level ops =
  List.filter
    (function
      | { Alpha_context.protocol_data =
            Operation_data {contents = Single (Endorsement {level; _}); _};
          _ } ->
          Raw_level.equal expected_level level
      | _ ->
          true)
    ops

(** [fetch_operations] retrieve the operations present in the
    mempool. If no endorsements are present in the initial set, it
    waits until it's able to build a valid block. *)
let fetch_operations (cctxt : #Protocol_client_context.full) ~chain
    (_, (head, priority, _delegate)) =
  Alpha_block_services.Mempool.monitor_operations
    cctxt
    ~chain
    ~applied:true
    ~branch_delayed:true
    ~refused:false
    ~branch_refused:false
    ()
  >>=? fun (operation_stream, _stop) ->
  (* Hypothesis : the first call to the stream returns instantly, even if the mempool is empty. *)
  Lwt_stream.get operation_stream
  >>= function
  | None ->
      (* New head received : aborting block construction *)
      return_none
  | Some current_mempool ->
      let block = `Hash (head.Client_baking_blocks.hash, 0) in
      let operations =
        ref (filter_outdated_endorsements head.level current_mempool)
      in
      (* Actively request our peers' for missing operations *)
      Shell_services.Mempool.request_operations cctxt ~chain ()
      >>=? fun () ->
      let compute_minimal_valid_time () =
        compute_endorsing_power cctxt ~chain ~block !operations
        >>=? fun current_endorsing_power ->
        Delegate_services.Minimal_valid_time.get
          cctxt
          (chain, block)
          priority
          current_endorsing_power
      in
      let compute_timeout () =
        compute_minimal_valid_time ()
        >>=? fun expected_validity ->
        match Client_baking_scheduling.sleep_until expected_validity with
        | None ->
            return_unit
        | Some timeout ->
            timeout >>= fun () -> return_unit
      in
      let last_get_event = ref None in
      let get_event () =
        match !last_get_event with
        | None ->
            let t = Lwt_stream.get operation_stream in
            last_get_event := Some t ;
            t
        | Some t ->
            t
      in
      let rec loop () =
        Lwt.choose
          [ (compute_timeout () >|= fun _ -> `Timeout);
            (get_event () >|= fun e -> `Event e) ]
        >>= function
        | `Event (Some op_list) ->
            last_get_event := None ;
            let op_list = filter_outdated_endorsements head.level op_list in
            operations := op_list @ !operations ;
            loop ()
        | `Timeout ->
            (* Retrieve the remaining operations present in the stream
               before block construction *)
            let remaining_operations =
              filter_outdated_endorsements
                head.level
                (List.flatten (Lwt_stream.get_available operation_stream))
            in
            operations := remaining_operations @ !operations ;
            compute_minimal_valid_time ()
            >>=? fun expected_validity ->
            return_some (!operations, expected_validity)
        | `Event None ->
            (* Got new head while waiting:
               - not enough endorsements received ;
               - late at baking *)
            return_none
      in
      loop ()

(** Given a delegate baking slot [build_block] constructs a full block
    with consistent operations that went through the client-side
    validation *)
let build_block cctxt ~user_activated_upgrades state seed_nonce_hash
    ((slot_timestamp, (bi, priority, delegate)) as slot) =
  let chain = `Hash bi.Client_baking_blocks.chain_id in
  let block = `Hash (bi.hash, 0) in
  Alpha_services.Helpers.current_level cctxt ~offset:1l (chain, block)
  >>=? fun next_level ->
  let seed_nonce_hash =
    if next_level.Level.expected_commitment then Some seed_nonce_hash else None
  in
  Client_keys.Public_key_hash.name cctxt delegate
  >>=? fun name ->
  lwt_debug
    Tag.DSL.(
      fun f ->
        f "Try baking after %a (slot %d) for %s (%a)"
        -% t event "try_baking"
        -% a Block_hash.Logging.tag bi.hash
        -% s bake_priority_tag priority
        -% s Client_keys.Logging.tag name
        -% a timestamp_tag (Time.System.of_protocol_exn slot_timestamp))
  >>= fun () ->
  fetch_operations cctxt ~chain slot
  >>=? function
  | None ->
      lwt_log_notice
        Tag.DSL.(
          fun f ->
            f
              "Received a new head while waiting for operations. Aborting \
               this block."
            -% t event "new_head_received")
      >>= fun () -> return_none
  | Some (operations, timestamp) -> (
      let hard_gas_limit_per_block =
        state.constants.parametric.hard_gas_limit_per_block
      in
      classify_operations
        cctxt
        ~chain
        ~hard_gas_limit_per_block
        ~minimal_fees:state.minimal_fees
        ~minimal_nanotez_per_gas_unit:state.minimal_nanotez_per_gas_unit
        ~minimal_nanotez_per_byte:state.minimal_nanotez_per_byte
        ~block
        operations
      >>=? fun (operations, overflowing_ops) ->
      let next_version =
        match
          Tezos_base.Block_header.get_forced_protocol_upgrade
            ~user_activated_upgrades
            ~level:(Raw_level.to_int32 next_level.Level.level)
        with
        | None ->
            bi.next_protocol
        | Some hash ->
            hash
      in
      if Protocol_hash.(Protocol.hash <> next_version) then
        (* Let the shell validate this *)
        shell_prevalidation
          cctxt
          ~chain
          ~block
          ~timestamp
          seed_nonce_hash
          operations
          slot
      else
        let protocol_data =
          forge_faked_protocol_data ~priority ~seed_nonce_hash
        in
        filter_and_apply_operations
          cctxt
          state
          ~chain
          ~block
          ~priority
          ~protocol_data
          bi
          (operations, overflowing_ops)
        >>= function
        | Error errs ->
            lwt_log_error
              Tag.DSL.(
                fun f ->
                  f
                    "Client-side validation: error while filtering invalid \
                     operations :@\n\
                     @[<v 4>%a@]"
                  -% t event "client_side_validation_error"
                  -% a errs_tag errs)
            >>= fun () ->
            lwt_log_notice
              Tag.DSL.(
                fun f ->
                  f "Building a block using shell validation"
                  -% t event "shell_prevalidation_notice")
            >>= fun () ->
            shell_prevalidation
              cctxt
              ~chain
              ~block
              ~timestamp
              seed_nonce_hash
              operations
              slot
        | Ok
            (final_context, (validation_result, _), operations, valid_timestamp)
          ->
            ( if
              Time.System.(Systime_os.now () < of_protocol_exn valid_timestamp)
            then
              lwt_log_notice
                Tag.DSL.(
                  fun f ->
                    f "[%a] not ready to inject yet, waiting until %a"
                    -% a timestamp_tag (Systime_os.now ())
                    -% a
                         timestamp_tag
                         (Time.System.of_protocol_exn valid_timestamp)
                    -% t event "waiting_before_injection")
              >>= fun () ->
              match Client_baking_scheduling.sleep_until valid_timestamp with
              | None ->
                  Lwt.return_unit
              | Some timeout ->
                  timeout
            else Lwt.return_unit )
            >>= fun () ->
            lwt_debug
              Tag.DSL.(
                fun f ->
                  f
                    "Try forging locally the block header for %a (slot %d) \
                     for %s (%a)"
                  -% t event "try_forging"
                  -% a Block_hash.Logging.tag bi.hash
                  -% s bake_priority_tag priority
                  -% s Client_keys.Logging.tag name
                  -% a timestamp_tag (Time.System.of_protocol_exn timestamp))
            >>= fun () ->
            let current_protocol = bi.next_protocol in
            let context =
              Shell_context.unwrap_disk_context validation_result.context
            in
            Context.get_protocol context
            >>= fun next_protocol ->
            if Protocol_hash.equal current_protocol next_protocol then
              finalize_block_header
                final_context.header
                ~timestamp:valid_timestamp
                validation_result
                operations
              >>= function
              | Error (Forking_test_chain :: _) ->
                  shell_prevalidation
                    cctxt
                    ~chain
                    ~block
                    ~timestamp
                    seed_nonce_hash
                    operations
                    slot
              | Error _ as errs ->
                  Lwt.return errs
              | Ok shell_header ->
                  let raw_ops = List.map (List.map forge) operations in
                  return_some
                    ( bi,
                      priority,
                      shell_header,
                      raw_ops,
                      delegate,
                      seed_nonce_hash )
            else
              lwt_log_notice
                Tag.DSL.(
                  fun f ->
                    f "New protocol detected: using shell validation"
                    -% t event "shell_prevalidation_notice")
              >>= fun () ->
              shell_prevalidation
                cctxt
                ~chain
                ~block
                ~timestamp
                seed_nonce_hash
                operations
                slot )

(** [bake cctxt state] create a single block when woken up to do
    so. All the necessary information is available in the
    [state.best_slot]. *)
let bake (cctxt : #Protocol_client_context.full) ~user_activated_upgrades
    ~chain state =
  ( match state.best_slot with
  | None ->
      assert false (* unreachable *)
  | Some slot ->
      return slot )
  >>=? fun slot ->
  let seed_nonce = generate_seed_nonce () in
  let seed_nonce_hash = Nonce.hash seed_nonce in
  build_block cctxt ~user_activated_upgrades state seed_nonce_hash slot
  >>=? function
  | Some (head, priority, shell_header, operations, delegate, seed_nonce_hash)
    -> (
      let level = Raw_level.succ head.level in
      Client_keys.Public_key_hash.name cctxt delegate
      >>=? fun name ->
      lwt_log_info
        Tag.DSL.(
          fun f ->
            f "Injecting block (priority %d, fitness %a) for %s after %a..."
            -% t event "start_injecting_block"
            -% s bake_priority_tag priority
            -% a fitness_tag shell_header.fitness
            -% s Client_keys.Logging.tag name
            -% a Block_hash.Logging.predecessor_tag shell_header.predecessor
            -% t Signature.Public_key_hash.Logging.tag delegate)
      >>= fun () ->
      Client_keys.get_key cctxt delegate
      >>=? fun (_, _, delegate_sk) ->
      inject_block
        cctxt
        ~chain
        ~force:false
        ~shell_header
        ~priority
        ?seed_nonce_hash
        ~delegate_pkh:delegate
        ~delegate_sk
        ~level
        operations
      >>= function
      | Error errs ->
          lwt_log_error
            Tag.DSL.(
              fun f ->
                f
                  "@[<v 4>Error while injecting block@ @[Included operations \
                   : %a@]@ %a@]"
                -% t event "block_injection_failed"
                -% a raw_operations_tag (List.concat operations)
                -% a errs_tag errs)
          >>= fun () -> return_unit
      | Ok block_hash ->
          lwt_log_notice
            Tag.DSL.(
              fun f ->
                f
                  "Injected block %a for %s after %a (level %a, priority %d, \
                   fitness %a, operations %a)."
                -% t event "injected_block"
                -% a Block_hash.Logging.tag block_hash
                -% s Client_keys.Logging.tag name
                -% a Block_hash.Logging.tag shell_header.predecessor
                -% a level_tag level
                -% s bake_priority_tag priority
                -% a fitness_tag shell_header.fitness
                -% a operations_tag operations)
          >>= fun () ->
          ( if seed_nonce_hash <> None then
            cctxt#with_lock (fun () ->
                let open Client_baking_nonces in
                load cctxt state.nonces_location
                >>=? fun nonces ->
                let nonces = add nonces block_hash seed_nonce in
                save cctxt state.nonces_location nonces)
            |> trace_exn (Failure "Error while recording nonce")
          else return_unit )
          >>=? fun () -> return_unit )
  | None ->
      return_unit

(** [get_baking_slots] calls the node via RPC to retrieve the potential
    slots for the given delegates within a given range of priority *)
let get_baking_slots cctxt ?(max_priority = default_max_priority) new_head
    delegates =
  let chain = `Hash new_head.Client_baking_blocks.chain_id in
  let block = `Hash (new_head.hash, 0) in
  let level = Raw_level.succ new_head.level in
  Alpha_services.Delegate.Baking_rights.get
    cctxt
    ~max_priority
    ~levels:[level]
    ~delegates
    (chain, block)
  >>= function
  | Error errs ->
      lwt_log_error
        Tag.DSL.(
          fun f ->
            f "Error while fetching baking possibilities:\n%a"
            -% t event "baking_slot_fetch_errors"
            -% a errs_tag errs)
      >>= fun () -> Lwt.return_nil
  | Ok [] ->
      Lwt.return_nil
  | Ok slots ->
      let slots =
        List.filter_map
          (function
            | {Alpha_services.Delegate.Baking_rights.timestamp = None; _} ->
                None
            | {timestamp = Some timestamp; priority; delegate; _} ->
                Some (timestamp, (new_head, priority, delegate)))
          slots
      in
      Lwt.return slots

(** [compute_best_slot_on_current_level] retrieves, among the given
    delegates, the highest priority slot for the current level. Then,
    it registers this slot in the state so the timeout knows when to
    wake up. *)
let compute_best_slot_on_current_level ?max_priority
    (cctxt : #Protocol_client_context.full) state new_head =
  get_delegates cctxt state
  >>=? fun delegates ->
  let level = Raw_level.succ new_head.Client_baking_blocks.level in
  get_baking_slots cctxt ?max_priority new_head delegates
  >>= function
  | [] ->
      lwt_log_notice
        Tag.DSL.(
          fun f ->
            let max_priority =
              Option.unopt ~default:default_max_priority max_priority
            in
            f "No slot found at level %a (max_priority = %d)"
            -% t event "no_slot_found" -% a level_tag level
            -% s bake_priority_tag max_priority)
      >>= fun () -> return_none
      (* No slot found *)
  | h :: t ->
      (* One or more slot found, fetching the best (lowest) priority.
         We do not suppose that the received slots are sorted. *)
      let ((timestamp, (_, priority, delegate)) as best_slot) =
        List.fold_left
          (fun ((_, (_, priority, _)) as acc) ((_, (_, priority', _)) as slot) ->
            if priority < priority' then acc else slot)
          h
          t
      in
      Client_keys.Public_key_hash.name cctxt delegate
      >>=? fun name ->
      lwt_log_notice
        Tag.DSL.(
          fun f ->
            f
              "New baking slot found (level %a, priority %d) at %a for %s \
               after %a."
            -% t event "have_baking_slot" -% a level_tag level
            -% s bake_priority_tag priority
            -% a timestamp_tag (Time.System.of_protocol_exn timestamp)
            -% s Client_keys.Logging.tag name
            -% a Block_hash.Logging.tag new_head.hash
            -% t Signature.Public_key_hash.Logging.tag delegate)
      >>= fun () ->
      (* Found at least a slot *)
      return_some best_slot

(** [reveal_potential_nonces] reveal registered nonces *)
let reveal_potential_nonces (cctxt : #Client_context.full) constants ~chain
    ~block =
  cctxt#with_lock (fun () ->
      Client_baking_files.resolve_location cctxt ~chain `Nonce
      >>=? fun nonces_location ->
      Client_baking_nonces.load cctxt nonces_location
      >>= function
      | Error err ->
          lwt_log_error
            Tag.DSL.(
              fun f ->
                f "Cannot read nonces: %a" -% t event "read_nonce_fail"
                -% a errs_tag err)
          >>= fun () -> return_unit
      | Ok nonces -> (
          Client_baking_nonces.get_unrevealed_nonces
            cctxt
            nonces_location
            nonces
          >>= function
          | Error err ->
              lwt_log_error
                Tag.DSL.(
                  fun f ->
                    f "Cannot retrieve unrevealed nonces: %a"
                    -% t event "nonce_retrieval_fail"
                    -% a errs_tag err)
              >>= fun () -> return_unit
          | Ok [] ->
              return_unit
          | Ok nonces_to_reveal -> (
              Client_baking_revelation.inject_seed_nonce_revelation
                cctxt
                ~chain
                ~block
                nonces_to_reveal
              >>= function
              | Error err ->
                  lwt_log_error
                    Tag.DSL.(
                      fun f ->
                        f "Cannot inject nonces: %a"
                        -% t event "nonce_injection_fail"
                        -% a errs_tag err)
                  >>= fun () -> return_unit
              | Ok () ->
                  (* If some nonces are to be revealed it means:
                   - We entered a new cycle and we can clear old nonces ;
                   - A revelation was not included yet in the cycle beggining.
                   So, it is safe to only filter outdated_nonces there *)
                  Client_baking_nonces.filter_outdated_nonces
                    cctxt
                    ~constants
                    nonces_location
                    nonces
                  >>=? fun live_nonces ->
                  Client_baking_nonces.save cctxt nonces_location live_nonces
                  >>=? fun () -> return_unit ) ))

(** [create] starts the main loop of the baker. The loop monitors new blocks and
    starts individual baking operations when baking-slots are available to any of
    the [delegates] *)
let create (cctxt : #Protocol_client_context.full) ~user_activated_upgrades
    ?minimal_fees ?minimal_nanotez_per_gas_unit ?minimal_nanotez_per_byte
    ?max_priority ~chain ~context_path delegates block_stream =
  let state_maker bi =
    Alpha_services.Constants.all cctxt (chain, `Head 0)
    >>=? fun constants ->
    Client_baking_simulator.load_context ~context_path
    >>= fun index ->
    Client_baking_simulator.check_context_consistency
      index
      bi.Client_baking_blocks.context
    >>=? fun () ->
    Client_baking_files.resolve_location cctxt ~chain `Nonce
    >>=? fun nonces_location ->
    let state =
      create_state
        ?minimal_fees
        ?minimal_nanotez_per_gas_unit
        ?minimal_nanotez_per_byte
        context_path
        index
        nonces_location
        delegates
        constants
    in
    return state
  in
  let event_k cctxt state new_head =
    reveal_potential_nonces
      cctxt
      state.constants
      ~chain
      ~block:(`Hash (new_head.Client_baking_blocks.hash, 0))
    >>= fun _ignore_nonce_err ->
    compute_best_slot_on_current_level ?max_priority cctxt state new_head
    >>=? fun slot ->
    state.best_slot <- slot ;
    return_unit
  in
  let compute_timeout state =
    match state.best_slot with
    | None ->
        (* No slot, just wait for new blocks which will give more info *)
        Lwt_utils.never_ending ()
    | Some (timestamp, _) -> (
      match Client_baking_scheduling.sleep_until timestamp with
      | None ->
          Lwt.return_unit
      | Some timeout ->
          timeout )
  in
  let timeout_k cctxt state () =
    bake cctxt ~user_activated_upgrades ~chain state
    >>=? fun () ->
    (* Stopping the timeout and waiting for the next block *)
    state.best_slot <- None ;
    return_unit
  in
  Client_baking_scheduling.main
    ~name:"baker"
    ~cctxt
    ~stream:block_stream
    ~state_maker
    ~pre_loop:event_k
    ~compute_timeout
    ~timeout_k
    ~event_k
