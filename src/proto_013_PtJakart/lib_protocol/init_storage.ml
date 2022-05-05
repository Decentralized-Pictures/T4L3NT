(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2019-2020 Nomadic Labs <contact@nomadic-labs.com>           *)
(* Copyright (c) 2021 DaiLambda, Inc. <contact@dailambda.jp>                 *)
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

module Patch_legacy_contracts_for_J = struct
  let patch_script (address, legacy_script_hash, patched_code) ctxt =
    Contract_repr.of_b58check address >>?= fun contract ->
    Storage.Contract.Code.find ctxt contract >>=? fun (ctxt, code_opt) ->
    Logging.log Notice "Patching %s... " address ;
    match code_opt with
    | Some old_code ->
        let old_bin = Data_encoding.force_bytes old_code in
        let old_hash = Script_expr_hash.hash_bytes [old_bin] in
        if Script_expr_hash.equal old_hash legacy_script_hash then (
          let new_code = Script_repr.lazy_expr patched_code in
          Logging.log Notice "Contract %s successfully patched" address ;
          Storage.Contract.Code.update ctxt contract new_code
          >>=? fun (ctxt, size_diff) ->
          let size_diff = Z.of_int size_diff in
          Storage.Contract.Used_storage_space.get ctxt contract
          >>=? fun prev_size ->
          let new_size = Z.add prev_size size_diff in
          Storage.Contract.Used_storage_space.update ctxt contract new_size
          >>=? fun ctxt ->
          if Z.(gt size_diff zero) then
            Storage.Contract.Paid_storage_space.get ctxt contract
            >>=? fun prev_paid_size ->
            let paid_size = Z.add prev_paid_size size_diff in
            Storage.Contract.Paid_storage_space.update ctxt contract paid_size
          else return ctxt)
        else (
          Logging.log
            Error
            "Patching %s was skipped because its script does not have the \
             expected hash (expected: %a, found: %a)"
            address
            Script_expr_hash.pp
            legacy_script_hash
            Script_expr_hash.pp
            old_hash ;
          return ctxt)
    | None ->
        Logging.log
          Error
          "Patching %s was skipped because no script was found for it in the \
           context."
          address ;
        return ctxt
end

(*
  To add invoices, you can use a helper function like this one:

  (** Invoice a contract at a given address with a given amount. Returns the
      updated context and a  balance update receipt (singleton list). The address
      must be a valid base58 hash, otherwise this is no-op and returns an empty
      receipts list.

      Do not fail if something goes wrong.
  *)
  let invoice_contract ctxt ~address ~amount_mutez =
    match Tez_repr.of_mutez amount_mutez with
    | None -> Lwt.return (ctxt, [])
    | Some amount -> (
        ( Contract_repr.of_b58check address >>?= fun recipient ->
          Token.transfer
            ~origin:Protocol_migration
            ctxt
            `Invoice
            (`Contract recipient)
            amount )
        >|= function
        | Ok res -> res
        | Error _ -> (ctxt, []))
*)

let prepare_first_block ctxt ~typecheck ~level ~timestamp =
  Raw_context.prepare_first_block ~level ~timestamp ctxt
  >>=? fun (previous_protocol, ctxt) ->
  let parametric = Raw_context.constants ctxt in
  ( Raw_context.Cache.set_cache_layout
      ctxt
      (Constants_repr.cache_layout parametric)
  >|= fun ctxt -> Raw_context.Cache.clear ctxt )
  >>= fun ctxt ->
  Raw_level_repr.of_int32 level >>?= fun level ->
  Storage.Tenderbake.First_level_of_protocol.init ctxt level >>=? fun ctxt ->
  (match previous_protocol with
  | Genesis param ->
      (* This is the genesis protocol: initialise the state *)
      Storage.Block_round.init ctxt Round_repr.zero >>=? fun ctxt ->
      let init_commitment (ctxt, balance_updates)
          Commitment_repr.{blinded_public_key_hash; amount} =
        Token.transfer
          ctxt
          `Initial_commitments
          (`Collected_commitments blinded_public_key_hash)
          amount
        >>=? fun (ctxt, new_balance_updates) ->
        return (ctxt, new_balance_updates @ balance_updates)
      in
      List.fold_left_es init_commitment (ctxt, []) param.commitments
      >>=? fun (ctxt, commitments_balance_updates) ->
      Storage.Stake.Last_snapshot.init ctxt 0 >>=? fun ctxt ->
      Seed_storage.init ?initial_seed:param.constants.initial_seed ctxt
      >>=? fun ctxt ->
      Contract_storage.init ctxt >>=? fun ctxt ->
      Bootstrap_storage.init
        ctxt
        ~typecheck
        ?no_reward_cycles:param.no_reward_cycles
        param.bootstrap_accounts
        param.bootstrap_contracts
      >>=? fun (ctxt, bootstrap_balance_updates) ->
      Delegate_storage.init_first_cycles ctxt >>=? fun ctxt ->
      let cycle = (Raw_context.current_level ctxt).cycle in
      Delegate_storage.freeze_deposits_do_not_call_except_for_migration
        ~new_cycle:cycle
        ~balance_updates:[]
        ctxt
      >>=? fun (ctxt, deposits_balance_updates) ->
      Vote_storage.init
        ctxt
        ~start_position:(Level_storage.current ctxt).level_position
      >>=? fun ctxt ->
      Vote_storage.update_listings ctxt >>=? fun ctxt ->
      (* Must be called after other originations since it unsets the origination nonce. *)
      Liquidity_baking_migration.init ctxt ~typecheck
      >>=? fun (ctxt, operation_results) ->
      Storage.Pending_migration.Operation_results.init ctxt operation_results
      >>=? fun ctxt ->
      return
        ( ctxt,
          commitments_balance_updates @ bootstrap_balance_updates
          @ deposits_balance_updates )
  | Ithaca_012 ->
      (* TODO (#2704): possibly handle endorsements for migration block (in bakers);
         if that is done, do not set Storage.Tenderbake.First_level_of_protocol. *)
      Storage.Vote.Legacy_listings_size.remove ctxt >>= fun ctxt ->
      Vote_storage.update_listings ctxt >>=? fun ctxt ->
      Liquidity_baking_migration.Migration_from_Ithaca.update ctxt
      >>=? fun ctxt -> return (ctxt, []))
  >>=? fun (ctxt, balance_updates) ->
  Storage.Tenderbake.First_level_legacy.remove ctxt >>= fun ctxt ->
  Receipt_repr.group_balance_updates balance_updates >>?= fun balance_updates ->
  Storage.Pending_migration.Balance_updates.add ctxt balance_updates
  >>= fun ctxt ->
  List.fold_right_es
    Patch_legacy_contracts_for_J.patch_script
    Legacy_script_patches_for_J.addresses_to_patch
    ctxt
  >>=? fun ctxt -> return ctxt

let prepare ctxt ~level ~predecessor_timestamp ~timestamp =
  Raw_context.prepare ~level ~predecessor_timestamp ~timestamp ctxt
  >>=? fun ctxt -> Storage.Pending_migration.remove ctxt
