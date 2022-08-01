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

(*
  To patch code of legacy contracts you can add a helper function here and call
  it at the end of prepare_first_block.

  See !3730 for an example.
*)

module Patch_dictator_for_ghostnet = struct
  let ghostnet_id =
    let id = Chain_id.of_b58check_exn "NetXnHfVqm9iesp" in
    if Chain_id.equal id Constants_repr.mainnet_id then assert false else id

  let oxhead_testnet_baker =
    Signature.Public_key_hash.of_b58check_exn
      "tz1Xf8zdT3DbAX9cHw3c3CXh79rc4nK4gCe8"

  let patch_constant chain_id ctxt =
    if Chain_id.equal chain_id ghostnet_id then
      Raw_context.patch_constants ctxt (fun c ->
          {
            c with
            testnet_dictator = Some oxhead_testnet_baker;
            cycles_per_voting_period = 1l;
          })
    else Lwt.return ctxt
end

let prepare_first_block chain_id ctxt ~typecheck ~level ~timestamp =
  Raw_context.prepare_first_block ~level ~timestamp ctxt
  >>=? fun (previous_protocol, ctxt) ->
  let parametric = Raw_context.constants ctxt in
  ( Raw_context.Cache.set_cache_layout
      ctxt
      (Constants_repr.cache_layout parametric)
  >|= fun ctxt -> Raw_context.Cache.clear ctxt )
  >>= fun ctxt ->
  (match previous_protocol with
  | Genesis param ->
      (* This is the genesis protocol: initialise the state *)
      Raw_level_repr.of_int32 level >>?= fun level ->
      Storage.Tenderbake.First_level_of_protocol.init ctxt level
      >>=? fun ctxt ->
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
  | Jakarta_013 ->
      (* TODO (#2704): possibly handle endorsements for migration block (in bakers);
         if that is done, do not set Storage.Tenderbake.First_level_of_protocol. *)
      Raw_level_repr.of_int32 level >>?= fun level ->
      Storage.Tenderbake.First_level_of_protocol.update ctxt level
      >>=? fun ctxt ->
      Patch_dictator_for_ghostnet.patch_constant chain_id ctxt >>= fun ctxt ->
      invoice_contract
        ctxt
        ~address:"tz1X81bCXPtMiHu1d4UZF4GPhMPkvkp56ssb"
        ~amount_mutez:3_000_000_000L
      >>= fun (ctxt, balance_updates) -> return (ctxt, balance_updates))
  >>=? fun (ctxt, balance_updates) ->
  Receipt_repr.group_balance_updates balance_updates >>?= fun balance_updates ->
  Storage.Pending_migration.Balance_updates.add ctxt balance_updates
  >>= fun ctxt -> return ctxt

let prepare ctxt ~level ~predecessor_timestamp ~timestamp =
  Raw_context.prepare ~level ~predecessor_timestamp ~timestamp ctxt
  >>=? fun ctxt -> Storage.Pending_migration.remove ctxt
