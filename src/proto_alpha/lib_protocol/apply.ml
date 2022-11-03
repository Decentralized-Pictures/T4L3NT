(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2019-2022 Nomadic Labs <contact@nomadic-labs.com>           *)
(* Copyright (c) 2022 Trili Tech, <contact@trili.tech>                       *)
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

(** Tezos Protocol Implementation - Main Entry Points *)

open Alpha_context

type error +=
  | Not_enough_endorsements of {required : int; provided : int}
  | Faulty_validation_wrong_slot
  | Set_deposits_limit_on_unregistered_delegate of Signature.Public_key_hash.t
  | Set_deposits_limit_too_high of {limit : Tez.t; max_limit : Tez.t}
  | Error_while_taking_fees
  | Update_consensus_key_on_unregistered_delegate of Signature.Public_key_hash.t
  | Empty_transaction of Contract.t
  | Tx_rollup_feature_disabled
  | Tx_rollup_invalid_transaction_ticket_amount
  | Cannot_transfer_ticket_to_implicit
  | Sc_rollup_feature_disabled
  | Internal_operation_replay of
      Apply_internal_results.packed_internal_operation
  | Multiple_revelation
  | Zero_frozen_deposits of Signature.Public_key_hash.t
  | Invalid_transfer_to_sc_rollup_from_implicit_account

let () =
  register_error_kind
    `Permanent
    ~id:"operation.not_enough_endorsements"
    ~title:"Not enough endorsements"
    ~description:
      "The block being validated does not include the required minimum number \
       of endorsements."
    ~pp:(fun ppf (required, provided) ->
      Format.fprintf
        ppf
        "Wrong number of endorsements (%i), at least %i are expected"
        provided
        required)
    Data_encoding.(obj2 (req "required" int31) (req "provided" int31))
    (function
      | Not_enough_endorsements {required; provided} -> Some (required, provided)
      | _ -> None)
    (fun (required, provided) -> Not_enough_endorsements {required; provided}) ;
  let description =
    "The consensus operation uses an invalid slot. This error should not \
     happen: the operation validation should have failed earlier."
  in
  register_error_kind
    `Permanent
    ~id:"operation.faulty_validation_wrong_slot"
    ~title:"Faulty validation (wrong slot for consensus operation)"
    ~description
    ~pp:(fun ppf () -> Format.fprintf ppf "%s" description)
    Data_encoding.empty
    (function Faulty_validation_wrong_slot -> Some () | _ -> None)
    (fun () -> Faulty_validation_wrong_slot) ;
  register_error_kind
    `Temporary
    ~id:"operation.set_deposits_limit_on_unregistered_delegate"
    ~title:"Set deposits limit on an unregistered delegate"
    ~description:"Cannot set deposits limit on an unregistered delegate."
    ~pp:(fun ppf c ->
      Format.fprintf
        ppf
        "Cannot set a deposits limit on the unregistered delegate %a."
        Signature.Public_key_hash.pp
        c)
    Data_encoding.(obj1 (req "delegate" Signature.Public_key_hash.encoding))
    (function
      | Set_deposits_limit_on_unregistered_delegate c -> Some c | _ -> None)
    (fun c -> Set_deposits_limit_on_unregistered_delegate c) ;
  register_error_kind
    `Permanent
    ~id:"operation.set_deposits_limit_too_high"
    ~title:"Set deposits limit to a too high value"
    ~description:
      "Cannot set deposits limit such that the active stake overflows."
    ~pp:(fun ppf (limit, max_limit) ->
      Format.fprintf
        ppf
        "Cannot set deposits limit to %a as it is higher the allowed maximum \
         %a."
        Tez.pp
        limit
        Tez.pp
        max_limit)
    Data_encoding.(
      obj2 (req "limit" Tez.encoding) (req "max_limit" Tez.encoding))
    (function
      | Set_deposits_limit_too_high {limit; max_limit} -> Some (limit, max_limit)
      | _ -> None)
    (fun (limit, max_limit) -> Set_deposits_limit_too_high {limit; max_limit}) ;

  let error_while_taking_fees_description =
    "There was an error while taking the fees, which should not happen and \
     means that the operation's validation was faulty."
  in
  register_error_kind
    `Permanent
    ~id:"operation.error_while_taking_fees"
    ~title:"Error while taking the fees of a manager operation"
    ~description:error_while_taking_fees_description
    ~pp:(fun ppf () ->
      Format.fprintf ppf "%s" error_while_taking_fees_description)
    Data_encoding.unit
    (function Error_while_taking_fees -> Some () | _ -> None)
    (fun () -> Error_while_taking_fees) ;

  register_error_kind
    `Temporary
    ~id:"operation.update_consensus_key_on_unregistered_delegate"
    ~title:"Update consensus key on an unregistered delegate"
    ~description:"Cannot update consensus key an unregistered delegate."
    ~pp:(fun ppf c ->
      Format.fprintf
        ppf
        "Cannot update the consensus key on the unregistered delegate %a."
        Signature.Public_key_hash.pp
        c)
    Data_encoding.(obj1 (req "delegate" Signature.Public_key_hash.encoding))
    (function
      | Update_consensus_key_on_unregistered_delegate c -> Some c | _ -> None)
    (fun c -> Update_consensus_key_on_unregistered_delegate c) ;
  register_error_kind
    `Branch
    ~id:"contract.empty_transaction"
    ~title:"Empty transaction"
    ~description:"Forbidden to credit 0ꜩ to a contract without code."
    ~pp:(fun ppf contract ->
      Format.fprintf
        ppf
        "Transactions of 0ꜩ towards a contract without code are forbidden (%a)."
        Contract.pp
        contract)
    Data_encoding.(obj1 (req "contract" Contract.encoding))
    (function Empty_transaction c -> Some c | _ -> None)
    (fun c -> Empty_transaction c) ;

  register_error_kind
    `Permanent
    ~id:"operation.tx_rollup_is_disabled"
    ~title:"Tx rollup is disabled"
    ~description:"Cannot originate a tx rollup as it is disabled."
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Cannot apply a tx rollup operation as it is disabled. This feature \
         will be enabled in a future proposal")
    Data_encoding.unit
    (function Tx_rollup_feature_disabled -> Some () | _ -> None)
    (fun () -> Tx_rollup_feature_disabled) ;

  register_error_kind
    `Permanent
    ~id:"operation.tx_rollup_invalid_transaction_ticket_amount"
    ~title:"Amount of transferred ticket is too high"
    ~description:
      "The ticket amount of a rollup transaction must fit in a signed 64-bit \
       integer."
    ~pp:(fun ppf () ->
      Format.fprintf ppf "Amount of transferred ticket is too high.")
    Data_encoding.unit
    (function
      | Tx_rollup_invalid_transaction_ticket_amount -> Some () | _ -> None)
    (fun () -> Tx_rollup_invalid_transaction_ticket_amount) ;

  register_error_kind
    `Permanent
    ~id:"operation.cannot_transfer_ticket_to_implicit"
    ~title:"Cannot transfer ticket to implicit account"
    ~description:"Cannot transfer ticket to implicit account"
    Data_encoding.unit
    (function Cannot_transfer_ticket_to_implicit -> Some () | _ -> None)
    (fun () -> Cannot_transfer_ticket_to_implicit) ;

  let description =
    "Smart contract rollups will be enabled in a future proposal."
  in
  register_error_kind
    `Permanent
    ~id:"operation.sc_rollup_disabled"
    ~title:"Smart contract rollups are disabled"
    ~description
    ~pp:(fun ppf () -> Format.fprintf ppf "%s" description)
    Data_encoding.unit
    (function Sc_rollup_feature_disabled -> Some () | _ -> None)
    (fun () -> Sc_rollup_feature_disabled) ;

  register_error_kind
    `Permanent
    ~id:"internal_operation_replay"
    ~title:"Internal operation replay"
    ~description:"An internal operation was emitted twice by a script"
    ~pp:(fun ppf (Apply_internal_results.Internal_operation {nonce; _}) ->
      Format.fprintf
        ppf
        "Internal operation %d was emitted twice by a script"
        nonce)
    Apply_internal_results.internal_operation_encoding
    (function Internal_operation_replay op -> Some op | _ -> None)
    (fun op -> Internal_operation_replay op) ;
  register_error_kind
    `Permanent
    ~id:"block.multiple_revelation"
    ~title:"Multiple revelations were included in a manager operation"
    ~description:
      "A manager operation should not contain more than one revelation"
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Multiple revelations were included in a manager operation")
    Data_encoding.empty
    (function Multiple_revelation -> Some () | _ -> None)
    (fun () -> Multiple_revelation) ;
  register_error_kind
    `Permanent
    ~id:"delegate.zero_frozen_deposits"
    ~title:"Zero frozen deposits"
    ~description:"The delegate has zero frozen deposits."
    ~pp:(fun ppf delegate ->
      Format.fprintf
        ppf
        "Delegate %a has zero frozen deposits; it is not allowed to \
         bake/preendorse/endorse."
        Signature.Public_key_hash.pp
        delegate)
    Data_encoding.(obj1 (req "delegate" Signature.Public_key_hash.encoding))
    (function Zero_frozen_deposits delegate -> Some delegate | _ -> None)
    (fun delegate -> Zero_frozen_deposits delegate) ;
  register_error_kind
    `Permanent
    ~id:"operations.invalid_transfer_to_sc_rollup_from_implicit_account"
    ~title:"Invalid transfer to sc rollup"
    ~description:"Invalid transfer to sc rollup from implicit account"
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Invalid source for transfer operation to smart-contract rollup. Only \
         originated accounts are allowed")
    Data_encoding.empty
    (function
      | Invalid_transfer_to_sc_rollup_from_implicit_account -> Some ()
      | _ -> None)
    (fun () -> Invalid_transfer_to_sc_rollup_from_implicit_account)

open Apply_results
open Apply_operation_result
open Apply_internal_results

let assert_tx_rollup_feature_enabled ctxt =
  let open Result_syntax in
  let level = (Level.current ctxt).level in
  let* sunset = Raw_level.of_int32 @@ Constants.tx_rollup_sunset_level ctxt in
  let* () = error_when Raw_level.(sunset <= level) Tx_rollup_feature_disabled in
  error_unless (Constants.tx_rollup_enable ctxt) Tx_rollup_feature_disabled

let assert_sc_rollup_feature_enabled ctxt =
  error_unless (Constants.sc_rollup_enable ctxt) Sc_rollup_feature_disabled

let update_script_storage_and_ticket_balances ctxt ~self_contract storage
    lazy_storage_diff ticket_diffs operations =
  Contract.update_script_storage ctxt self_contract storage lazy_storage_diff
  >>=? fun ctxt ->
  Ticket_accounting.update_ticket_balances
    ctxt
    ~self_contract
    ~ticket_diffs
    operations

let apply_delegation ~ctxt ~source ~delegate ~before_operation =
  Contract.Delegate.set ctxt source delegate >|=? fun ctxt ->
  (ctxt, Gas.consumed ~since:before_operation ~until:ctxt, [])

type 'loc execution_arg =
  | Typed_arg : 'loc * ('a, _) Script_typed_ir.ty * 'a -> 'loc execution_arg
  | Untyped_arg : Script.expr -> _ execution_arg

let apply_transaction_to_implicit ~ctxt ~source ~amount ~pkh ~before_operation =
  let contract = Contract.Implicit pkh in
  (* Transfers of zero to implicit accounts are forbidden. *)
  error_when Tez.(amount = zero) (Empty_transaction contract) >>?= fun () ->
  (* If the implicit contract is not yet allocated at this point then
     the next transfer of tokens will allocate it. *)
  Contract.allocated ctxt contract >>= fun already_allocated ->
  Token.transfer ctxt (`Contract source) (`Contract contract) amount
  >>=? fun (ctxt, balance_updates) ->
  let result =
    Transaction_to_contract_result
      {
        storage = None;
        lazy_storage_diff = None;
        balance_updates;
        ticket_receipt = [];
        originated_contracts = [];
        consumed_gas = Gas.consumed ~since:before_operation ~until:ctxt;
        storage_size = Z.zero;
        paid_storage_size_diff = Z.zero;
        allocated_destination_contract = not already_allocated;
      }
  in
  return (ctxt, result, [])

let apply_transaction_to_smart_contract ~ctxt ~source ~contract_hash ~amount
    ~entrypoint ~before_operation ~payer ~chain_id ~internal ~parameter =
  let contract = Contract.Originated contract_hash in
  (* Since the contract is originated, nothing will be allocated or this
     transfer of tokens will fail.  [Token.transfer] will succeed even on
     non-existing contracts, if the amount is zero.  Then if the destination
     does not exist, [Script_cache.find] will signal that by returning [None]
     and we'll fail.
  *)
  Token.transfer ctxt (`Contract source) (`Contract contract) amount
  >>=? fun (ctxt, balance_updates) ->
  Script_cache.find ctxt contract_hash >>=? fun (ctxt, cache_key, script) ->
  match script with
  | None -> fail (Contract.Non_existing_contract contract)
  | Some (script, script_ir) ->
      (* Token.transfer which is being called before already loads this value into
         the Irmin cache, so no need to burn gas for it. *)
      Contract.get_balance ctxt contract >>=? fun balance ->
      let now = Script_timestamp.now ctxt in
      let level =
        (Level.current ctxt).level |> Raw_level.to_int32 |> Script_int.of_int32
        |> Script_int.abs
      in
      let step_constants =
        let open Script_interpreter in
        {
          source;
          payer;
          self = contract_hash;
          amount;
          chain_id;
          balance;
          now;
          level;
        }
      in
      let execute =
        match parameter with
        | Untyped_arg parameter -> Script_interpreter.execute ~parameter
        | Typed_arg (location, parameter_ty, parameter) ->
            Script_interpreter.execute_with_typed_parameter
              ~location
              ~parameter_ty
              ~parameter
      in
      let cached_script = Some script_ir in
      execute
        ctxt
        ~cached_script
        Optimized
        step_constants
        ~script
        ~entrypoint
        ~internal
      >>=? fun ( {
                   script = updated_cached_script;
                   code_size = updated_size;
                   storage;
                   lazy_storage_diff;
                   operations;
                   ticket_diffs;
                   ticket_receipt;
                 },
                 ctxt ) ->
      update_script_storage_and_ticket_balances
        ctxt
        ~self_contract:contract
        storage
        lazy_storage_diff
        ticket_diffs
        operations
      >>=? fun (ticket_table_size_diff, ctxt) ->
      Ticket_balance.adjust_storage_space
        ctxt
        ~storage_diff:ticket_table_size_diff
      >>=? fun (ticket_paid_storage_diff, ctxt) ->
      Fees.record_paid_storage_space ctxt contract
      >>=? fun (ctxt, new_size, contract_paid_storage_size_diff) ->
      Contract.originated_from_current_nonce ~since:before_operation ~until:ctxt
      >>=? fun originated_contracts ->
      Lwt.return
        ( Script_cache.update
            ctxt
            cache_key
            ( {script with storage = Script.lazy_expr storage},
              updated_cached_script )
            updated_size
        >|? fun ctxt ->
          let result =
            Transaction_to_contract_result
              {
                storage = Some storage;
                lazy_storage_diff;
                balance_updates;
                ticket_receipt;
                originated_contracts;
                consumed_gas = Gas.consumed ~since:before_operation ~until:ctxt;
                storage_size = new_size;
                paid_storage_size_diff =
                  Z.add contract_paid_storage_size_diff ticket_paid_storage_diff;
                allocated_destination_contract = false;
              }
          in
          (ctxt, result, operations) )

let apply_transaction_to_tx_rollup ~ctxt ~parameters_ty ~parameters ~payer
    ~dst_rollup ~since =
  assert_tx_rollup_feature_enabled ctxt >>?= fun () ->
  (* If the ticket deposit fails on L2 for some reason
     (e.g. [Balance_overflow] in the recipient), then it is
     returned to [payer]. As [payer] is implicit, it cannot own
     tickets directly. Therefore, erroneous deposits are
     returned using the L2 withdrawal mechanism: a failing
     deposit emits a withdrawal that can be executed by
     [payer]. *)
  let Tx_rollup_parameters.{ex_ticket; l2_destination} =
    Tx_rollup_parameters.get_deposit_parameters parameters_ty parameters
  in
  Ticket_scanner.ex_ticket_size ctxt ex_ticket >>=? fun (ticket_size, ctxt) ->
  let limit = Constants.tx_rollup_max_ticket_payload_size ctxt in
  fail_when
    Saturation_repr.(ticket_size >! limit)
    (Tx_rollup_errors_repr.Ticket_payload_size_limit_exceeded
       {payload_size = ticket_size; limit})
  >>=? fun () ->
  let ex_token, ticket_amount =
    Ticket_token.token_and_amount_of_ex_ticket ex_ticket
  in
  Ticket_balance_key.of_ex_token ctxt ~owner:(Tx_rollup dst_rollup) ex_token
  >>=? fun (ticket_hash, ctxt) ->
  Option.value_e
    ~error:
      (Error_monad.trace_of_error Tx_rollup_invalid_transaction_ticket_amount)
    (Option.bind
       (Script_int.to_int64 (ticket_amount :> Script_int.n Script_int.num))
       Tx_rollup_l2_qty.of_int64)
  >>?= fun ticket_amount ->
  error_when
    Tx_rollup_l2_qty.(ticket_amount <= zero)
    Script_tc_errors.Forbidden_zero_ticket_quantity
  >>?= fun () ->
  let deposit, message_size =
    Tx_rollup_message.make_deposit
      payer
      l2_destination
      ticket_hash
      ticket_amount
  in
  Tx_rollup_state.get ctxt dst_rollup >>=? fun (ctxt, state) ->
  Tx_rollup_state.burn_cost ~limit:None state message_size >>?= fun cost ->
  Token.transfer ctxt (`Contract (Contract.Implicit payer)) `Burned cost
  >>=? fun (ctxt, balance_updates) ->
  Tx_rollup_inbox.append_message ctxt dst_rollup state deposit
  >>=? fun (ctxt, state, paid_storage_size_diff) ->
  Tx_rollup_state.update ctxt dst_rollup state >>=? fun ctxt ->
  let result =
    ITransaction_result
      (Transaction_to_tx_rollup_result
         {
           balance_updates;
           consumed_gas = Gas.consumed ~since ~until:ctxt;
           ticket_hash;
           paid_storage_size_diff;
         })
  in
  return (ctxt, result, [])

let apply_origination ~ctxt ~storage_type ~storage ~unparsed_code
    ~contract:contract_hash ~delegate ~source ~credit ~before_operation =
  Script_ir_translator.collect_lazy_storage ctxt storage_type storage
  >>?= fun (to_duplicate, ctxt) ->
  let to_update = Script_ir_translator.no_lazy_storage_id in
  Script_ir_translator.extract_lazy_storage_diff
    ctxt
    Optimized
    storage_type
    storage
    ~to_duplicate
    ~to_update
    ~temporary:false
  >>=? fun (storage, lazy_storage_diff, ctxt) ->
  Script_ir_translator.unparse_data ctxt Optimized storage_type storage
  >>=? fun (storage, ctxt) ->
  let storage = Script.lazy_expr storage in
  (* Normalize code to avoid #843 *)
  Script_ir_translator.unparse_code
    ctxt
    Optimized
    (Micheline.root unparsed_code)
  >>=? fun (code, ctxt) ->
  let code = Script.lazy_expr code in
  let script = {Script.code; storage} in
  Contract.raw_originate
    ctxt
    ~prepaid_bootstrap_storage:false
    contract_hash
    ~script:(script, lazy_storage_diff)
  >>=? fun ctxt ->
  let contract = Contract.Originated contract_hash in
  (match delegate with
  | None -> return ctxt
  | Some delegate -> Contract.Delegate.init ctxt contract delegate)
  >>=? fun ctxt ->
  Token.transfer ctxt (`Contract source) (`Contract contract) credit
  >>=? fun (ctxt, balance_updates) ->
  Fees.record_paid_storage_space ctxt contract
  >|=? fun (ctxt, size, paid_storage_size_diff) ->
  let result =
    {
      lazy_storage_diff;
      balance_updates;
      originated_contracts = [contract_hash];
      consumed_gas = Gas.consumed ~since:before_operation ~until:ctxt;
      storage_size = size;
      paid_storage_size_diff;
    }
  in
  (ctxt, result, [])

(**

   Retrieving the source code of a contract from its address is costly
   because it requires I/Os. For this reason, we put the corresponding
   Micheline expression in the cache.

   Elaborating a Micheline node into the well-typed script abstract
   syntax tree is also a costly operation. The result of this operation
   is cached as well.

*)

let apply_internal_operation_contents :
    type kind.
    context ->
    payer:public_key_hash ->
    source:Contract.t ->
    chain_id:Chain_id.t ->
    kind Script_typed_ir.internal_operation_contents ->
    (context
    * kind successful_internal_operation_result
    * Script_typed_ir.packed_internal_operation list)
    tzresult
    Lwt.t =
 fun ctxt_before_op ~payer ~source ~chain_id operation ->
  Contract.must_exist ctxt_before_op source >>=? fun () ->
  Gas.consume ctxt_before_op Michelson_v1_gas.Cost_of.manager_operation
  >>?= fun ctxt ->
  (* Note that [ctxt_before_op] will be used again later to compute
     gas consumption and originations for the operation result (by
     comparing it with the [ctxt] we will have at the end of the
     application). *)
  match operation with
  | Transaction_to_implicit {destination = pkh; amount} ->
      apply_transaction_to_implicit
        ~ctxt
        ~source
        ~amount
        ~pkh
        ~before_operation:ctxt_before_op
      >|=? fun (ctxt, res, ops) ->
      ( ctxt,
        (ITransaction_result res : kind successful_internal_operation_result),
        ops )
  | Transaction_to_smart_contract
      {
        amount;
        destination = contract_hash;
        entrypoint;
        location;
        parameters_ty;
        parameters = typed_parameters;
        unparsed_parameters = _;
      } ->
      apply_transaction_to_smart_contract
        ~ctxt
        ~source
        ~contract_hash
        ~amount
        ~entrypoint
        ~before_operation:ctxt_before_op
        ~payer
        ~chain_id
        ~internal:true
        ~parameter:(Typed_arg (location, parameters_ty, typed_parameters))
      >|=? fun (ctxt, res, ops) -> (ctxt, ITransaction_result res, ops)
  | Transaction_to_tx_rollup
      {destination; unparsed_parameters = _; parameters_ty; parameters} ->
      apply_transaction_to_tx_rollup
        ~ctxt
        ~parameters_ty
        ~parameters
        ~payer
        ~dst_rollup:destination
        ~since:ctxt_before_op
  | Transaction_to_sc_rollup
      {
        destination;
        entrypoint = _;
        parameters_ty = _;
        parameters = _;
        unparsed_parameters = payload;
      } ->
      assert_sc_rollup_feature_enabled ctxt >>?= fun () ->
      (* TODO: #3242
         We could rather change the type of [source] in
         {!Script_type_ir.internal_operation}. Only originated accounts should
         be allowed anyway for internal operations.
      *)
      (match source with
      | Contract.Implicit _ ->
          error Invalid_transfer_to_sc_rollup_from_implicit_account
      | Originated hash -> ok hash)
      >>?= fun sender ->
      (* Adding the message to the inbox. Note that it is safe to ignore the
         size diff since only its hash and meta data are stored in the context.
         See #3232. *)
      Sc_rollup.Inbox.add_internal_message
        ctxt
        destination
        ~payload
        ~sender
        ~source:payer
      >|=? fun (inbox_after, _size, ctxt) ->
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result =
        Transaction_to_sc_rollup_result {consumed_gas; inbox_after}
      in
      (ctxt, ITransaction_result result, [])
  | Event {ty = _; unparsed_data = _; tag = _} ->
      return
        ( ctxt,
          IEvent_result
            {consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt},
          [] )
  | Transaction_to_zk_rollup
      {destination; unparsed_parameters = _; parameters_ty; parameters} ->
      Zk_rollup_apply.transaction_to_zk_rollup
        ~ctxt
        ~parameters_ty
        ~parameters
        ~dst_rollup:destination
        ~since:ctxt_before_op
  | Origination
      {
        delegate;
        code = unparsed_code;
        unparsed_storage = _;
        credit;
        preorigination;
        storage_type;
        storage;
      } ->
      apply_origination
        ~ctxt
        ~storage_type
        ~storage
        ~unparsed_code
        ~contract:preorigination
        ~delegate
        ~source
        ~credit
        ~before_operation:ctxt_before_op
      >|=? fun (ctxt, origination_result, ops) ->
      (ctxt, IOrigination_result origination_result, ops)
  | Delegation delegate ->
      apply_delegation ~ctxt ~source ~delegate ~before_operation:ctxt_before_op
      >|=? fun (ctxt, consumed_gas, ops) ->
      (ctxt, IDelegation_result {consumed_gas}, ops)

let apply_manager_operation :
    type kind.
    context ->
    source:public_key_hash ->
    chain_id:Chain_id.t ->
    kind manager_operation ->
    (context
    * kind successful_manager_operation_result
    * Script_typed_ir.packed_internal_operation list)
    tzresult
    Lwt.t =
 fun ctxt_before_op ~source ~chain_id operation ->
  let source_contract = Contract.Implicit source in
  Contract.must_exist ctxt_before_op source_contract >>=? fun () ->
  Gas.consume ctxt_before_op Michelson_v1_gas.Cost_of.manager_operation
  >>?= fun ctxt ->
  (* Note that [ctxt_before_op] will be used again later to compute
     gas consumption and originations for the operation result (by
     comparing it with the [ctxt] we will have at the end of the
     application). *)
  let consume_deserialization_gas =
    (* Note that we used to set this to [Script.When_needed] because
       the deserialization gas was accounted for in the gas consumed
       by precheck. However, we no longer have access to this precheck
       gas, so we want to always consume the deserialization gas
       again, independently of the internal state of the lazy_exprs in
       the arguments. *)
    Script.Always
  in
  match operation with
  | Reveal pk ->
      (* TODO #2603

         Even if [precheck_manager_contents] has already asserted that
         the implicit contract is allocated, we must re-do this check in
         case the manager has been emptied while collecting fees. This
         should be solved by forking out [validate_operation] from
         [apply_operation]. *)
      Contract.must_be_allocated ctxt source_contract >>=? fun () ->
      (* TODO tezos/tezos#3070

         We have already asserted the consistency of the supplied public
         key during precheck, so we avoid re-checking that precondition
         with [?check_consistency=false]. This optional parameter is
         temporary, to avoid breaking compatibility with external legacy
         usage of [Contract.reveal_manager_key]. However, the pattern of
         using [Contract.check_public_key] and this usage of
         [Contract.reveal_manager_key] should become the standard. *)
      Contract.reveal_manager_key ~check_consistency:false ctxt source pk
      >>=? fun ctxt ->
      return
        ( ctxt,
          (Reveal_result
             {consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt}
            : kind successful_manager_operation_result),
          [] )
  | Transaction {amount; parameters; destination = Implicit pkh; entrypoint} ->
      Script.force_decode_in_context
        ~consume_deserialization_gas
        ctxt
        parameters
      >>?= fun (parameters, ctxt) ->
      (* Only allow [Unit] parameter to implicit accounts. *)
      (match Micheline.root parameters with
      | Prim (_, Michelson_v1_primitives.D_Unit, [], _) -> Result.return_unit
      | _ -> error (Script_interpreter.Bad_contract_parameter source_contract))
      >>?= fun () ->
      (if Entrypoint.is_default entrypoint then Result.return_unit
      else error (Script_tc_errors.No_such_entrypoint entrypoint))
      >>?= fun () ->
      apply_transaction_to_implicit
        ~ctxt
        ~source:source_contract
        ~amount
        ~pkh
        ~before_operation:ctxt_before_op
      >|=? fun (ctxt, res, ops) -> (ctxt, Transaction_result res, ops)
  | Transaction
      {amount; parameters; destination = Originated contract_hash; entrypoint}
    ->
      Script.force_decode_in_context
        ~consume_deserialization_gas
        ctxt
        parameters
      >>?= fun (parameters, ctxt) ->
      apply_transaction_to_smart_contract
        ~ctxt
        ~source:source_contract
        ~contract_hash
        ~amount
        ~entrypoint
        ~before_operation:ctxt_before_op
        ~payer:source
        ~chain_id
        ~internal:false
        ~parameter:(Untyped_arg parameters)
      >|=? fun (ctxt, res, ops) -> (ctxt, Transaction_result res, ops)
  | Tx_rollup_dispatch_tickets
      {
        tx_rollup;
        level;
        context_hash;
        message_index;
        message_result_path;
        tickets_info;
      } ->
      Tx_rollup_state.get ctxt tx_rollup >>=? fun (ctxt, state) ->
      Tx_rollup_commitment.get_finalized ctxt tx_rollup state level
      >>=? fun (ctxt, commitment) ->
      Tx_rollup_reveal.mem ctxt tx_rollup level ~message_position:message_index
      >>=? fun (ctxt, already_revealed) ->
      error_when
        already_revealed
        Tx_rollup_errors.Withdrawals_already_dispatched
      >>?= fun () ->
      (* The size of the list [tickets_info] is bounded by a
         parametric constant, and checked in precheck. *)
      List.fold_left_es
        (fun (acc_withdraw, acc, ctxt)
             Tx_rollup_reveal.{contents; ty; ticketer; amount; claimer} ->
          error_when
            Tx_rollup_l2_qty.(amount <= zero)
            Script_tc_errors.Forbidden_zero_ticket_quantity
          >>?= fun () ->
          Tx_rollup_ticket.parse_ticket
            ~consume_deserialization_gas
            ~ticketer
            ~contents
            ~ty
            ctxt
          >>=? fun (ctxt, ticket_token) ->
          Tx_rollup_ticket.make_withdraw_order
            ctxt
            tx_rollup
            ticket_token
            claimer
            amount
          >>=? fun (ctxt, withdrawal) ->
          return
            (withdrawal :: acc_withdraw, (withdrawal, ticket_token) :: acc, ctxt))
        ([], [], ctxt)
        tickets_info
      >>=? fun (rev_withdraw_list, rev_ex_token_and_hash_list, ctxt) ->
      Tx_rollup_hash.withdraw_list ctxt (List.rev rev_withdraw_list)
      >>?= fun (ctxt, withdraw_list_hash) ->
      Tx_rollup_commitment.check_message_result
        ctxt
        commitment.commitment
        (`Result {context_hash; withdraw_list_hash})
        ~path:message_result_path
        ~index:message_index
      >>?= fun ctxt ->
      Tx_rollup_reveal.record
        ctxt
        tx_rollup
        level
        ~message_position:message_index
      >>=? fun ctxt ->
      let adjust_ticket_balance (ctxt, acc_diff)
          ( Tx_rollup_withdraw.
              {claimer; amount; ticket_hash = tx_rollup_ticket_hash},
            ticket_token ) =
        Tx_rollup_l2_qty.to_z amount
        |> Ticket_amount.of_zint
        |> Option.value_e
             ~error:
               (Error_monad.trace_of_error
                  Script_tc_errors.Forbidden_zero_ticket_quantity)
        >>?= fun amount ->
        Ticket_balance_key.of_ex_token
          ctxt
          ~owner:(Contract (Contract.Implicit claimer))
          ticket_token
        >>=? fun (claimer_ticket_hash, ctxt) ->
        Tx_rollup_ticket.transfer_ticket_with_hashes
          ctxt
          ~src_hash:tx_rollup_ticket_hash
          ~dst_hash:claimer_ticket_hash
          amount
        >>=? fun (ctxt, diff) -> return (ctxt, Z.(add acc_diff diff))
      in
      List.fold_left_es
        adjust_ticket_balance
        (ctxt, Z.zero)
        rev_ex_token_and_hash_list
      >>=? fun (ctxt, paid_storage_size_diff) ->
      let result =
        Tx_rollup_dispatch_tickets_result
          {
            balance_updates = [];
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
            paid_storage_size_diff;
          }
      in
      return (ctxt, result, [])
  | Transfer_ticket {contents; ty; ticketer; amount; destination; entrypoint}
    -> (
      match destination with
      | Implicit _ -> fail Cannot_transfer_ticket_to_implicit
      | Originated destination_hash ->
          Tx_rollup_ticket.parse_ticket_and_operation
            ~consume_deserialization_gas
            ~ticketer
            ~contents
            ~ty
            ~source:source_contract
            ~destination:destination_hash
            ~entrypoint
            ~amount
            ctxt
          >>=? fun (ctxt, ticket_token, op) ->
          Tx_rollup_ticket.transfer_ticket
            ctxt
            ~src:(Contract source_contract)
            ~dst:(Contract destination)
            ticket_token
            amount
          >>=? fun (ctxt, paid_storage_size_diff) ->
          let result =
            Transfer_ticket_result
              {
                balance_updates = [];
                consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
                paid_storage_size_diff;
              }
          in
          return (ctxt, result, [op]))
  | Origination {delegate; script; credit} ->
      (* Internal originations have their address generated in the interpreter
         so that the script can use it immediately.
         The address of external originations is generated here. *)
      Contract.fresh_contract_from_current_nonce ctxt
      >>?= fun (ctxt, contract) ->
      Script.force_decode_in_context
        ~consume_deserialization_gas
        ctxt
        script.Script.storage
      >>?= fun (_unparsed_storage, ctxt) ->
      Script.force_decode_in_context
        ~consume_deserialization_gas
        ctxt
        script.Script.code
      >>?= fun (unparsed_code, ctxt) ->
      Script_ir_translator.parse_script
        ctxt
        ~elab_conf:Script_ir_translator_config.(make ~legacy:false ())
        ~allow_forged_in_storage:false
        script
      >>=? fun (Ex_script parsed_script, ctxt) ->
      let (Script {storage_type; views; storage; _}) = parsed_script in
      let views_result =
        Script_ir_translator.parse_views
          ctxt
          ~elab_conf:Script_ir_translator_config.(make ~legacy:false ())
          storage_type
          views
      in
      trace
        (Script_tc_errors.Ill_typed_contract (unparsed_code, []))
        views_result
      >>=? fun (_typed_views, ctxt) ->
      apply_origination
        ~ctxt
        ~storage_type
        ~storage
        ~unparsed_code
        ~contract
        ~delegate
        ~source:source_contract
        ~credit
        ~before_operation:ctxt_before_op
      >|=? fun (ctxt, origination_result, ops) ->
      (ctxt, Origination_result origination_result, ops)
  | Delegation delegate ->
      apply_delegation
        ~ctxt
        ~source:source_contract
        ~delegate
        ~before_operation:ctxt_before_op
      >|=? fun (ctxt, consumed_gas, ops) ->
      (ctxt, Delegation_result {consumed_gas}, ops)
  | Register_global_constant {value} ->
      (* Decode the value and consume gas appropriately *)
      Script.force_decode_in_context ~consume_deserialization_gas ctxt value
      >>?= fun (expr, ctxt) ->
      (* Set the key to the value in storage. *)
      Global_constants_storage.register ctxt expr
      >>=? fun (ctxt, address, size) ->
      (* The burn and the reporting of the burn are calculated differently.

         [Fees.record_global_constant_storage_space] does the actual burn
         based on the size of the constant registered, and this causes a
         change in account balance.

         On the other hand, the receipt is calculated
         with the help of [Fees.cost_of_bytes], and is included in block metadata
         and the client output. The receipt is also used during simulation,
         letting the client automatically set an appropriate storage limit.
         TODO : is this concern still honored by the token management
         refactoring ? *)
      let ctxt, paid_size =
        Fees.record_global_constant_storage_space ctxt size
      in
      let result =
        Register_global_constant_result
          {
            balance_updates = [];
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
            size_of_constant = paid_size;
            global_address = address;
          }
      in
      return (ctxt, result, [])
  | Set_deposits_limit limit ->
      (match limit with
      | None -> Result.return_unit
      | Some limit ->
          let frozen_deposits_percentage =
            Constants.frozen_deposits_percentage ctxt
          in
          let max_limit =
            Tez.of_mutez_exn
              Int64.(
                mul (of_int frozen_deposits_percentage) Int64.(div max_int 100L))
          in
          error_when
            Tez.(limit > max_limit)
            (Set_deposits_limit_too_high {limit; max_limit}))
      >>?= fun () ->
      Delegate.registered ctxt source >>= fun is_registered ->
      error_unless
        is_registered
        (Set_deposits_limit_on_unregistered_delegate source)
      >>?= fun () ->
      Delegate.set_frozen_deposits_limit ctxt source limit >>= fun ctxt ->
      return
        ( ctxt,
          Set_deposits_limit_result
            {consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt},
          [] )
  | Increase_paid_storage {amount_in_bytes; destination} ->
      let contract = Contract.Originated destination in
      Contract.increase_paid_storage ctxt contract ~amount_in_bytes
      >>=? fun ctxt ->
      let payer = `Contract (Contract.Implicit source) in
      Fees.burn_storage_increase_fees ctxt ~payer amount_in_bytes
      >|=? fun (ctxt, storage_bus) ->
      let result =
        Increase_paid_storage_result
          {
            balance_updates = storage_bus;
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
          }
      in
      (ctxt, result, [])
  | Update_consensus_key pk ->
      Delegate.registered ctxt source >>= fun is_registered ->
      error_unless
        is_registered
        (Update_consensus_key_on_unregistered_delegate source)
      >>?= fun () ->
      Delegate.Consensus_key.register_update ctxt source pk >>=? fun ctxt ->
      return
        ( ctxt,
          Update_consensus_key_result
            {consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt},
          [] )
  | Tx_rollup_origination ->
      Tx_rollup.originate ctxt >>=? fun (ctxt, originated_tx_rollup) ->
      let result =
        Tx_rollup_origination_result
          {
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
            originated_tx_rollup;
            balance_updates = [];
          }
      in
      return (ctxt, result, [])
  | Tx_rollup_submit_batch {tx_rollup; content; burn_limit} ->
      let message, message_size = Tx_rollup_message.make_batch content in
      Tx_rollup_gas.hash_cost message_size >>?= fun cost ->
      Gas.consume ctxt cost >>?= fun ctxt ->
      Tx_rollup_state.get ctxt tx_rollup >>=? fun (ctxt, state) ->
      Tx_rollup_inbox.append_message ctxt tx_rollup state message
      >>=? fun (ctxt, state, paid_storage_size_diff) ->
      Tx_rollup_state.burn_cost ~limit:burn_limit state message_size
      >>?= fun cost ->
      Token.transfer ctxt (`Contract source_contract) `Burned cost
      >>=? fun (ctxt, balance_updates) ->
      Tx_rollup_state.update ctxt tx_rollup state >>=? fun ctxt ->
      let result =
        Tx_rollup_submit_batch_result
          {
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
            balance_updates;
            paid_storage_size_diff;
          }
      in
      return (ctxt, result, [])
  | Tx_rollup_commit {tx_rollup; commitment} ->
      Tx_rollup_state.get ctxt tx_rollup >>=? fun (ctxt, state) ->
      ( Tx_rollup_commitment.has_bond ctxt tx_rollup source
      >>=? fun (ctxt, pending) ->
        if not pending then
          let bond_id = Bond_id.Tx_rollup_bond_id tx_rollup in
          Token.transfer
            ctxt
            (`Contract source_contract)
            (`Frozen_bonds (source_contract, bond_id))
            (Constants.tx_rollup_commitment_bond ctxt)
        else return (ctxt, []) )
      >>=? fun (ctxt, balance_updates) ->
      Tx_rollup_commitment.add_commitment ctxt tx_rollup state source commitment
      >>=? fun (ctxt, state, to_slash) ->
      (match to_slash with
      | Some pkh ->
          let committer = Contract.Implicit pkh in
          Tx_rollup_commitment.slash_bond ctxt tx_rollup pkh
          >>=? fun (ctxt, slashed) ->
          if slashed then
            let bid = Bond_id.Tx_rollup_bond_id tx_rollup in
            Token.balance ctxt (`Frozen_bonds (committer, bid))
            >>=? fun (ctxt, burn) ->
            Token.transfer
              ctxt
              (`Frozen_bonds (committer, bid))
              `Tx_rollup_rejection_punishments
              burn
          else return (ctxt, [])
      | None -> return (ctxt, []))
      >>=? fun (ctxt, burn_update) ->
      Tx_rollup_state.update ctxt tx_rollup state >>=? fun ctxt ->
      let result =
        Tx_rollup_commit_result
          {
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
            balance_updates = burn_update @ balance_updates;
          }
      in
      return (ctxt, result, [])
  | Tx_rollup_return_bond {tx_rollup} ->
      Tx_rollup_commitment.remove_bond ctxt tx_rollup source >>=? fun ctxt ->
      let bond_id = Bond_id.Tx_rollup_bond_id tx_rollup in
      Token.balance ctxt (`Frozen_bonds (source_contract, bond_id))
      >>=? fun (ctxt, bond) ->
      Token.transfer
        ctxt
        (`Frozen_bonds (source_contract, bond_id))
        (`Contract source_contract)
        bond
      >>=? fun (ctxt, balance_updates) ->
      let result =
        Tx_rollup_return_bond_result
          {
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
            balance_updates;
          }
      in
      return (ctxt, result, [])
  | Tx_rollup_finalize_commitment {tx_rollup} ->
      Tx_rollup_state.get ctxt tx_rollup >>=? fun (ctxt, state) ->
      Tx_rollup_commitment.finalize_commitment ctxt tx_rollup state
      >>=? fun (ctxt, state, level) ->
      Tx_rollup_state.update ctxt tx_rollup state >>=? fun ctxt ->
      let result =
        Tx_rollup_finalize_commitment_result
          {
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
            balance_updates = [];
            level;
          }
      in
      return (ctxt, result, [])
  | Tx_rollup_remove_commitment {tx_rollup} ->
      Tx_rollup_state.get ctxt tx_rollup >>=? fun (ctxt, state) ->
      Tx_rollup_commitment.remove_commitment ctxt tx_rollup state
      >>=? fun (ctxt, state, level) ->
      Tx_rollup_state.update ctxt tx_rollup state >>=? fun ctxt ->
      let result =
        Tx_rollup_remove_commitment_result
          {
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
            balance_updates = [];
            level;
          }
      in
      return (ctxt, result, [])
  | Tx_rollup_rejection
      {
        proof;
        tx_rollup;
        level;
        message;
        message_position;
        message_path;
        message_result_hash;
        message_result_path;
        previous_message_result;
        previous_message_result_path;
      } -> (
      Tx_rollup_state.get ctxt tx_rollup >>=? fun (ctxt, state) ->
      (* Check [level] *)
      Tx_rollup_state.check_level_can_be_rejected state level >>?= fun () ->
      Tx_rollup_commitment.get ctxt tx_rollup state level
      >>=? fun (ctxt, commitment) ->
      (* Check [message] *)
      error_when
        Compare.Int.(
          message_position < 0
          || commitment.commitment.messages.count <= message_position)
        (Tx_rollup_errors.Wrong_message_position
           {
             level = commitment.commitment.level;
             position = message_position;
             length = commitment.commitment.messages.count;
           })
      >>?= fun () ->
      Tx_rollup_inbox.check_message_hash
        ctxt
        level
        tx_rollup
        ~position:message_position
        message
        message_path
      >>=? fun ctxt ->
      (* Check message result paths *)
      Tx_rollup_commitment.check_agreed_and_disputed_results
        ctxt
        tx_rollup
        state
        commitment
        ~agreed_result:previous_message_result
        ~agreed_result_path:previous_message_result_path
        ~disputed_result:message_result_hash
        ~disputed_result_path:message_result_path
        ~disputed_position:message_position
      >>=? fun ctxt ->
      (* Check [proof] *)
      let parameters =
        Tx_rollup_l2_apply.
          {
            tx_rollup_max_withdrawals_per_batch =
              Constants.tx_rollup_max_withdrawals_per_batch ctxt;
          }
      in
      let proof_length = Tx_rollup_l2_proof.length proof in
      match Tx_rollup_l2_proof.proof_of_serialized_opt proof with
      | Some proof ->
          Tx_rollup_l2_verifier.verify_proof
            ctxt
            parameters
            message
            proof
            ~proof_length
            ~agreed:previous_message_result
            ~rejected:message_result_hash
            ~max_proof_size:(Constants.tx_rollup_rejection_max_proof_size ctxt)
          >>=? fun ctxt ->
          (* Proof is correct, removing *)
          Tx_rollup_commitment.reject_commitment ctxt tx_rollup state level
          >>=? fun (ctxt, state) ->
          (* Bond slashing, and removing *)
          Tx_rollup_commitment.slash_bond ctxt tx_rollup commitment.committer
          >>=? fun (ctxt, slashed) ->
          (if slashed then
           let committer = Contract.Implicit commitment.committer in
           let bid = Bond_id.Tx_rollup_bond_id tx_rollup in
           Token.balance ctxt (`Frozen_bonds (committer, bid))
           >>=? fun (ctxt, burn) ->
           Tez.(burn /? 2L) >>?= fun reward ->
           Token.transfer
             ctxt
             (`Frozen_bonds (committer, bid))
             `Tx_rollup_rejection_punishments
             burn
           >>=? fun (ctxt, burn_update) ->
           Token.transfer
             ctxt
             `Tx_rollup_rejection_rewards
             (`Contract source_contract)
             reward
           >>=? fun (ctxt, reward_update) ->
           return (ctxt, burn_update @ reward_update)
          else return (ctxt, []))
          >>=? fun (ctxt, balance_updates) ->
          (* Update state and conclude *)
          Tx_rollup_state.update ctxt tx_rollup state >>=? fun ctxt ->
          let result =
            Tx_rollup_rejection_result
              {
                consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
                balance_updates;
              }
          in
          return (ctxt, result, [])
      | None -> fail Tx_rollup_errors.Proof_undecodable)
  | Dal_publish_slot_header {slot_header} ->
      Dal_apply.apply_publish_slot_header ctxt slot_header >>?= fun ctxt ->
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result = Dal_publish_slot_header_result {consumed_gas} in
      return (ctxt, result, [])
  | Sc_rollup_originate {kind; boot_sector; origination_proof; parameters_ty} ->
      Sc_rollup_operations.originate
        ctxt
        ~kind
        ~boot_sector
        ~origination_proof
        ~parameters_ty
      >>=? fun ({address; size; genesis_commitment_hash}, ctxt) ->
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result =
        Sc_rollup_originate_result
          {
            address;
            genesis_commitment_hash;
            consumed_gas;
            size;
            balance_updates = [];
          }
      in
      return (ctxt, result, [])
  | Sc_rollup_add_messages {rollup; messages} ->
      Sc_rollup.Inbox.add_external_messages ctxt rollup messages
      >>=? fun (inbox_after, _size, ctxt) ->
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result = Sc_rollup_add_messages_result {consumed_gas; inbox_after} in
      return (ctxt, result, [])
  | Sc_rollup_cement {rollup; commitment} ->
      Sc_rollup.Stake_storage.cement_commitment ctxt rollup commitment
      >>=? fun (ctxt, commitment) ->
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result =
        Sc_rollup_cement_result
          {consumed_gas; inbox_level = commitment.inbox_level}
      in
      return (ctxt, result, [])
  | Sc_rollup_publish {rollup; commitment} ->
      Sc_rollup.Stake_storage.publish_commitment ctxt rollup source commitment
      >>=? fun (staked_hash, published_at_level, ctxt, balance_updates) ->
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result =
        Sc_rollup_publish_result
          {staked_hash; consumed_gas; published_at_level; balance_updates}
      in
      return (ctxt, result, [])
  | Sc_rollup_refute {rollup; opponent; refutation} ->
      let open Sc_rollup.Refutation_storage in
      let player = source in
      (match refutation with
      | None ->
          start_game ctxt rollup ~player ~opponent >>=? fun ctxt ->
          return (None, ctxt)
      | Some refutation -> game_move ctxt rollup ~player ~opponent refutation)
      >>=? fun (game_result, ctxt) ->
      (match game_result with
      | None -> return (Sc_rollup.Game.Ongoing, ctxt, [])
      | Some game_result ->
          let stakers = Sc_rollup.Game.Index.make source opponent in
          Sc_rollup.Refutation_storage.apply_game_result
            ctxt
            rollup
            stakers
            game_result)
      >>=? fun (game_status, ctxt, balance_updates) ->
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result =
        Sc_rollup_refute_result {game_status; consumed_gas; balance_updates}
      in
      return (ctxt, result, [])
  | Sc_rollup_timeout {rollup; stakers} ->
      Sc_rollup.Refutation_storage.timeout ctxt rollup stakers
      >>=? fun (game_result, ctxt) ->
      Sc_rollup.Refutation_storage.apply_game_result
        ctxt
        rollup
        stakers
        game_result
      >>=? fun (game_status, ctxt, balance_updates) ->
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result =
        Sc_rollup_timeout_result {game_status; consumed_gas; balance_updates}
      in
      return (ctxt, result, [])
  | Sc_rollup_execute_outbox_message {rollup; cemented_commitment; output_proof}
    ->
      Sc_rollup_operations.execute_outbox_message
        ctxt
        rollup
        ~cemented_commitment
        ~source
        ~output_proof
      >|=? fun ({Sc_rollup_operations.paid_storage_size_diff; operations}, ctxt)
        ->
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result =
        Sc_rollup_execute_outbox_message_result
          {paid_storage_size_diff; balance_updates = []; consumed_gas}
      in
      (ctxt, result, operations)
  | Sc_rollup_recover_bond {sc_rollup} ->
      Sc_rollup.Stake_storage.withdraw_stake ctxt sc_rollup source
      >>=? fun (ctxt, balance_updates) ->
      let result =
        Sc_rollup_recover_bond_result
          {
            consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt;
            balance_updates;
          }
      in
      return (ctxt, result, [])
  | Sc_rollup_dal_slot_subscribe {rollup; slot_index} ->
      let open Lwt_tzresult_syntax in
      let+ slot_index, level, ctxt =
        Sc_rollup.Dal_slot.subscribe ctxt rollup ~slot_index
      in
      let consumed_gas = Gas.consumed ~since:ctxt_before_op ~until:ctxt in
      let result =
        Sc_rollup_dal_slot_subscribe_result {consumed_gas; slot_index; level}
      in
      (ctxt, result, [])
  | Zk_rollup_origination {public_parameters; circuits_info; init_state; nb_ops}
    ->
      Zk_rollup_apply.originate
        ~ctxt_before_op
        ~ctxt
        ~public_parameters
        ~circuits_info
        ~init_state
        ~nb_ops
  | Zk_rollup_publish {zk_rollup; ops} ->
      Zk_rollup_apply.publish ~ctxt_before_op ~ctxt ~zk_rollup ~l2_ops:ops

type success_or_failure = Success of context | Failure

let apply_internal_operations ctxt ~payer ~chain_id ops =
  let rec apply ctxt applied worklist =
    match worklist with
    | [] -> Lwt.return (Success ctxt, List.rev applied)
    | Script_typed_ir.Internal_operation ({source; operation; nonce} as op)
      :: rest -> (
        (if internal_nonce_already_recorded ctxt nonce then
         let op_res = Apply_internal_results.internal_operation op in
         fail (Internal_operation_replay (Internal_operation op_res))
        else
          let ctxt = record_internal_nonce ctxt nonce in
          apply_internal_operation_contents
            ctxt
            ~source
            ~payer
            ~chain_id
            operation)
        >>= function
        | Error errors ->
            let result =
              pack_internal_operation_result
                op
                (Failed (Script_typed_ir.manager_kind op.operation, errors))
            in
            let skipped =
              List.rev_map
                (fun (Script_typed_ir.Internal_operation op) ->
                  pack_internal_operation_result
                    op
                    (Skipped (Script_typed_ir.manager_kind op.operation)))
                rest
            in
            Lwt.return (Failure, List.rev (skipped @ (result :: applied)))
        | Ok (ctxt, result, emitted) ->
            apply
              ctxt
              (pack_internal_operation_result op (Applied result) :: applied)
              (emitted @ rest))
  in
  apply ctxt [] ops

let burn_transaction_storage_fees ctxt trr ~storage_limit ~payer =
  match trr with
  | Transaction_to_contract_result payload ->
      let consumed = payload.paid_storage_size_diff in
      Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
      >>=? fun (ctxt, storage_limit, storage_bus) ->
      (if payload.allocated_destination_contract then
       Fees.burn_origination_fees ctxt ~storage_limit ~payer
      else return (ctxt, storage_limit, []))
      >>=? fun (ctxt, storage_limit, origination_bus) ->
      let balance_updates =
        storage_bus @ payload.balance_updates @ origination_bus
      in
      return
        ( ctxt,
          storage_limit,
          Transaction_to_contract_result
            {
              storage = payload.storage;
              lazy_storage_diff = payload.lazy_storage_diff;
              balance_updates;
              ticket_receipt = payload.ticket_receipt;
              originated_contracts = payload.originated_contracts;
              consumed_gas = payload.consumed_gas;
              storage_size = payload.storage_size;
              paid_storage_size_diff = payload.paid_storage_size_diff;
              allocated_destination_contract =
                payload.allocated_destination_contract;
            } )
  | Transaction_to_tx_rollup_result payload ->
      let consumed = payload.paid_storage_size_diff in
      Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
      >>=? fun (ctxt, storage_limit, storage_bus) ->
      let balance_updates = storage_bus @ payload.balance_updates in
      return
        ( ctxt,
          storage_limit,
          Transaction_to_tx_rollup_result {payload with balance_updates} )
  | Transaction_to_sc_rollup_result _ -> return (ctxt, storage_limit, trr)
  | Transaction_to_zk_rollup_result payload ->
      let consumed = payload.paid_storage_size_diff in
      Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
      >>=? fun (ctxt, storage_limit, storage_bus) ->
      let balance_updates = storage_bus @ payload.balance_updates in
      return
        ( ctxt,
          storage_limit,
          Transaction_to_zk_rollup_result {payload with balance_updates} )

let burn_origination_storage_fees ctxt
    {
      lazy_storage_diff;
      balance_updates;
      originated_contracts;
      consumed_gas;
      storage_size;
      paid_storage_size_diff;
    } ~storage_limit ~payer =
  let consumed = paid_storage_size_diff in
  Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
  >>=? fun (ctxt, storage_limit, storage_bus) ->
  Fees.burn_origination_fees ctxt ~storage_limit ~payer
  >>=? fun (ctxt, storage_limit, origination_bus) ->
  let balance_updates = storage_bus @ origination_bus @ balance_updates in
  return
    ( ctxt,
      storage_limit,
      {
        lazy_storage_diff;
        balance_updates;
        originated_contracts;
        consumed_gas;
        storage_size;
        paid_storage_size_diff;
      } )

(** [burn_manager_storage_fees ctxt smopr storage_limit payer] burns the
    storage fees associated to an external operation result [smopr].
    Returns an updated context, an updated storage limit with the space consumed
    by the operation subtracted, and [smopr] with the relevant balance updates
    included. *)
let burn_manager_storage_fees :
    type kind.
    context ->
    kind successful_manager_operation_result ->
    storage_limit:Z.t ->
    payer:public_key_hash ->
    (context * Z.t * kind successful_manager_operation_result) tzresult Lwt.t =
 fun ctxt smopr ~storage_limit ~payer ->
  let payer = `Contract (Contract.Implicit payer) in
  match smopr with
  | Transaction_result transaction_result ->
      burn_transaction_storage_fees
        ctxt
        transaction_result
        ~storage_limit
        ~payer
      >>=? fun (ctxt, storage_limit, transaction_result) ->
      return (ctxt, storage_limit, Transaction_result transaction_result)
  | Origination_result origination_result ->
      burn_origination_storage_fees
        ctxt
        origination_result
        ~storage_limit
        ~payer
      >>=? fun (ctxt, storage_limit, origination_result) ->
      return (ctxt, storage_limit, Origination_result origination_result)
  | Reveal_result _ | Delegation_result _ -> return (ctxt, storage_limit, smopr)
  | Register_global_constant_result payload ->
      let consumed = payload.size_of_constant in
      Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
      >|=? fun (ctxt, storage_limit, storage_bus) ->
      let balance_updates = storage_bus @ payload.balance_updates in
      ( ctxt,
        storage_limit,
        Register_global_constant_result
          {
            balance_updates;
            consumed_gas = payload.consumed_gas;
            size_of_constant = payload.size_of_constant;
            global_address = payload.global_address;
          } )
  | Set_deposits_limit_result _ | Update_consensus_key_result _ ->
      return (ctxt, storage_limit, smopr)
  | Increase_paid_storage_result _ -> return (ctxt, storage_limit, smopr)
  | Tx_rollup_origination_result payload ->
      Fees.burn_tx_rollup_origination_fees ctxt ~storage_limit ~payer
      >|=? fun (ctxt, storage_limit, origination_bus) ->
      let balance_updates = origination_bus @ payload.balance_updates in
      ( ctxt,
        storage_limit,
        Tx_rollup_origination_result {payload with balance_updates} )
  | Tx_rollup_return_bond_result _ | Tx_rollup_remove_commitment_result _
  | Tx_rollup_rejection_result _ | Tx_rollup_finalize_commitment_result _
  | Tx_rollup_commit_result _ ->
      return (ctxt, storage_limit, smopr)
  | Transfer_ticket_result payload ->
      let consumed = payload.paid_storage_size_diff in
      Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
      >|=? fun (ctxt, storage_limit, storage_bus) ->
      let balance_updates = payload.balance_updates @ storage_bus in
      ( ctxt,
        storage_limit,
        Transfer_ticket_result {payload with balance_updates} )
  | Tx_rollup_submit_batch_result payload ->
      let consumed = payload.paid_storage_size_diff in
      Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
      >|=? fun (ctxt, storage_limit, storage_bus) ->
      let balance_updates = storage_bus @ payload.balance_updates in
      ( ctxt,
        storage_limit,
        Tx_rollup_submit_batch_result {payload with balance_updates} )
  | Tx_rollup_dispatch_tickets_result payload ->
      let consumed = payload.paid_storage_size_diff in
      Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
      >|=? fun (ctxt, storage_limit, storage_bus) ->
      let balance_updates = storage_bus @ payload.balance_updates in
      ( ctxt,
        storage_limit,
        Tx_rollup_dispatch_tickets_result {payload with balance_updates} )
  | Dal_publish_slot_header_result _ -> return (ctxt, storage_limit, smopr)
  | Sc_rollup_originate_result payload ->
      Fees.burn_sc_rollup_origination_fees
        ctxt
        ~storage_limit
        ~payer
        payload.size
      >|=? fun (ctxt, storage_limit, balance_updates) ->
      let result = Sc_rollup_originate_result {payload with balance_updates} in
      (ctxt, storage_limit, result)
  | Sc_rollup_add_messages_result _ -> return (ctxt, storage_limit, smopr)
  | Sc_rollup_cement_result _ -> return (ctxt, storage_limit, smopr)
  | Sc_rollup_publish_result _ -> return (ctxt, storage_limit, smopr)
  | Sc_rollup_refute_result _ -> return (ctxt, storage_limit, smopr)
  | Sc_rollup_timeout_result _ -> return (ctxt, storage_limit, smopr)
  | Sc_rollup_execute_outbox_message_result
      ({paid_storage_size_diff; balance_updates; _} as payload) ->
      let consumed = paid_storage_size_diff in
      Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
      >|=? fun (ctxt, storage_limit, storage_bus) ->
      let balance_updates = storage_bus @ balance_updates in
      ( ctxt,
        storage_limit,
        Sc_rollup_execute_outbox_message_result {payload with balance_updates}
      )
  | Sc_rollup_recover_bond_result _ -> return (ctxt, storage_limit, smopr)
  | Sc_rollup_dal_slot_subscribe_result _ -> return (ctxt, storage_limit, smopr)
  | Zk_rollup_origination_result payload ->
      Fees.burn_zk_rollup_origination_fees
        ctxt
        ~storage_limit
        ~payer
        payload.storage_size
      >>=? fun (ctxt, storage_limit, balance_updates) ->
      let result =
        Zk_rollup_origination_result {payload with balance_updates}
      in
      return (ctxt, storage_limit, result)
  | Zk_rollup_publish_result payload ->
      let consumed = payload.paid_storage_size_diff in
      Fees.burn_storage_fees ctxt ~storage_limit ~payer consumed
      >|=? fun (ctxt, storage_limit, storage_bus) ->
      let balance_updates = storage_bus @ payload.balance_updates in
      ( ctxt,
        storage_limit,
        Zk_rollup_publish_result {payload with balance_updates} )

(** [burn_internal_storage_fees ctxt smopr storage_limit payer] burns the
    storage fees associated to an internal operation result [smopr].
    Returns an updated context, an updated storage limit with the space consumed
    by the operation subtracted, and [smopr] with the relevant balance updates
    included. *)
let burn_internal_storage_fees :
    type kind.
    context ->
    kind successful_internal_operation_result ->
    storage_limit:Z.t ->
    payer:public_key_hash ->
    (context * Z.t * kind successful_internal_operation_result) tzresult Lwt.t =
 fun ctxt smopr ~storage_limit ~payer ->
  let payer = `Contract (Contract.Implicit payer) in
  match smopr with
  | ITransaction_result transaction_result ->
      burn_transaction_storage_fees
        ctxt
        transaction_result
        ~storage_limit
        ~payer
      >|=? fun (ctxt, storage_limit, transaction_result) ->
      (ctxt, storage_limit, ITransaction_result transaction_result)
  | IOrigination_result origination_result ->
      burn_origination_storage_fees
        ctxt
        origination_result
        ~storage_limit
        ~payer
      >|=? fun (ctxt, storage_limit, origination_result) ->
      (ctxt, storage_limit, IOrigination_result origination_result)
  | IDelegation_result _ -> return (ctxt, storage_limit, smopr)
  | IEvent_result _ -> return (ctxt, storage_limit, smopr)

let apply_manager_contents (type kind) ctxt chain_id
    (op : kind Kind.manager contents) :
    (success_or_failure
    * kind manager_operation_result
    * packed_internal_operation_result list)
    Lwt.t =
  let (Manager_operation {source; operation; gas_limit; storage_limit; _}) =
    op
  in
  (* We do not expose the internal scaling to the users. Instead, we multiply
       the specified gas limit by the internal scaling. *)
  let ctxt = Gas.set_limit ctxt gas_limit in
  apply_manager_operation ctxt ~source ~chain_id operation >>= function
  | Ok (ctxt, operation_results, internal_operations) -> (
      apply_internal_operations ctxt ~payer:source ~chain_id internal_operations
      >>= function
      | Success ctxt, internal_operations_results -> (
          burn_manager_storage_fees
            ctxt
            operation_results
            ~storage_limit
            ~payer:source
          >>= function
          | Ok (ctxt, storage_limit, operation_results) -> (
              List.fold_left_es
                (fun (ctxt, storage_limit, res) imopr ->
                  let (Internal_operation_result (op, mopr)) = imopr in
                  match mopr with
                  | Applied smopr ->
                      burn_internal_storage_fees
                        ctxt
                        smopr
                        ~storage_limit
                        ~payer:source
                      >>=? fun (ctxt, storage_limit, smopr) ->
                      let imopr =
                        Internal_operation_result (op, Applied smopr)
                      in
                      return (ctxt, storage_limit, imopr :: res)
                  | _ -> return (ctxt, storage_limit, imopr :: res))
                (ctxt, storage_limit, [])
                internal_operations_results
              >|= function
              | Ok (ctxt, _, internal_operations_results) ->
                  ( Success ctxt,
                    Applied operation_results,
                    List.rev internal_operations_results )
              | Error errors ->
                  ( Failure,
                    Backtracked (operation_results, Some errors),
                    internal_operations_results ))
          | Error errors ->
              Lwt.return
                ( Failure,
                  Backtracked (operation_results, Some errors),
                  internal_operations_results ))
      | Failure, internal_operations_results ->
          Lwt.return
            (Failure, Applied operation_results, internal_operations_results))
  | Error errors ->
      Lwt.return (Failure, Failed (manager_kind operation, errors), [])

(** An individual manager operation (either standalone or inside a
    batch) together with the balance update corresponding to the
    transfer of its fee. *)
type 'kind fees_updated_contents = {
  contents : 'kind contents;
  balance_updates : Receipt.balance_updates;
}

type _ fees_updated_contents_list =
  | FeesUpdatedSingle :
      'kind fees_updated_contents
      -> 'kind fees_updated_contents_list
  | FeesUpdatedCons :
      'kind Kind.manager fees_updated_contents
      * 'rest Kind.manager fees_updated_contents_list
      -> ('kind * 'rest) Kind.manager fees_updated_contents_list

let rec mark_skipped :
    type kind.
    payload_producer:Consensus_key.t ->
    Level.t ->
    kind Kind.manager fees_updated_contents_list ->
    kind Kind.manager contents_result_list =
 fun ~payload_producer level fees_updated_contents_list ->
  match fees_updated_contents_list with
  | FeesUpdatedSingle
      {contents = Manager_operation {operation; _}; balance_updates} ->
      Single_result
        (Manager_operation_result
           {
             balance_updates;
             operation_result = Skipped (manager_kind operation);
             internal_operation_results = [];
           })
  | FeesUpdatedCons
      ({contents = Manager_operation {operation; _}; balance_updates}, rest) ->
      Cons_result
        ( Manager_operation_result
            {
              balance_updates;
              operation_result = Skipped (manager_kind operation);
              internal_operation_results = [];
            },
          mark_skipped ~payload_producer level rest )

(** Return balance updates for fees, and an updated context that
   accounts for:

    - fees spending,

    - counter incrementation,

    - consumption of each operation's [gas_limit] from the available
   block gas.

    The operation should already have been validated by
   {!Validate.validate_operation}. The latter is responsible for ensuring that
   the operation is solvable, i.e. its fees can be taken, i.e.
   [take_fees] cannot return an error. *)
let take_fees ctxt contents_list =
  let open Lwt_tzresult_syntax in
  let rec take_fees_rec :
      type kind.
      context ->
      kind Kind.manager contents_list ->
      (context * kind Kind.manager fees_updated_contents_list) tzresult Lwt.t =
   fun ctxt contents_list ->
    let contents_effects contents =
      let (Manager_operation {source; fee; gas_limit; _}) = contents in
      let*? ctxt = Gas.consume_limit_in_block ctxt gas_limit in
      let* ctxt = Contract.increment_counter ctxt source in
      let+ ctxt, balance_updates =
        Token.transfer
          ctxt
          (`Contract (Contract.Implicit source))
          `Block_fees
          fee
      in
      (ctxt, {contents; balance_updates})
    in
    match contents_list with
    | Single contents ->
        let+ ctxt, fees_updated_contents = contents_effects contents in
        (ctxt, FeesUpdatedSingle fees_updated_contents)
    | Cons (contents, rest) ->
        let* ctxt, fees_updated_contents = contents_effects contents in
        let+ ctxt, result_rest = take_fees_rec ctxt rest in
        (ctxt, FeesUpdatedCons (fees_updated_contents, result_rest))
  in
  let*! result = take_fees_rec ctxt contents_list in
  Lwt.return (record_trace Error_while_taking_fees result)

let rec apply_manager_contents_list_rec :
    type kind.
    context ->
    payload_producer:Consensus_key.t ->
    Chain_id.t ->
    kind Kind.manager fees_updated_contents_list ->
    (success_or_failure * kind Kind.manager contents_result_list) Lwt.t =
 fun ctxt ~payload_producer chain_id fees_updated_contents_list ->
  let level = Level.current ctxt in
  match fees_updated_contents_list with
  | FeesUpdatedSingle {contents = Manager_operation _ as op; balance_updates} ->
      apply_manager_contents ctxt chain_id op
      >|= fun (ctxt_result, operation_result, internal_operation_results) ->
      let result =
        Manager_operation_result
          {balance_updates; operation_result; internal_operation_results}
      in
      (ctxt_result, Single_result result)
  | FeesUpdatedCons
      ({contents = Manager_operation _ as op; balance_updates}, rest) -> (
      apply_manager_contents ctxt chain_id op >>= function
      | Failure, operation_result, internal_operation_results ->
          let result =
            Manager_operation_result
              {balance_updates; operation_result; internal_operation_results}
          in
          Lwt.return
            ( Failure,
              Cons_result (result, mark_skipped ~payload_producer level rest) )
      | Success ctxt, operation_result, internal_operation_results ->
          let result =
            Manager_operation_result
              {balance_updates; operation_result; internal_operation_results}
          in
          apply_manager_contents_list_rec ctxt ~payload_producer chain_id rest
          >|= fun (ctxt_result, results) ->
          (ctxt_result, Cons_result (result, results)))

let mark_backtracked results =
  let mark_results :
      type kind.
      kind Kind.manager contents_result -> kind Kind.manager contents_result =
   fun results ->
    let mark_manager_operation_result :
        type kind.
        kind manager_operation_result -> kind manager_operation_result =
      function
      | (Failed _ | Skipped _ | Backtracked _) as result -> result
      | Applied result -> Backtracked (result, None)
    in
    let mark_internal_operation_result :
        type kind.
        kind internal_operation_result -> kind internal_operation_result =
      function
      | (Failed _ | Skipped _ | Backtracked _) as result -> result
      | Applied result -> Backtracked (result, None)
    in
    let mark_internal_operation_results
        (Internal_operation_result (kind, result)) =
      Internal_operation_result (kind, mark_internal_operation_result result)
    in
    match results with
    | Manager_operation_result op ->
        Manager_operation_result
          {
            balance_updates = op.balance_updates;
            operation_result = mark_manager_operation_result op.operation_result;
            internal_operation_results =
              List.map
                mark_internal_operation_results
                op.internal_operation_results;
          }
  in
  let rec traverse_apply_results :
      type kind.
      kind Kind.manager contents_result_list ->
      kind Kind.manager contents_result_list = function
    | Single_result res -> Single_result (mark_results res)
    | Cons_result (res, rest) ->
        Cons_result (mark_results res, traverse_apply_results rest)
  in
  traverse_apply_results results

type mode =
  | Application of {
      block_header : Block_header.t;
      fitness : Fitness.t;
      payload_producer : Consensus_key.t;
      block_producer : Consensus_key.t;
      predecessor_level : Level.t;
      predecessor_round : Round.t;
    }
  | Full_construction of {
      block_data_contents : Block_header.contents;
      predecessor_hash : Block_hash.t;
      payload_producer : Consensus_key.t;
      block_producer : Consensus_key.t;
      round : Round.t;
      predecessor_level : Level.t;
      predecessor_round : Round.t;
    }
  | Partial_construction of {
      predecessor_level : Raw_level.t;
      predecessor_fitness : Fitness.raw;
    }

type application_state = {
  ctxt : t;
  chain_id : Chain_id.t;
  mode : mode;
  op_count : int;
  migration_balance_updates : Receipt.balance_updates;
  liquidity_baking_toggle_ema : Liquidity_baking.Toggle_EMA.t;
  implicit_operations_results :
    Apply_results.packed_successful_manager_operation_result list;
}

let record_operation (type kind) ctxt hash (operation : kind operation) :
    context =
  match operation.protocol_data.contents with
  | Single (Preendorsement _) -> ctxt
  | Single (Endorsement _) -> ctxt
  | Single (Dal_slot_availability _) -> ctxt
  | Single
      ( Failing_noop _ | Proposals _ | Ballot _ | Seed_nonce_revelation _
      | Vdf_revelation _ | Double_endorsement_evidence _
      | Double_preendorsement_evidence _ | Double_baking_evidence _
      | Activate_account _ | Drain_delegate _ | Manager_operation _ )
  | Cons (Manager_operation _, _) ->
      record_non_consensus_operation_hash ctxt hash

let record_preendorsement ctxt (mode : mode) (content : consensus_content) :
    (context * Kind.preendorsement contents_result_list) tzresult =
  let open Tzresult_syntax in
  let ctxt =
    match mode with
    | Full_construction _ -> (
        match Consensus.get_preendorsements_quorum_round ctxt with
        | None -> Consensus.set_preendorsements_quorum_round ctxt content.round
        | Some _ -> ctxt)
    | Application _ | Partial_construction _ -> ctxt
  in
  match Slot.Map.find content.slot (Consensus.allowed_preendorsements ctxt) with
  | None ->
      (* This should not happen: operation validation should have failed. *)
      error Faulty_validation_wrong_slot
  | Some ({delegate; consensus_pkh; _}, preendorsement_power) ->
      let* ctxt =
        Consensus.record_preendorsement
          ctxt
          ~initial_slot:content.slot
          ~power:preendorsement_power
          content.round
      in
      return
        ( ctxt,
          Single_result
            (Preendorsement_result
               {
                 balance_updates = [];
                 delegate;
                 consensus_key = consensus_pkh;
                 preendorsement_power;
               }) )

let is_grandparent_endorsement mode content =
  match mode with
  | Partial_construction {predecessor_level; _} ->
      Raw_level.(succ content.level = predecessor_level)
  | _ -> false

let record_endorsement ctxt (mode : mode) (content : consensus_content) :
    (context * Kind.endorsement contents_result_list) tzresult Lwt.t =
  let open Lwt_tzresult_syntax in
  let mk_endorsement_result {Consensus_key.delegate; consensus_pkh}
      endorsement_power =
    Single_result
      (Endorsement_result
         {
           balance_updates = [];
           delegate;
           consensus_key = consensus_pkh;
           endorsement_power;
         })
  in
  if is_grandparent_endorsement mode content then
    let level = Level.from_raw ctxt content.level in
    let* ctxt, ({delegate; _} as consensus_key) =
      Stake_distribution.slot_owner ctxt level content.slot
    in
    let*? ctxt = Consensus.record_grand_parent_endorsement ctxt delegate in
    return (ctxt, mk_endorsement_result (Consensus_key.pkh consensus_key) 0)
  else
    match Slot.Map.find content.slot (Consensus.allowed_endorsements ctxt) with
    | None ->
        (* This should not happen: operation validation should have failed. *)
        fail Faulty_validation_wrong_slot
    | Some (consensus_key, power) ->
        let*? ctxt =
          Consensus.record_endorsement ctxt ~initial_slot:content.slot ~power
        in
        return
          (ctxt, mk_endorsement_result (Consensus_key.pkh consensus_key) power)

let apply_manager_contents_list ctxt ~payload_producer chain_id
    fees_updated_contents_list =
  apply_manager_contents_list_rec
    ctxt
    ~payload_producer
    chain_id
    fees_updated_contents_list
  >>= fun (ctxt_result, results) ->
  match ctxt_result with
  | Failure -> Lwt.return (ctxt (* backtracked *), mark_backtracked results)
  | Success ctxt ->
      Lazy_storage.cleanup_temporaries ctxt >|= fun ctxt -> (ctxt, results)

let apply_manager_operations ctxt ~payload_producer chain_id ~mempool_mode
    contents_list =
  let open Lwt_tzresult_syntax in
  let ctxt = if mempool_mode then Gas.reset_block_gas ctxt else ctxt in
  let* ctxt, fees_updated_contents_list = take_fees ctxt contents_list in
  let*! ctxt, contents_result_list =
    apply_manager_contents_list
      ctxt
      ~payload_producer
      chain_id
      fees_updated_contents_list
  in
  return (ctxt, contents_result_list)

let punish_delegate ctxt delegate level mistake mk_result ~payload_producer =
  let punish =
    match mistake with
    | `Double_baking -> Delegate.punish_double_baking
    | `Double_endorsing -> Delegate.punish_double_endorsing
  in
  punish ctxt delegate level >>=? fun (ctxt, burned, punish_balance_updates) ->
  (match Tez.(burned /? 2L) with
  | Ok reward ->
      Token.transfer
        ctxt
        `Double_signing_evidence_rewards
        (`Contract (Contract.Implicit payload_producer.Consensus_key.delegate))
        reward
  | Error _ -> (* reward is Tez.zero *) return (ctxt, []))
  >|=? fun (ctxt, reward_balance_updates) ->
  let balance_updates = reward_balance_updates @ punish_balance_updates in
  (ctxt, Single_result (mk_result balance_updates))

let punish_double_endorsement_or_preendorsement (type kind) ctxt
    ~(op1 : kind Kind.consensus Operation.t) ~payload_producer :
    (context
    * kind Kind.double_consensus_operation_evidence contents_result_list)
    tzresult
    Lwt.t =
  let mk_result (balance_updates : Receipt.balance_updates) :
      kind Kind.double_consensus_operation_evidence contents_result =
    match op1.protocol_data.contents with
    | Single (Preendorsement _) ->
        Double_preendorsement_evidence_result balance_updates
    | Single (Endorsement _) ->
        Double_endorsement_evidence_result balance_updates
  in
  match op1.protocol_data.contents with
  | Single (Preendorsement e1) | Single (Endorsement e1) ->
      let level = Level.from_raw ctxt e1.level in
      Stake_distribution.slot_owner ctxt level e1.slot
      >>=? fun (ctxt, consensus_pk1) ->
      punish_delegate
        ctxt
        consensus_pk1.delegate
        level
        `Double_endorsing
        mk_result
        ~payload_producer

let punish_double_baking ctxt (bh1 : Block_header.t) ~payload_producer =
  Fitness.from_raw bh1.shell.fitness >>?= fun bh1_fitness ->
  let round1 = Fitness.round bh1_fitness in
  Raw_level.of_int32 bh1.shell.level >>?= fun raw_level ->
  let level = Level.from_raw ctxt raw_level in
  let committee_size = Constants.consensus_committee_size ctxt in
  Round.to_slot round1 ~committee_size >>?= fun slot1 ->
  Stake_distribution.slot_owner ctxt level slot1
  >>=? fun (ctxt, consensus_pk1) ->
  punish_delegate
    ctxt
    consensus_pk1.delegate
    level
    `Double_baking
    ~payload_producer
    (fun balance_updates -> Double_baking_evidence_result balance_updates)

let apply_contents_list (type kind) ctxt chain_id (mode : mode)
    ~payload_producer (contents_list : kind contents_list) :
    (context * kind contents_result_list) tzresult Lwt.t =
  let mempool_mode =
    match mode with
    | Partial_construction _ -> true
    | Full_construction _ | Application _ -> false
  in
  match contents_list with
  | Single (Preendorsement consensus_content) ->
      record_preendorsement ctxt mode consensus_content |> Lwt.return
  | Single (Endorsement consensus_content) ->
      record_endorsement ctxt mode consensus_content
  | Single (Dal_slot_availability (endorser, slot_availability)) ->
      (* DAL/FIXME https://gitlab.com/tezos/tezos/-/issues/3115

         This is a temporary operation. We do no check for the
         moment. In particular, this means we do not check the
         signature. Consequently, it is really important to ensure this
         operation cannot be included into a block when the feature flag
         is not set. This is done in order to avoid modifying the
         endorsement encoding. However, once the DAL will be ready, this
         operation should be merged with an endorsement or at least
         refined. *)
      Dal_apply.apply_data_availability ctxt slot_availability ~endorser
      >>=? fun ctxt ->
      return
        ( ctxt,
          Single_result (Dal_slot_availability_result {delegate = endorser}) )
  | Single (Seed_nonce_revelation {level; nonce}) ->
      let level = Level.from_raw ctxt level in
      Nonce.reveal ctxt level nonce >>=? fun ctxt ->
      let tip = Constants.seed_nonce_revelation_tip ctxt in
      let contract =
        Contract.Implicit payload_producer.Consensus_key.delegate
      in
      Token.transfer ctxt `Revelation_rewards (`Contract contract) tip
      >|=? fun (ctxt, balance_updates) ->
      (ctxt, Single_result (Seed_nonce_revelation_result balance_updates))
  | Single (Vdf_revelation {solution}) ->
      Seed.update_seed ctxt solution >>=? fun ctxt ->
      let tip = Constants.seed_nonce_revelation_tip ctxt in
      let contract =
        Contract.Implicit payload_producer.Consensus_key.delegate
      in
      Token.transfer ctxt `Revelation_rewards (`Contract contract) tip
      >|=? fun (ctxt, balance_updates) ->
      (ctxt, Single_result (Vdf_revelation_result balance_updates))
  | Single (Double_preendorsement_evidence {op1; op2 = _}) ->
      punish_double_endorsement_or_preendorsement ctxt ~op1 ~payload_producer
  | Single (Double_endorsement_evidence {op1; op2 = _}) ->
      punish_double_endorsement_or_preendorsement ctxt ~op1 ~payload_producer
  | Single (Double_baking_evidence {bh1; bh2 = _}) ->
      punish_double_baking ctxt bh1 ~payload_producer
  | Single (Activate_account {id = pkh; activation_code}) ->
      let blinded_pkh =
        Blinded_public_key_hash.of_ed25519_pkh activation_code pkh
      in
      let src = `Collected_commitments blinded_pkh in
      let contract = Contract.Implicit (Signature.Ed25519 pkh) in
      Token.balance ctxt src >>=? fun (ctxt, amount) ->
      Token.transfer ctxt src (`Contract contract) amount
      >>=? fun (ctxt, bupds) ->
      return (ctxt, Single_result (Activate_account_result bupds))
  | Single (Proposals _ as contents) ->
      Amendment.apply_proposals ctxt chain_id contents
  | Single (Ballot _ as contents) -> Amendment.apply_ballot ctxt contents
  | Single (Drain_delegate {delegate; destination; consensus_key = _}) ->
      Delegate.drain ctxt ~delegate ~destination
      >>=? fun ( ctxt,
                 allocated_destination_contract,
                 fees,
                 drain_balance_updates ) ->
      Token.transfer
        ctxt
        (`Contract (Contract.Implicit delegate))
        (`Contract (Contract.Implicit payload_producer.Consensus_key.delegate))
        fees
      >>=? fun (ctxt, fees_balance_updates) ->
      let balance_updates = drain_balance_updates @ fees_balance_updates in
      return
        ( ctxt,
          Single_result
            (Drain_delegate_result
               {balance_updates; allocated_destination_contract}) )
  | Single (Failing_noop _) ->
      (* This operation always fails. It should already have been
         rejected by {!Validate.validate_operation}. *)
      fail Validate_errors.Failing_noop_error
  | Single (Manager_operation _) ->
      apply_manager_operations
        ctxt
        ~payload_producer
        chain_id
        ~mempool_mode
        contents_list
  | Cons (Manager_operation _, _) ->
      apply_manager_operations
        ctxt
        ~payload_producer
        chain_id
        ~mempool_mode
        contents_list

let apply_operation application_state operation_hash operation =
  let open Lwt_tzresult_syntax in
  let apply_operation application_state packed_operation ~payload_producer =
    let {shell; protocol_data = Operation_data unpacked_protocol_data} =
      packed_operation
    in
    let operation : _ Operation.t =
      {shell; protocol_data = unpacked_protocol_data}
    in
    let ctxt = Origination_nonce.init application_state.ctxt operation_hash in
    let ctxt = record_operation ctxt operation_hash operation in
    let* ctxt, result =
      apply_contents_list
        ctxt
        application_state.chain_id
        application_state.mode
        ~payload_producer
        operation.protocol_data.contents
    in
    let ctxt = Gas.set_unlimited ctxt in
    let ctxt = Origination_nonce.unset ctxt in
    let op_count = succ application_state.op_count in
    return
      ( {application_state with ctxt; op_count},
        Operation_metadata {contents = result} )
  in
  match application_state.mode with
  | Application {payload_producer; _} ->
      apply_operation application_state operation ~payload_producer
  | Full_construction {payload_producer; _} ->
      apply_operation application_state operation ~payload_producer
  | Partial_construction _ ->
      apply_operation
        application_state
        operation
        ~payload_producer:Consensus_key.zero

let may_start_new_cycle ctxt =
  match Level.dawn_of_a_new_cycle ctxt with
  | None -> return (ctxt, [], [])
  | Some last_cycle ->
      Delegate.cycle_end ctxt last_cycle
      >>=? fun (ctxt, balance_updates, deactivated) ->
      Bootstrap.cycle_end ctxt last_cycle >|=? fun ctxt ->
      (ctxt, balance_updates, deactivated)

let apply_liquidity_baking_subsidy ctxt ~toggle_vote =
  Liquidity_baking.on_subsidy_allowed
    ctxt
    ~toggle_vote
    (fun ctxt liquidity_baking_cpmm_contract_hash ->
      let liquidity_baking_cpmm_contract =
        Contract.Originated liquidity_baking_cpmm_contract_hash
      in
      let ctxt =
        (* We set a gas limit of 1/20th the block limit, which is ~10x
           actual usage here in Granada. Gas consumed is reported in
           the Transaction receipt, but not counted towards the block
           limit. The gas limit is reset to unlimited at the end of
           this function.*)
        Gas.set_limit
          ctxt
          (Gas.Arith.integral_exn
             (Z.div
                (Gas.Arith.integral_to_z
                   (Constants.hard_gas_limit_per_block ctxt))
                (Z.of_int 20)))
      in
      let backtracking_ctxt = ctxt in
      (let liquidity_baking_subsidy = Constants.liquidity_baking_subsidy ctxt in
       (* credit liquidity baking subsidy to CPMM contract *)
       Token.transfer
         ~origin:Subsidy
         ctxt
         `Liquidity_baking_subsidies
         (`Contract liquidity_baking_cpmm_contract)
         liquidity_baking_subsidy
       >>=? fun (ctxt, balance_updates) ->
       Script_cache.find ctxt liquidity_baking_cpmm_contract_hash
       >>=? fun (ctxt, cache_key, script) ->
       match script with
       | None -> fail (Script_tc_errors.No_such_entrypoint Entrypoint.default)
       | Some (script, script_ir) -> (
           (* Token.transfer which is being called above already loads this
              value into the Irmin cache, so no need to burn gas for it. *)
           Contract.get_balance ctxt liquidity_baking_cpmm_contract
           >>=? fun balance ->
           let now = Script_timestamp.now ctxt in
           let level =
             (Level.current ctxt).level |> Raw_level.to_int32
             |> Script_int.of_int32 |> Script_int.abs
           in
           let step_constants =
             let open Script_interpreter in
             (* Using dummy values for source, payer, and chain_id
                since they are not used within the CPMM default
                entrypoint. *)
             {
               source = liquidity_baking_cpmm_contract;
               payer = Signature.Public_key_hash.zero;
               self = liquidity_baking_cpmm_contract_hash;
               amount = liquidity_baking_subsidy;
               balance;
               chain_id = Chain_id.zero;
               now;
               level;
             }
           in
           (*
                 Call CPPM default entrypoint with parameter Unit.
                 This is necessary for the CPMM's xtz_pool in storage to
                 increase since it cannot use BALANCE due to a transfer attack.

                 Mimicks a transaction.

                 There is no:
                 - storage burn (extra storage is free)
                 - fees (the operation is mandatory)
          *)
           Script_interpreter.execute_with_typed_parameter
             ctxt
             Optimized
             step_constants
             ~script
             ~parameter:()
             ~parameter_ty:Unit_t
             ~cached_script:(Some script_ir)
             ~location:Micheline.dummy_location
             ~entrypoint:Entrypoint.default
             ~internal:false
           >>=? fun ( {
                        script = updated_cached_script;
                        code_size = updated_size;
                        storage;
                        lazy_storage_diff;
                        operations;
                        ticket_diffs;
                        ticket_receipt;
                      },
                      ctxt ) ->
           match operations with
           | _ :: _ ->
               (* No internal operations are expected here. Something bad may be happening. *)
               return (backtracking_ctxt, [])
           | [] ->
               (* update CPMM storage *)
               update_script_storage_and_ticket_balances
                 ctxt
                 ~self_contract:liquidity_baking_cpmm_contract
                 storage
                 lazy_storage_diff
                 ticket_diffs
                 operations
               >>=? fun (ticket_table_size_diff, ctxt) ->
               Fees.record_paid_storage_space
                 ctxt
                 liquidity_baking_cpmm_contract
               >>=? fun (ctxt, new_size, paid_storage_size_diff) ->
               Ticket_balance.adjust_storage_space
                 ctxt
                 ~storage_diff:ticket_table_size_diff
               >>=? fun (ticket_paid_storage_diff, ctxt) ->
               let consumed_gas =
                 Gas.consumed ~since:backtracking_ctxt ~until:ctxt
               in
               Script_cache.update
                 ctxt
                 cache_key
                 ( {script with storage = Script.lazy_expr storage},
                   updated_cached_script )
                 updated_size
               >>?= fun ctxt ->
               let result =
                 Transaction_result
                   (Transaction_to_contract_result
                      {
                        storage = Some storage;
                        lazy_storage_diff;
                        balance_updates;
                        ticket_receipt;
                        (* At this point in application the
                           origination nonce has not been initialized
                           so it's not possible to originate new
                           contracts. We've checked above that none
                           were originated. *)
                        originated_contracts = [];
                        consumed_gas;
                        storage_size = new_size;
                        paid_storage_size_diff =
                          Z.add paid_storage_size_diff ticket_paid_storage_diff;
                        allocated_destination_contract = false;
                      })
               in
               let ctxt = Gas.set_unlimited ctxt in
               return (ctxt, [Successful_manager_result result])))
      >|= function
      | Ok (ctxt, results) -> Ok (ctxt, results)
      | Error _ ->
          (* Do not fail if something bad happens during CPMM contract call. *)
          let ctxt = Gas.set_unlimited backtracking_ctxt in
          Ok (ctxt, []))

let are_endorsements_required ctxt ~level =
  First_level_of_protocol.get ctxt >|=? fun first_level ->
  (* NB: the first level is the level of the migration block. There
     are no endorsements for this block. Therefore the block at the
     next level cannot contain endorsements. *)
  let level_position_in_protocol = Raw_level.diff level first_level in
  Compare.Int32.(level_position_in_protocol > 1l)

let record_endorsing_participation ctxt =
  let validators = Consensus.allowed_endorsements ctxt in
  Slot.Map.fold_es
    (fun initial_slot ((consensus_pk : Consensus_key.pk), power) ctxt ->
      let participation =
        if Slot.Set.mem initial_slot (Consensus.endorsements_seen ctxt) then
          Delegate.Participated
        else Delegate.Didn't_participate
      in
      Delegate.record_endorsing_participation
        ctxt
        ~delegate:consensus_pk.delegate
        ~participation
        ~endorsing_power:power)
    validators
    ctxt

let begin_application ctxt chain_id ~migration_balance_updates
    ~migration_operation_results ~(predecessor_fitness : Fitness.raw)
    (block_header : Block_header.t) : application_state tzresult Lwt.t =
  let open Lwt_tzresult_syntax in
  let*? fitness = Fitness.from_raw block_header.shell.fitness in
  let level = block_header.shell.level in
  let*? predecessor_round = Fitness.round_from_raw predecessor_fitness in
  let*? predecessor_level = Raw_level.of_int32 (Int32.pred level) in
  let predecessor_level = Level.from_raw ctxt predecessor_level in
  let round = Fitness.round fitness in
  let current_level = Level.current ctxt in
  let* ctxt, _slot, block_producer =
    Stake_distribution.baking_rights_owner ctxt current_level ~round
  in
  let* ctxt, _slot, payload_producer =
    Stake_distribution.baking_rights_owner
      ctxt
      current_level
      ~round:block_header.protocol_data.contents.payload_round
  in
  let toggle_vote =
    block_header.Block_header.protocol_data.contents
      .liquidity_baking_toggle_vote
  in
  let* ctxt, liquidity_baking_operations_results, liquidity_baking_toggle_ema =
    apply_liquidity_baking_subsidy ctxt ~toggle_vote
  in
  let mode =
    Application
      {
        block_header;
        fitness;
        predecessor_round;
        predecessor_level;
        payload_producer = Consensus_key.pkh payload_producer;
        block_producer = Consensus_key.pkh block_producer;
      }
  in
  return
    {
      mode;
      chain_id;
      ctxt;
      op_count = 0;
      migration_balance_updates;
      liquidity_baking_toggle_ema;
      implicit_operations_results =
        Apply_results.pack_migration_operation_results
          migration_operation_results
        @ liquidity_baking_operations_results;
    }

let begin_full_construction ctxt chain_id ~migration_balance_updates
    ~migration_operation_results ~predecessor_timestamp ~predecessor_level
    ~predecessor_round ~predecessor_hash ~timestamp
    (block_data_contents : Block_header.contents) =
  let open Lwt_tzresult_syntax in
  let round_durations = Constants.round_durations ctxt in
  let*? round =
    Round.round_of_timestamp
      round_durations
      ~predecessor_timestamp
      ~predecessor_round
      ~timestamp
  in
  (* The endorsement/preendorsement validation rules for construction are the
     same as for application. *)
  let current_level = Level.current ctxt in
  let* ctxt, _slot, block_producer =
    Stake_distribution.baking_rights_owner ctxt current_level ~round
  in
  let* ctxt, _slot, payload_producer =
    Stake_distribution.baking_rights_owner
      ctxt
      current_level
      ~round:block_data_contents.payload_round
  in
  let toggle_vote = block_data_contents.liquidity_baking_toggle_vote in
  let* ctxt, liquidity_baking_operations_results, liquidity_baking_toggle_ema =
    apply_liquidity_baking_subsidy ctxt ~toggle_vote
  in
  let mode =
    Full_construction
      {
        block_data_contents;
        predecessor_hash;
        payload_producer = Consensus_key.pkh payload_producer;
        block_producer = Consensus_key.pkh block_producer;
        round;
        predecessor_round;
        predecessor_level;
      }
  in
  return
    {
      mode;
      chain_id;
      ctxt;
      op_count = 0;
      migration_balance_updates;
      liquidity_baking_toggle_ema;
      implicit_operations_results =
        Apply_results.pack_migration_operation_results
          migration_operation_results
        @ liquidity_baking_operations_results;
    }

let begin_partial_construction ctxt chain_id ~migration_balance_updates
    ~migration_operation_results ~predecessor_level
    ~(predecessor_fitness : Fitness.raw) : application_state tzresult Lwt.t =
  let open Lwt_tzresult_syntax in
  let toggle_vote = Liquidity_baking.LB_pass in
  let* ctxt, liquidity_baking_operations_results, liquidity_baking_toggle_ema =
    apply_liquidity_baking_subsidy ctxt ~toggle_vote
  in
  let mode = Partial_construction {predecessor_level; predecessor_fitness} in
  return
    {
      mode;
      chain_id;
      ctxt;
      op_count = 0;
      migration_balance_updates;
      liquidity_baking_toggle_ema;
      implicit_operations_results =
        Apply_results.pack_migration_operation_results
          migration_operation_results
        @ liquidity_baking_operations_results;
    }

let finalize_application ctxt block_data_contents ~round ~predecessor_hash
    ~liquidity_baking_toggle_ema ~implicit_operations_results
    ~migration_balance_updates ~(block_producer : Consensus_key.t)
    ~(payload_producer : Consensus_key.t) =
  let open Lwt_tzresult_syntax in
  let level = Level.current ctxt in
  let endorsing_power = Consensus.current_endorsement_power ctxt in
  let* required_endorsements =
    are_endorsements_required ctxt ~level:level.level
  in
  let block_payload_hash =
    Block_payload.hash
      ~predecessor_hash
      ~payload_round:block_data_contents.Block_header.payload_round
      (non_consensus_operations ctxt)
  in
  (* from this point nothing should fail *)
  (* We mark the endorsement branch as the grand parent branch when
     accessible. This will not be present before the first two blocks
     of tenderbake. *)
  let level = Level.current ctxt in
  let*! ctxt =
    match Consensus.endorsement_branch ctxt with
    | Some predecessor_branch ->
        Consensus.store_grand_parent_branch ctxt predecessor_branch
    | None -> Lwt.return ctxt
  in
  (* We mark the current payload hash as the predecessor one => this
     will only be accessed by the successor block now. *)
  let*! ctxt =
    Consensus.store_endorsement_branch
      ctxt
      (predecessor_hash, block_payload_hash)
  in
  let* ctxt = Round.update ctxt round in
  (* end of level  *)
  let* ctxt =
    match block_data_contents.Block_header.seed_nonce_hash with
    | None -> return ctxt
    | Some nonce_hash ->
        Nonce.record_hash ctxt {nonce_hash; delegate = block_producer.delegate}
  in
  let* ctxt, reward_bonus =
    if required_endorsements then
      let* ctxt = record_endorsing_participation ctxt in
      let*? rewards_bonus = Baking.bonus_baking_reward ctxt ~endorsing_power in
      return (ctxt, Some rewards_bonus)
    else return (ctxt, None)
  in
  let baking_reward = Constants.baking_reward_fixed_portion ctxt in
  let* ctxt, baking_receipts =
    Delegate.record_baking_activity_and_pay_rewards_and_fees
      ctxt
      ~payload_producer:payload_producer.delegate
      ~block_producer:block_producer.delegate
      ~baking_reward
      ~reward_bonus
  in
  (* if end of nonce revelation period, compute seed *)
  let* ctxt =
    if Level.may_compute_randao ctxt then Seed.compute_randao ctxt
    else return ctxt
  in
  let* ctxt =
    if Level.may_snapshot_stake_distribution ctxt then
      Stake_distribution.snapshot ctxt
    else return ctxt
  in
  let* ctxt, cycle_end_balance_updates, deactivated =
    may_start_new_cycle ctxt
  in
  let* ctxt = Amendment.may_start_new_voting_period ctxt in
  let* ctxt, dal_slot_availability = Dal_apply.dal_finalisation ctxt in
  let balance_updates =
    migration_balance_updates @ baking_receipts @ cycle_end_balance_updates
  in
  let consumed_gas =
    Gas.Arith.sub
      (Gas.Arith.fp @@ Constants.hard_gas_limit_per_block ctxt)
      (Gas.block_level ctxt)
  in
  let+ voting_period_info = Voting_period.get_rpc_current_info ctxt in
  let receipt =
    Apply_results.
      {
        proposer = payload_producer;
        baker = block_producer;
        level_info = level;
        voting_period_info;
        nonce_hash = block_data_contents.seed_nonce_hash;
        consumed_gas;
        deactivated;
        balance_updates;
        liquidity_baking_toggle_ema;
        implicit_operations_results;
        dal_slot_availability;
      }
  in
  (ctxt, receipt)

type error += Missing_shell_header

let () =
  register_error_kind
    `Permanent
    ~id:"apply.missing_shell_header"
    ~title:"Missing shell_header during finalisation of a block"
    ~description:
      "During finalisation of a block header in Application mode or Full \
       construction mode, a shell header should be provided so that a cache \
       nonce can be computed."
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "No shell header provided during the finalisation of a block.")
    Data_encoding.unit
    (function Missing_shell_header -> Some () | _ -> None)
    (fun () -> Missing_shell_header)

let finalize_with_commit_message ctxt ~cache_nonce fitness round op_count =
  let open Lwt_syntax in
  let* ctxt = Cache.Admin.sync ctxt cache_nonce in
  let raw_level = Raw_level.to_int32 (Level.current ctxt).level in
  let commit_message =
    Format.asprintf
      "lvl %ld, fit:%a, round %a, %d ops"
      raw_level
      Fitness.pp
      fitness
      Round.pp
      round
      op_count
  in
  let validation_result =
    finalize ~commit_message ctxt (Fitness.to_raw fitness)
  in
  return validation_result

let finalize_block (application_state : application_state) shell_header_opt =
  let open Lwt_tzresult_syntax in
  let {
    ctxt;
    liquidity_baking_toggle_ema;
    implicit_operations_results;
    migration_balance_updates;
    op_count;
    _;
  } =
    application_state
  in
  match application_state.mode with
  | Full_construction
      {
        block_data_contents;
        predecessor_hash;
        predecessor_level = _;
        predecessor_round;
        block_producer;
        payload_producer;
        round;
      } ->
      let*? (shell_header : Block_header.shell_header) =
        Option.value_e
          shell_header_opt
          ~error:(Error_monad.trace_of_error Missing_shell_header)
      in
      let cache_nonce =
        Cache.cache_nonce_from_block_header shell_header block_data_contents
      in
      let locked_round_evidence =
        Option.map
          (fun (preendorsement_round, preendorsement_count) ->
            Block_header.{preendorsement_round; preendorsement_count})
          (Consensus.locked_round_evidence ctxt)
      in
      let locked_round =
        match locked_round_evidence with
        | None -> None
        | Some {preendorsement_round; _} -> Some preendorsement_round
      in
      let level = (Level.current ctxt).level in
      let*? fitness =
        Fitness.create ~level ~round ~predecessor_round ~locked_round
      in
      let* ctxt, receipt =
        finalize_application
          ctxt
          block_data_contents
          ~round
          ~predecessor_hash
          ~liquidity_baking_toggle_ema
          ~implicit_operations_results
          ~migration_balance_updates
          ~block_producer
          ~payload_producer
      in
      let*! result =
        finalize_with_commit_message ctxt ~cache_nonce fitness round op_count
      in
      return (result, receipt)
  | Partial_construction {predecessor_fitness; _} ->
      let* voting_period_info = Voting_period.get_rpc_current_info ctxt in
      let level_info = Level.current ctxt in
      let result = finalize ctxt predecessor_fitness in
      return
        ( result,
          Apply_results.
            {
              proposer = Consensus_key.zero;
              baker = Consensus_key.zero;
              level_info;
              voting_period_info;
              nonce_hash = None;
              consumed_gas = Gas.Arith.zero;
              deactivated = [];
              balance_updates = migration_balance_updates;
              liquidity_baking_toggle_ema;
              implicit_operations_results;
              dal_slot_availability = None;
            } )
  | Application
      {
        fitness;
        block_header = {shell; protocol_data};
        payload_producer;
        block_producer;
        _;
      } ->
      let round = Fitness.round fitness in
      let cache_nonce =
        Cache.cache_nonce_from_block_header shell protocol_data.contents
      in
      let* ctxt, receipt =
        finalize_application
          ctxt
          protocol_data.contents
          ~round
          ~predecessor_hash:shell.predecessor
          ~liquidity_baking_toggle_ema
          ~implicit_operations_results
          ~migration_balance_updates
          ~block_producer
          ~payload_producer
      in
      let*! result =
        finalize_with_commit_message ctxt ~cache_nonce fitness round op_count
      in
      return (result, receipt)

let value_of_key ctxt k = Cache.Admin.value_of_key ctxt k
