(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Nomadic Development. <contact@tezcore.com>             *)
(* Copyright (c) 2021-2022 Nomadic Labs, <contact@nomadic-labs.com>          *)
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

type error_classification =
  [ `Branch_delayed of tztrace
  | `Branch_refused of tztrace
  | `Refused of tztrace
  | `Outdated of tztrace ]

type nanotez = Q.t

let nanotez_enc : nanotez Data_encoding.t =
  let open Data_encoding in
  def
    "nanotez"
    ~title:"A thousandth of a mutez"
    ~description:"One thousand nanotez make a mutez (1 tez = 1e9 nanotez)"
    (conv
       (fun q -> (q.Q.num, q.Q.den))
       (fun (num, den) -> {Q.num; den})
       (tup2 z z))

let manager_op_replacement_factor_enc : Q.t Data_encoding.t =
  let open Data_encoding in
  def
    "manager operation replacement factor"
    ~title:"A manager operation's replacement factor"
    ~description:"The fee and fee/gas ratio of an operation to replace another"
    (conv
       (fun q -> (q.Q.num, q.Q.den))
       (fun (num, den) -> {Q.num; den})
       (tup2 z z))

type config = {
  minimal_fees : Tez.t;
  minimal_nanotez_per_gas_unit : nanotez;
  minimal_nanotez_per_byte : nanotez;
  allow_script_failure : bool;
      (** If [true], this makes [post_filter_manager] unconditionally return
            [`Passed_postfilter filter_state], no matter the operation's
            success. *)
  clock_drift : Period.t option;
  replace_by_fee_factor : Q.t;
      (** This field determines the amount of additional fees (given as a
            factor of the declared fees) a manager should add to an operation
            in order to (eventually) replace an existing (prechecked) one
            in the mempool. Note that other criteria, such as the gas ratio,
            are also taken into account to decide whether to accept the
            replacement or not. *)
  max_prechecked_manager_operations : int;
      (** Maximal number of prechecked operations to keep. The mempool only
            keeps the [max_prechecked_manager_operations] operations with the
            highest fee/gas and fee/size ratios. *)
}

let default_minimal_fees =
  match Tez.of_mutez 100L with None -> assert false | Some t -> t

let default_minimal_nanotez_per_gas_unit = Q.of_int 100

let default_minimal_nanotez_per_byte = Q.of_int 1000

let quota = Main.validation_passes

let managers_index = 3 (* in Main.validation_passes *)

let managers_quota = Stdlib.List.nth quota managers_index

(* If the drift is not specified, it will be the duration of round zero.
   It allows only to spam with one future round.

   /!\ Warning /!\ : current plugin implementation implies that this drift
   cumulates with the accepted  drift regarding the current head's timestamp.
*)
let default_config =
  {
    minimal_fees = default_minimal_fees;
    minimal_nanotez_per_gas_unit = default_minimal_nanotez_per_gas_unit;
    minimal_nanotez_per_byte = default_minimal_nanotez_per_byte;
    allow_script_failure = true;
    clock_drift = None;
    replace_by_fee_factor =
      Q.make (Z.of_int 105) (Z.of_int 100)
      (* Default value of [replace_by_fee_factor] is set to 5% *);
    max_prechecked_manager_operations = 5_000;
  }

let config_encoding : config Data_encoding.t =
  let open Data_encoding in
  conv
    (fun {
           minimal_fees;
           minimal_nanotez_per_gas_unit;
           minimal_nanotez_per_byte;
           allow_script_failure;
           clock_drift;
           replace_by_fee_factor;
           max_prechecked_manager_operations;
         } ->
      ( minimal_fees,
        minimal_nanotez_per_gas_unit,
        minimal_nanotez_per_byte,
        allow_script_failure,
        clock_drift,
        replace_by_fee_factor,
        max_prechecked_manager_operations ))
    (fun ( minimal_fees,
           minimal_nanotez_per_gas_unit,
           minimal_nanotez_per_byte,
           allow_script_failure,
           clock_drift,
           replace_by_fee_factor,
           max_prechecked_manager_operations ) ->
      {
        minimal_fees;
        minimal_nanotez_per_gas_unit;
        minimal_nanotez_per_byte;
        allow_script_failure;
        clock_drift;
        replace_by_fee_factor;
        max_prechecked_manager_operations;
      })
    (obj7
       (dft "minimal_fees" Tez.encoding default_config.minimal_fees)
       (dft
          "minimal_nanotez_per_gas_unit"
          nanotez_enc
          default_config.minimal_nanotez_per_gas_unit)
       (dft
          "minimal_nanotez_per_byte"
          nanotez_enc
          default_config.minimal_nanotez_per_byte)
       (dft "allow_script_failure" bool default_config.allow_script_failure)
       (opt "clock_drift" Period.encoding)
       (dft
          "replace_by_fee_factor"
          manager_op_replacement_factor_enc
          default_config.replace_by_fee_factor)
       (dft
          "max_prechecked_manager_operations"
          int31
          default_config.max_prechecked_manager_operations))

(* For each Prechecked manager operation (batched or not), we associate the
   following information to its source:
   - the operation's hash, needed in case the operation is replaced
     afterwards,
   - the total fee and gas_limit, needed to compare operations of the same
     manager to decide which one has more fees w.r.t. announced gas limit
     (modulo replace_by_fee_factor)
*)
type manager_op_info = {
  operation_hash : Operation_hash.t;
  gas_limit : Gas.Arith.fp;
  fee : Tez.t;
  weight : Q.t;
}

type manager_op_weight = {operation_hash : Operation_hash.t; weight : Q.t}

let op_weight_of_info (info : manager_op_info) : manager_op_weight =
  {operation_hash = info.operation_hash; weight = info.weight}

module ManagerOpWeightSet = Set.Make (struct
  type t = manager_op_weight

  (* Sort by weight *)
  let compare op1 op2 =
    let c = Q.compare op1.weight op2.weight in
    if c <> 0 then c
    else Operation_hash.compare op1.operation_hash op2.operation_hash
end)

type state = {
  grandparent_level_start : Timestamp.t option;
  round_zero_duration : Period.t option;
  op_prechecked_managers : manager_op_info Signature.Public_key_hash.Map.t;
      (** All managers that are the source of manager operations
            prechecked in the mempool. Each manager in the map is associated to
            a record of type [manager_op_info] (See for record details above).
            Each manager in the map should be accessible
            with an operation hash in [operation_hash_to_manager]. *)
  operation_hash_to_manager : Signature.Public_key_hash.t Operation_hash.Map.t;
      (** Map of operation hash to manager used to remove a manager from
            [op_prechecked_managers] with an operation hash. Each manager in the
            map should also be in [op_prechecked_managers]. *)
  prechecked_operations_count : int;
      (** Number of prechecked manager operations.
            Invariants:
            - [Operation_hash.Map.cardinal operation_hash_to_manager =
               prechecked_operations_count]
            - [prechecked_operations_count <= max_prechecked_manager_operations] *)
  ops_prechecked : ManagerOpWeightSet.t;
  min_prechecked_op_weight : manager_op_weight option;
      (** The prechecked operation in [op_prechecked_managers], if any, with
            the minimal weight.
            Invariant:
            - [min_prechecked_op_weight = min { x | x \in ops_prechecked }] *)
}

let empty : state =
  {
    grandparent_level_start = None;
    round_zero_duration = None;
    op_prechecked_managers = Signature.Public_key_hash.Map.empty;
    operation_hash_to_manager = Operation_hash.Map.empty;
    prechecked_operations_count = 0;
    ops_prechecked = ManagerOpWeightSet.empty;
    min_prechecked_op_weight = None;
  }

let init config ?(validation_state : validation_state option) ~predecessor () =
  ignore config ;
  (match validation_state with
  | None -> return empty
  | Some {ctxt; _} ->
      let {
        Tezos_base.Block_header.fitness = predecessor_fitness;
        timestamp = predecessor_timestamp;
        _;
      } =
        predecessor.Tezos_base.Block_header.shell
      in
      Alpha_context.Fitness.predecessor_round_from_raw predecessor_fitness
      >>?= fun grandparent_round ->
      Alpha_context.Fitness.round_from_raw predecessor_fitness
      >>?= fun predecessor_round ->
      let round_durations = Constants.round_durations ctxt in
      let round_zero_duration =
        Round.round_duration round_durations Round.zero
      in
      Round.level_offset_of_round
        round_durations
        ~round:Round.(succ grandparent_round)
      >>?= fun proposal_level_offset ->
      Round.level_offset_of_round round_durations ~round:predecessor_round
      >>?= fun proposal_round_offset ->
      Period.(add proposal_level_offset proposal_round_offset)
      >>?= fun proposal_offset ->
      return
        {
          empty with
          grandparent_level_start =
            Some Timestamp.(predecessor_timestamp - proposal_offset);
          round_zero_duration = Some round_zero_duration;
        })
  >|= Environment.wrap_tzresult

let manager_prio p = `Low p

let consensus_prio = `High

let other_prio = `Medium

let on_flush config filter_state ?(validation_state : validation_state option)
    ~predecessor () =
  ignore filter_state ;
  init config ?validation_state ~predecessor ()

let remove ~(filter_state : state) oph =
  let removed_oph_source = ref None in
  let operation_hash_to_manager =
    Operation_hash.Map.update
      oph
      (function
        | None -> None
        | Some source ->
            removed_oph_source := Some source ;
            None)
      filter_state.operation_hash_to_manager
  in
  match !removed_oph_source with
  | None ->
      (* Not present anywhere in the filter state, because of invariants.
         See {!state} *)
      filter_state
  | Some source ->
      let prechecked_operations_count =
        filter_state.prechecked_operations_count - 1
      in
      let removed_op = ref None in
      let op_prechecked_managers =
        Signature.Public_key_hash.Map.update
          source
          (function
            | None -> None
            | Some op ->
                removed_op := Some op ;
                None)
          filter_state.op_prechecked_managers
      in
      let ops_prechecked =
        match !removed_op with
        | None -> filter_state.ops_prechecked
        | Some op ->
            ManagerOpWeightSet.remove
              (op_weight_of_info op)
              filter_state.ops_prechecked
      in
      let min_prechecked_op_weight =
        match filter_state.min_prechecked_op_weight with
        | None -> None
        | Some op ->
            if Operation_hash.equal op.operation_hash oph then
              ManagerOpWeightSet.min_elt ops_prechecked
            else Some op
      in
      {
        filter_state with
        op_prechecked_managers;
        operation_hash_to_manager;
        ops_prechecked;
        prechecked_operations_count;
        min_prechecked_op_weight;
      }

let get_manager_operation_gas_and_fee contents =
  let open Operation in
  let l = to_list (Contents_list contents) in
  List.fold_left
    (fun acc -> function
      | Contents (Manager_operation {fee; gas_limit; _}) -> (
          match acc with
          | Error _ as e -> e
          | Ok (total_fee, total_gas) -> (
              match Tez.(total_fee +? fee) with
              | Ok total_fee -> Ok (total_fee, Gas.Arith.add total_gas gas_limit)
              | Error _ as e -> e))
      | _ -> acc)
    (Ok (Tez.zero, Gas.Arith.zero))
    l

type Environment.Error_monad.error += Fees_too_low

let () =
  Environment.Error_monad.register_error_kind
    `Permanent
    ~id:"prefilter.fees_too_low"
    ~title:"Operation fees are too low"
    ~description:"Operation fees are too low"
    ~pp:(fun ppf () -> Format.fprintf ppf "Operation fees are too low")
    Data_encoding.unit
    (function Fees_too_low -> Some () | _ -> None)
    (fun () -> Fees_too_low)

type Environment.Error_monad.error +=
  | Manager_restriction of {oph : Operation_hash.t; fee : Tez.t}

let () =
  Environment.Error_monad.register_error_kind
    `Temporary
    ~id:"prefilter.manager_restriction"
    ~title:"Only one manager operation per manager per block allowed"
    ~description:"Only one manager operation per manager per block allowed"
    ~pp:(fun ppf (oph, fee) ->
      Format.fprintf
        ppf
        "Only one manager operation per manager per block allowed (found %a \
         with %atez fee. You may want to use --replace to provide adequate fee \
         and replace it)."
        Operation_hash.pp
        oph
        Tez.pp
        fee)
    Data_encoding.(
      obj2
        (req "operation_hash" Operation_hash.encoding)
        (req "operation_fee" Tez.encoding))
    (function Manager_restriction {oph; fee} -> Some (oph, fee) | _ -> None)
    (fun (oph, fee) -> Manager_restriction {oph; fee})

type Environment.Error_monad.error +=
  | Manager_operation_replaced of {
      old_hash : Operation_hash.t;
      new_hash : Operation_hash.t;
    }

let () =
  Environment.Error_monad.register_error_kind
    `Permanent
    ~id:"plugin.manager_operation_replaced"
    ~title:"Manager operation replaced"
    ~description:"The manager operation has been replaced"
    ~pp:(fun ppf (old_hash, new_hash) ->
      Format.fprintf
        ppf
        "The manager operation %a has been replaced with %a"
        Operation_hash.pp
        old_hash
        Operation_hash.pp
        new_hash)
    (Data_encoding.obj2
       (Data_encoding.req "old_hash" Operation_hash.encoding)
       (Data_encoding.req "new_hash" Operation_hash.encoding))
    (function
      | Manager_operation_replaced {old_hash; new_hash} ->
          Some (old_hash, new_hash)
      | _ -> None)
    (fun (old_hash, new_hash) ->
      Manager_operation_replaced {old_hash; new_hash})

type Environment.Error_monad.error += Fees_too_low_for_mempool of Tez.t

let () =
  Environment.Error_monad.register_error_kind
    `Temporary
    ~id:"prefilter.fees_too_low_for_mempool"
    ~title:"Operation fees are too low to be considered in full mempool"
    ~description:"Operation fees are too low to be considered in full mempool"
    ~pp:(fun ppf required_fees ->
      Format.fprintf
        ppf
        "The mempool is full, the number of prechecked manager operations has \
         reached the limit max_prechecked_manager_operations set by the \
         filter. Increase operation fees to at least %atz for the operation to \
         be considered and propagated by THIS node. Note that the operations \
         with the minimum fees in the mempool risk being removed if better \
         ones are received."
        Tez.pp
        required_fees)
    Data_encoding.(obj1 (req "required_fees" Tez.encoding))
    (function
      | Fees_too_low_for_mempool required_fees -> Some required_fees | _ -> None)
    (fun required_fees -> Fees_too_low_for_mempool required_fees)

type Environment.Error_monad.error += Removed_fees_too_low_for_mempool

let () =
  Environment.Error_monad.register_error_kind
    `Temporary
    ~id:"plugin.removed_fees_too_low_for_mempool"
    ~title:"Operation removed because fees are too low for full mempool"
    ~description:"Operation removed because fees are too low for full mempool"
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "The mempool is full, the number of prechecked manager operations has \
         reached the limit max_prechecked_manager_operations set by the \
         filter. Operation was removed because another operation with a better \
         fees/gas-size ratio was received and accepted by the mempool.")
    Data_encoding.unit
    (function Removed_fees_too_low_for_mempool -> Some () | _ -> None)
    (fun () -> Removed_fees_too_low_for_mempool)

(* TODO: https://gitlab.com/tezos/tezos/-/issues/2238
   Write unit tests for the feature 'replace-by-fee' and for other changes
   introduced by other MRs in the plugin. *)
(* In order to decide if the new operation can replace an old one from the
   same manager, we check if its fees (resp. fees/gas ratio) are greater than
   (or equal to) the old operations's fees (resp. fees/gas ratio), bumped by
   the factor [config.replace_by_fee_factor].
*)
let better_fees_and_ratio =
  let bump config q = Q.mul q config.replace_by_fee_factor in
  fun config old_gas old_fee new_gas new_fee ->
    let old_fee = Tez.to_mutez old_fee |> Z.of_int64 |> Q.of_bigint in
    let old_gas = Gas.Arith.integral_to_z old_gas |> Q.of_bigint in
    let new_fee = Tez.to_mutez new_fee |> Z.of_int64 |> Q.of_bigint in
    let new_gas = Gas.Arith.integral_to_z new_gas |> Q.of_bigint in
    let old_ratio = Q.div old_fee old_gas in
    let new_ratio = Q.div new_fee new_gas in
    Q.compare new_ratio (bump config old_ratio) >= 0
    && Q.compare new_fee (bump config old_fee) >= 0

let check_manager_restriction config filter_state source ~fee ~gas_limit =
  match
    Signature.Public_key_hash.Map.find
      source
      filter_state.op_prechecked_managers
  with
  | None -> `Fresh
  | Some
      {
        operation_hash = old_hash;
        gas_limit = old_gas;
        fee = old_fee;
        weight = _;
      } ->
      (* Manager already seen: one manager per block limitation triggered.
         Can replace old operation if new operation's fees are better *)
      if
        better_fees_and_ratio
          config
          (Gas.Arith.floor old_gas)
          old_fee
          gas_limit
          fee
      then `Replace old_hash
      else
        `Fail
          (`Branch_delayed
            [
              Environment.wrap_tzerror
                (Manager_restriction {oph = old_hash; fee = old_fee});
            ])

let size_of_operation op =
  (WithExceptions.Option.get ~loc:__LOC__
  @@ Data_encoding.Binary.fixed_length
       Tezos_base.Operation.shell_header_encoding)
  + Data_encoding.Binary.length Operation.protocol_data_encoding op

(** Returns the weight and resources consumption of an operation. The weight
      corresponds to the one implemented by the baker, to decide which operations
      to put in a block first (the code is largely duplicated).
      See {!Tezos_baking_alpha.Operation_selection.weight_manager} *)
let weight_and_resources_manager_operation ~validation_state ?size ~fee ~gas op
    =
  let hard_gas_limit_per_block =
    Constants.hard_gas_limit_per_block validation_state.ctxt
  in
  let max_size = managers_quota.max_size in
  let size = match size with None -> size_of_operation op | Some s -> s in
  let size_f = Q.of_int size in
  let gas_f = Q.of_bigint (Gas.Arith.integral_to_z gas) in
  let fee_f = Q.of_int64 (Tez.to_mutez fee) in
  let size_ratio = Q.(size_f / Q.of_int max_size) in
  let gas_ratio =
    Q.(gas_f / Q.of_bigint (Gas.Arith.integral_to_z hard_gas_limit_per_block))
  in
  let resources = Q.max size_ratio gas_ratio in
  (Q.(fee_f / resources), resources)

(** Returns the weight of an operation, i.e. the fees w.r.t the gas and size
      consumption in the block. *)
let weight_manager_operation ~validation_state ?size ~fee ~gas op =
  let weight, _resources =
    weight_and_resources_manager_operation ~validation_state ?size ~fee ~gas op
  in
  weight

(** Return fee for an operation that consumes [op_resources] for its weight to
      be strictly greater than [min_weight]. *)
let required_fee_manager_operation_weight ~op_resources ~min_weight =
  let req_mutez_q = Q.((min_weight * op_resources) + Q.one) in
  Tez.of_mutez_exn @@ Q.to_int64 req_mutez_q

(** Check if an operation as a weight (fees w.r.t gas and size) large enough to
      be prechecked and return said weight. In the case where the prechecked
      mempool is full, return an error if the weight is too small, or return the
      operation to be replaced otherwise. *)
let check_minimal_weight ?validation_state config filter_state ~fee ~gas_limit
    op =
  match validation_state with
  | None -> `Weight_ok (`No_replace, [])
  | Some validation_state -> (
      let weight, op_resources =
        weight_and_resources_manager_operation
          ~validation_state
          ~fee
          ~gas:gas_limit
          op
      in
      if
        filter_state.prechecked_operations_count
        < config.max_prechecked_manager_operations
      then
        (* The precheck mempool is not full yet *)
        `Weight_ok (`No_replace, [weight])
      else
        match filter_state.min_prechecked_op_weight with
        | None ->
            (* The precheck mempool is empty *)
            `Weight_ok (`No_replace, [weight])
        | Some {weight = min_weight; operation_hash = min_oph} ->
            if Q.(weight > min_weight) then
              (* The operation has a weight greater than the minimal
                 prechecked operation, replace the latest with the new one *)
              `Weight_ok (`Replace min_oph, [weight])
            else
              (* Otherwise fail and give indication as to what to fee should
                 be for the operation to be prechecked *)
              let required_fee =
                required_fee_manager_operation_weight ~op_resources ~min_weight
              in
              `Fail
                (`Branch_delayed
                  [
                    Environment.wrap_tzerror
                      (Fees_too_low_for_mempool required_fee);
                  ]))

let pre_filter_manager :
    type t.
    config ->
    state ->
    validation_state_before:validation_state option ->
    public_key_hash ->
    Operation.packed_protocol_data ->
    t Kind.manager contents_list ->
    [ `Passed_prefilter of Q.t list
    | `Branch_refused of tztrace
    | `Branch_delayed of tztrace
    | `Refused of tztrace
    | `Outdated of tztrace ] =
 fun config filter_state ~validation_state_before source packed_op op ->
  let size = size_of_operation packed_op in
  let check_gas_and_fee fee gas_limit =
    let fees_in_nanotez =
      Q.mul (Q.of_int64 (Tez.to_mutez fee)) (Q.of_int 1000)
    in
    let minimal_fees_in_nanotez =
      Q.mul (Q.of_int64 (Tez.to_mutez config.minimal_fees)) (Q.of_int 1000)
    in
    let minimal_fees_for_gas_in_nanotez =
      Q.mul
        config.minimal_nanotez_per_gas_unit
        (Q.of_bigint @@ Gas.Arith.integral_to_z gas_limit)
    in
    let minimal_fees_for_size_in_nanotez =
      Q.mul config.minimal_nanotez_per_byte (Q.of_int size)
    in
    if
      Q.compare
        fees_in_nanotez
        (Q.add
           minimal_fees_in_nanotez
           (Q.add
              minimal_fees_for_gas_in_nanotez
              minimal_fees_for_size_in_nanotez))
      >= 0
    then `Fees_ok
    else `Refused [Environment.wrap_tzerror Fees_too_low]
  in
  match get_manager_operation_gas_and_fee op with
  | Error err -> `Refused (Environment.wrap_tztrace err)
  | Ok (fee, gas_limit) -> (
      match
        check_manager_restriction config filter_state source ~fee ~gas_limit
      with
      | `Fail errs -> errs
      | `Fresh | `Replace _ -> (
          match check_gas_and_fee fee gas_limit with
          | `Refused _ as err -> err
          | `Fees_ok -> (
              match
                check_minimal_weight
                  ?validation_state:validation_state_before
                  config
                  filter_state
                  ~fee
                  ~gas_limit
                  packed_op
              with
              | `Fail errs -> errs
              | `Weight_ok (_, weight) -> `Passed_prefilter weight)))

type Environment.Error_monad.error += Outdated_endorsement

let () =
  Environment.Error_monad.register_error_kind
    `Temporary
    ~id:"prefilter.outdated_endorsement"
    ~title:"Endorsement is outdated"
    ~description:"Endorsement is outdated"
    ~pp:(fun ppf () -> Format.fprintf ppf "Endorsement is outdated")
    Data_encoding.unit
    (function Outdated_endorsement -> Some () | _ -> None)
    (fun () -> Outdated_endorsement)

type Environment.Error_monad.error += Wrong_operation

let () =
  Environment.Error_monad.register_error_kind
    `Temporary
    ~id:"prefilter.wrong_operation"
    ~title:"Wrong operation"
    ~description:"Failing_noop and old endorsement format are not accepted."
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Failing_noop and old endorsement format are not accepted")
    Data_encoding.unit
    (function Wrong_operation -> Some () | _ -> None)
    (fun () -> Wrong_operation)

type Environment.Error_monad.error += Consensus_operation_in_far_future

let () =
  Environment.Error_monad.register_error_kind
    `Branch
    ~id:"prefilter.Consensus_operation_in_far_future"
    ~title:"Consensus operation in far future"
    ~description:"Consensus operation too far in the future are not accepted."
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Consensus operation too far in the future are not accepted.")
    Data_encoding.unit
    (function Consensus_operation_in_far_future -> Some () | _ -> None)
    (fun () -> Consensus_operation_in_far_future)

(** {2 consensus operation filtering}

     In Tenderbake, we increased a lot the number of consensus
      operations, therefore it seems necessary to be able to filter consensus
     operations that could be produced by a Byzantine baker mis-using
     its right to produce operations in future rounds or levels.

      We consider the situation where the head is at level [h_l],
     round [h_r], and with timestamp [h_ts], with the predecessor of the head
     being at round [hp_r].
      We receive at a time [now] a consensus operation for level [op_l] and
     round [op_r].

       A consensus operation is considered too far in the future, and therefore filtered,
      if the earliest possible starting time of its round is greater than the
      current time plus a safety margin of [config.clock_drift].

      To consider potential level 2 reorgs, we first compute the expected
      timestamp of round zero at previous level [hp0_ts],

      All ops at level p_l and round r' such that time(r') is greater than (now + drift) are
     deemed too far in the future:

                  h_r                          op_ts    now+drift     (h_l,r')
     hp0_ts h_0   h_l                            |        |              |
        +----+-----+---------+-------------------+--+-----+--------------+-----------
             |     |         |                   |  |     |              |
             |    h_ts     h_r end time          | now    |        earliest expected
             |     |                             |        |        time of round r'
             |<----op_r rounds duration -------->|        |
                   |
                   |<--------------- operations kept ---->|<-rejected----------...
                   |
                   |<-----------operations considered by the filter -----------...

    For an operation on a proposal at the next level, we consider the minimum
    starting time of the operation's round, obtained by assuming that the proposal
    at the next level was built on top of a proposal at round 0 for the current
    level, itself based on a proposal at round 0 of previous level.
    Operations on proposal with higher levels are treated similarly.

    All ops at the next level and round r' such that timestamp(r') > now+drift
    are deemed too far in the future.

                r=0     r=1   h_r      now     now+drift   (h_l+1,r')
   hp0_ts h_0   h_l           h_l       |          |          |
      +----+---- |-------+----+---------+----------+----------+----------
           |     |       |    |                               |
           |     t0      |   h_ts                      earliest expected
           |     |       |    |                         time of round r'
           |<--- |    earliest|                               |
                 |  next level|                               |
                 |       |<---------------------------------->|
                                  round_offset(r')

  *)

(** At a given level a consensus operation is acceptable if its earliest
      expected timestamp, [op_earliest_ts] is below the current clock with an
      accepted drift for the clock given by a configuration.  *)
let acceptable ~drift ~op_earliest_ts ~now_timestamp =
  Timestamp.(
    now_timestamp +? drift >|? fun now_drifted -> op_earliest_ts <= now_drifted)

(** Check that an operation with the given [op_round], at level [op_level]
      is likely to be correct, meaning it could have been produced before
      now (+ the safety margin from configuration).

      Given an operation at level greater or equal than/to the current level, we
      compute the expected timestamp of the operation's round. If the operation
      is at a greater level, we assume that it is based on the proposal at round
      zero of the current level.

      All operations whose (level, round) is lower than or equal to the current
      head are deemed valid.
      Note that in case where their is a high drift in the computer clock, they
      might not have been considered valid by comparing their expected timestamp
      to the clock.

      This is a stricter than necessary filter as it will reject operations that
      could be valid in the current timeframe if the proposal they endorse is
      built over a predecessor of the current proposal that would be of lower
      round than the current one.

      What can we do that would be smarter: get current head's predecessor round
      and timestamp to compute the timestamp t0 of a predecessor that would have
      been proposed at round 0.

      Timestamp of round at current level for an alternative head that would be
      based on such proposal would be computed based on t0.
      For level higher than current head, compute the round's earliest timestamp
      if all proposal passed at round 0 starting from t0.
  *)
let acceptable_op ~config ~round_durations ~round_zero_duration ~proposal_level
    ~proposal_round ~proposal_timestamp
    ~(proposal_predecessor_level_start : Timestamp.t) ~op_level ~op_round
    ~now_timestamp =
  if
    Raw_level.(succ op_level < proposal_level)
    || (op_level = proposal_level && op_round <= proposal_round)
  then
    (* Past and current round operations are not in the future *)
    (* This case could be handled directly in `pre_filter_far_future_consensus_ops`
       for a (slightly) better performance. *)
    Ok true
  else
    (* If, by some tolerance on local clock drift, the timestamp of the
       current head is itself in the future, we use this time instead of
       now_timestamp *)
    let now_timestamp = Timestamp.(max now_timestamp proposal_timestamp) in
    (* Computing when the current level started. *)
    let drift = Option.value ~default:round_zero_duration config.clock_drift in
    (* We compute the earliest timestamp possible [op_earliest_ts] for the
       operation's (level,round), as if all proposals were accepted at round 0
       since the previous level. *)
    (* Invariant: [op_level + 1 >= proposal_level] *)
    let level_offset = Raw_level.(diff (succ op_level) proposal_level) in
    Period.mult level_offset round_zero_duration >>? fun time_shift ->
    Timestamp.(proposal_predecessor_level_start +? time_shift)
    >>? fun earliest_op_level_start ->
    (* computing the operations's round start from it's earliest
       possible level start *)
    Round.timestamp_of_another_round_same_level
      round_durations
      ~current_round:Round.zero
      ~current_timestamp:earliest_op_level_start
      ~considered_round:op_round
    >>? fun op_earliest_ts ->
    (* We finally check that the expected time of the operation is
       acceptable *)
    acceptable ~drift ~op_earliest_ts ~now_timestamp

let pre_filter_far_future_consensus_ops config
    ~filter_state:({grandparent_level_start; round_zero_duration; _} : state)
    ?validation_state_before
    ({level = op_level; round = op_round; _} : consensus_content) : bool Lwt.t =
  match
    (grandparent_level_start, validation_state_before, round_zero_duration)
  with
  | None, _, _ | _, None, _ | _, _, None -> Lwt.return_true
  | ( Some grandparent_level_start,
      Some validation_state_before,
      Some round_zero_duration ) -> (
      let ctxt : t = validation_state_before.ctxt in
      match validation_state_before.mode with
      | Application _ | Partial_application _ | Full_construction _ ->
          assert false
      (* Prefilter is always applied in mempool mode aka Partial_construction *)
      | Partial_construction {predecessor_round = proposal_round; _} -> (
          (let proposal_timestamp = Alpha_context.Timestamp.predecessor ctxt in
           let now_timestamp = Time.System.now () |> Time.System.to_protocol in
           let Level.{level; _} = Alpha_context.Level.current ctxt in
           let proposal_level =
             match Raw_level.pred level with
             | None ->
                 (* mempool level is set to the successor of the
                    current head *)
                 assert false
             | Some proposal_level -> proposal_level
           in
           let round_durations = Alpha_context.Constants.round_durations ctxt in
           Lwt.return
           @@ acceptable_op
                ~config
                ~round_durations
                ~round_zero_duration
                ~proposal_level
                ~proposal_round
                ~proposal_timestamp
                ~proposal_predecessor_level_start:grandparent_level_start
                ~op_level
                ~op_round
                ~now_timestamp)
          >>= function
          | Ok b -> Lwt.return b
          | _ -> Lwt.return_false))

(** A quasi infinite amount of "valid" (pre)endorsements could be
      sent by a committee member, one for each possible round number.

      This filter rejects (pre)endorsements that refer to a round
      that could not have been reached within the time span between
      the last head's timestamp and the current local clock.

      We add [config.clock_drift] time as a safety margin.
  *)
let pre_filter config ~(filter_state : state) ?validation_state_before
    ({shell = _; protocol_data = Operation_data {contents; _} as op} :
      Main.operation) =
  let prefilter_manager_op source manager_op =
    Lwt.return
    @@
    match
      pre_filter_manager
        config
        filter_state
        ~validation_state_before
        source
        op
        manager_op
    with
    | `Passed_prefilter prio -> `Passed_prefilter (manager_prio prio)
    | (`Branch_refused _ | `Branch_delayed _ | `Refused _ | `Outdated _) as err
      ->
        err
  in
  match contents with
  | Single (Failing_noop _) ->
      Lwt.return (`Refused [Environment.wrap_tzerror Wrong_operation])
  | Single (Preendorsement consensus_content)
  | Single (Endorsement consensus_content) ->
      pre_filter_far_future_consensus_ops
        ~filter_state
        config
        ?validation_state_before
        consensus_content
      >>= fun keep ->
      if keep then Lwt.return @@ `Passed_prefilter consensus_prio
      else
        Lwt.return
          (`Branch_refused
            [Environment.wrap_tzerror Consensus_operation_in_far_future])
  | Single (Dal_slot_availability _)
  | Single (Seed_nonce_revelation _)
  | Single (Double_preendorsement_evidence _)
  | Single (Double_endorsement_evidence _)
  | Single (Double_baking_evidence _)
  | Single (Activate_account _)
  | Single (Proposals _)
  | Single (Vdf_revelation _)
  | Single (Ballot _) ->
      Lwt.return @@ `Passed_prefilter other_prio
  | Single (Manager_operation {source; _}) as op ->
      prefilter_manager_op source op
  | Cons (Manager_operation {source; _}, _) as op ->
      prefilter_manager_op source op

let precheck_manager :
    type t.
    config ->
    state ->
    validation_state ->
    Operation_hash.t ->
    Tezos_base.Operation.shell_header ->
    t Kind.manager protocol_data ->
    nb_successful_prechecks:int ->
    fee:Tez.t ->
    gas_limit:Gas.Arith.fp ->
    public_key_hash ->
    [> `Prechecked_manager of
       [`No_replace | `Replace of Operation_hash.t * error_classification]
    | error_classification ]
    Lwt.t =
 fun config
     filter_state
     validation_state
     oph
     shell
     ({contents; _} as protocol_data : t Kind.manager protocol_data)
     ~nb_successful_prechecks
     ~fee
     ~gas_limit
     source ->
  let precheck_manager_and_check_signature ~on_success =
    let should_check_signature =
      if Compare.Int.(nb_successful_prechecks > 0) then
        (* Signature successfully checked at least once. *)
        Validate_operation.TMP_for_plugin.Skip_signature_check
      else
        (* Signature probably never checked. *)
        Validate_operation.TMP_for_plugin.Check_signature {shell; protocol_data}
    in
    Main.precheck_manager validation_state contents should_check_signature
    >|= function
    | Ok (_ : Validate_operation.stamp) -> on_success
    | Error err -> (
        let err = Environment.wrap_tztrace err in
        match classify_trace err with
        | Branch -> `Branch_refused err
        | Permanent -> `Refused err
        | Temporary -> `Branch_delayed err
        | Outdated -> `Outdated err)
  in
  let gas_limit = Gas.Arith.floor gas_limit in
  match
    check_manager_restriction config filter_state source ~fee ~gas_limit
  with
  | `Fail err -> Lwt.return err
  | `Replace old_oph ->
      let err =
        Environment.wrap_tzerror
        @@ Manager_operation_replaced {old_hash = old_oph; new_hash = oph}
      in
      precheck_manager_and_check_signature
        ~on_success:(`Prechecked_manager (`Replace (old_oph, `Outdated [err])))
  | `Fresh -> (
      match
        check_minimal_weight
          ~validation_state
          config
          filter_state
          ~fee
          ~gas_limit
          (Operation_data protocol_data)
      with
      | `Fail err -> Lwt.return err
      | `Weight_ok (replacement, _weight) ->
          let on_success =
            match replacement with
            | `No_replace -> `Prechecked_manager `No_replace
            | `Replace oph ->
                (* The operation with the lowest fees ratio, is reclassified as
                   branch_delayed. *)
                (* TODO: https://gitlab.com/tezos/tezos/-/issues/2347 The
                   branch_delayed ring is bounded to 1000, so we may loose
                   operations. We can probably do better. *)
                `Prechecked_manager
                  (`Replace
                    ( oph,
                      `Branch_delayed
                        [
                          Environment.wrap_tzerror
                            Removed_fees_too_low_for_mempool;
                        ] ))
          in
          precheck_manager_and_check_signature ~on_success)

let add_manager_restriction filter_state oph info source replacement =
  let filter_state =
    match replacement with
    | `No_replace -> filter_state
    | `Replace (oph, _class) -> remove ~filter_state oph
  in
  let prechecked_operations_count =
    if Operation_hash.Map.mem oph filter_state.operation_hash_to_manager then
      filter_state.prechecked_operations_count
    else filter_state.prechecked_operations_count + 1
  in
  let op_weight = op_weight_of_info info in
  let min_prechecked_op_weight =
    match filter_state.min_prechecked_op_weight with
    | Some mini when Q.(mini.weight < info.weight) -> Some mini
    | Some _ | None -> Some op_weight
  in
  {
    filter_state with
    op_prechecked_managers =
      (* Manager not seen yet, record it for next ops *)
      Signature.Public_key_hash.Map.add
        source
        info
        filter_state.op_prechecked_managers;
    operation_hash_to_manager =
      Operation_hash.Map.add oph source filter_state.operation_hash_to_manager
      (* Record which manager is used for the operation hash. *);
    ops_prechecked =
      ManagerOpWeightSet.add op_weight filter_state.ops_prechecked;
    prechecked_operations_count;
    min_prechecked_op_weight;
  }

let precheck :
    config ->
    filter_state:state ->
    validation_state:validation_state ->
    Operation_hash.t ->
    Main.operation ->
    nb_successful_prechecks:int ->
    [ `Passed_precheck of
      state
      * validation_state
      * [`No_replace | `Replace of Operation_hash.t * error_classification]
    | error_classification
    | `Undecided ]
    Lwt.t =
 fun config
     ~filter_state
     ~validation_state
     oph
     {shell = shell_header; protocol_data = Operation_data protocol_data}
     ~nb_successful_prechecks ->
  let precheck_manager protocol_data source op =
    match get_manager_operation_gas_and_fee op with
    | Error err -> Lwt.return (`Refused (Environment.wrap_tztrace err))
    | Ok (fee, gas_limit) -> (
        let weight =
          weight_manager_operation
            ~validation_state
            ~fee
            ~gas:gas_limit
            (Operation_data protocol_data)
        in
        let gas_limit = Gas.Arith.fp gas_limit in
        let info = {operation_hash = oph; gas_limit; fee; weight} in
        precheck_manager
          config
          filter_state
          validation_state
          oph
          shell_header
          protocol_data
          source
          ~nb_successful_prechecks
          ~fee
          ~gas_limit
        >|= function
        | `Prechecked_manager replacement ->
            let filter_state =
              add_manager_restriction filter_state oph info source replacement
            in
            `Passed_precheck (filter_state, validation_state, replacement)
        | (`Refused _ | `Branch_delayed _ | `Branch_refused _ | `Outdated _) as
          errs ->
            errs)
  in
  match protocol_data.contents with
  | Single (Manager_operation {source; _}) as op ->
      precheck_manager protocol_data source op
  | Cons (Manager_operation {source; _}, _) as op ->
      precheck_manager protocol_data source op
  | Single _ -> Lwt.return `Undecided

open Apply_results

type Environment.Error_monad.error += Skipped_operation

let () =
  Environment.Error_monad.register_error_kind
    `Temporary
    ~id:"postfilter.skipped_operation"
    ~title:"The operation has been skipped by the protocol"
    ~description:"The operation has been skipped by the protocol"
    ~pp:(fun ppf () ->
      Format.fprintf ppf "The operation has been skipped by the protocol")
    Data_encoding.unit
    (function Skipped_operation -> Some () | _ -> None)
    (fun () -> Skipped_operation)

type Environment.Error_monad.error += Backtracked_operation

let () =
  Environment.Error_monad.register_error_kind
    `Temporary
    ~id:"postfilter.backtracked_operation"
    ~title:"The operation has been backtracked by the protocol"
    ~description:"The operation has been backtracked by the protocol"
    ~pp:(fun ppf () ->
      Format.fprintf ppf "The operation has been backtracked by the protocol")
    Data_encoding.unit
    (function Backtracked_operation -> Some () | _ -> None)
    (fun () -> Backtracked_operation)

let rec post_filter_manager :
    type t.
    Alpha_context.t ->
    state ->
    t Kind.manager contents_result_list ->
    config ->
    [`Passed_postfilter of state | `Refused of tztrace] =
 fun ctxt filter_state result config ->
  (* TODO: https://gitlab.com/tezos/tezos/-/issues/2181
     This function should be unit tested.
     The errors that can be raised if allow_script_failure is enable should
     be tested. *)
  match result with
  | Single_result (Manager_operation_result {operation_result; _}) -> (
      let check_allow_script_failure errs =
        if config.allow_script_failure then `Passed_postfilter filter_state
        else `Refused errs
      in
      match operation_result with
      | Applied _ -> `Passed_postfilter filter_state
      | Skipped _ ->
          check_allow_script_failure
            [Environment.wrap_tzerror Skipped_operation]
      | Failed (_, errors) ->
          check_allow_script_failure (Environment.wrap_tztrace errors)
      | Backtracked (_, errors) ->
          check_allow_script_failure
            (match errors with
            | Some e -> Environment.wrap_tztrace e
            | None -> [Environment.wrap_tzerror Backtracked_operation]))
  | Cons_result (Manager_operation_result res, rest) -> (
      post_filter_manager
        ctxt
        filter_state
        (Single_result (Manager_operation_result res))
        config
      |> function
      | `Passed_postfilter filter_state ->
          post_filter_manager ctxt filter_state rest config
      | `Refused _ as errs -> errs)

let post_filter config ~(filter_state : state) ~validation_state_before:_
    ~validation_state_after:({ctxt; _} : validation_state) (_op, receipt) =
  match receipt with
  | No_operation_metadata -> assert false (* only for multipass validator *)
  | Operation_metadata {contents} -> (
      match contents with
      | Single_result (Preendorsement_result _)
      | Single_result (Endorsement_result _)
      | Single_result (Dal_slot_availability_result _)
      | Single_result (Seed_nonce_revelation_result _)
      | Single_result (Double_preendorsement_evidence_result _)
      | Single_result (Double_endorsement_evidence_result _)
      | Single_result (Double_baking_evidence_result _)
      | Single_result (Activate_account_result _)
      | Single_result Proposals_result
      | Single_result (Vdf_revelation_result _)
      | Single_result Ballot_result ->
          Lwt.return (`Passed_postfilter filter_state)
      | Single_result (Manager_operation_result _) as result ->
          Lwt.return (post_filter_manager ctxt filter_state result config)
      | Cons_result (Manager_operation_result _, _) as result ->
          Lwt.return (post_filter_manager ctxt filter_state result config))
