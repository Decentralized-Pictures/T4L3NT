(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>           *)
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

(** Testing
    -------
    Component:  Protocol (token)
    Invocation: dune exec \
                src/proto_alpha/lib_protocol/test/integration/main.exe \
                -- test "^frozen bonds"
    Subject:    Frozen bonds applicable to contracts and part of their stake.
*)

open Protocol
open Alpha_context
open Test_tez

let ( >>>=? ) x f = x >|= Environment.wrap_tzresult >>=? f

let big_random_amount () =
  match Tez.of_mutez (Int64.add 1L (Random.int64 10_000L)) with
  | None -> assert false
  | Some x -> x

let small_random_amount () =
  match Tez.of_mutez (Int64.add 1L (Random.int64 1_000L)) with
  | None -> assert false
  | Some x -> x

let very_small_random_amount () =
  match Tez.of_mutez (Int64.add 1L (Random.int64 100L)) with
  | None -> assert false
  | Some x -> x

let nonce_zero =
  Origination_nonce.Internal_for_tests.initial Operation_hash.zero

let mk_tx_rollup ?(nonce = nonce_zero) () =
  ( Tx_rollup.Internal_for_tests.originated_tx_rollup nonce,
    Origination_nonce.Internal_for_tests.incr nonce )

(** Creates a context with a single account. Returns the context and the public
    key hash of the account. *)
let create_context () =
  let accounts = Account.generate_accounts 1 in
  Block.alpha_context accounts >>=? fun ctxt ->
  match accounts with
  | [({pkh; _}, _)] -> return (ctxt, pkh)
  | _ -> (* Exactly one account has been generated. *) assert false

(** Creates a context, a user contract, and a delegate.
    Returns the context, the user contract, the user account, and the
    delegate's pkh. *)
let init_test ~user_is_delegate =
  create_context () >>=? fun (ctxt, _) ->
  let (delegate, delegate_pk, _) = Signature.generate_key () in
  let delegate_contract = Contract.implicit_contract delegate in
  let delegate_account = `Contract (Contract.implicit_contract delegate) in
  let user_contract =
    if user_is_delegate then delegate_contract
    else
      let (user, _, _) = Signature.generate_key () in
      Contract.implicit_contract user
  in
  let user_account = `Contract user_contract in
  (* Allocate contracts for user and delegate. *)
  let user_balance = big_random_amount () in
  Token.transfer ctxt `Minted user_account user_balance >>>=? fun (ctxt, _) ->
  let delegate_balance = big_random_amount () in
  Token.transfer ctxt `Minted delegate_account delegate_balance
  >>>=? fun (ctxt, _) ->
  (* Configure delegate, as a delegate by self-delegation, for which
     revealing its manager key is a prerequisite. *)
  Contract.reveal_manager_key ctxt delegate delegate_pk >>>=? fun ctxt ->
  Delegate.set ctxt delegate_contract (Some delegate) >>>=? fun ctxt ->
  return (ctxt, user_contract, user_account, delegate)

(** Tested scenario :
    1. user contract delegates to 'delegate',
    2. freeze a deposit,
    3. check that staking balance of delegate has not changed,
    4. remove delegation,
    5. check staking balance decreased accordingly,
    6. unfreeze the deposit,
    7. check that staking balance is unchanged,
    8. check that user's balance is unchanged. *)
let test_delegate_then_freeze_deposit () =
  init_test ~user_is_delegate:false
  >>=? fun (ctxt, user_contract, user_account, delegate) ->
  (* Fetch user's initial balance before freeze. *)
  Token.balance ctxt user_account >>>=? fun (ctxt, user_balance) ->
  (* Let user delegate to "delegate". *)
  Delegate.set ctxt user_contract (Some delegate) >>>=? fun ctxt ->
  (* Fetch staking balance after delegation and before freeze. *)
  Delegate.staking_balance ctxt delegate >>>=? fun staking_balance ->
  (* Freeze a tx-rollup deposit. *)
  let (tx_rollup, _) = mk_tx_rollup () in
  let bond_id = Bond_id.Tx_rollup_bond_id tx_rollup in
  let deposit_amount = small_random_amount () in
  let deposit_account = `Frozen_bonds (user_contract, bond_id) in
  Token.transfer ctxt user_account deposit_account deposit_amount
  >>>=? fun (ctxt, _) ->
  (* Fetch staking balance after freeze. *)
  Delegate.staking_balance ctxt delegate >>>=? fun staking_balance' ->
  (* Ensure staking balance did not change. *)
  Assert.equal_tez ~loc:__LOC__ staking_balance' staking_balance >>=? fun () ->
  (* Remove delegation. *)
  Delegate.set ctxt user_contract None >>>=? fun ctxt ->
  (* Fetch staking balance after delegation removal. *)
  Delegate.staking_balance ctxt delegate >>>=? fun staking_balance'' ->
  (* Ensure staking balance decreased by user's initial balance. *)
  Assert.equal_tez
    ~loc:__LOC__
    staking_balance''
    (staking_balance' -! user_balance)
  >>=? fun () ->
  (* Unfreeze the deposit. *)
  Token.transfer ctxt deposit_account user_account deposit_amount
  >>>=? fun (ctxt, _) ->
  (* Fetch staking balance of delegate. *)
  Delegate.staking_balance ctxt delegate >>>=? fun staking_balance''' ->
  (* Ensure that staking balance is unchanged. *)
  Assert.equal_tez ~loc:__LOC__ staking_balance''' staking_balance''
  >>=? fun () ->
  (* Fetch user's balance again. *)
  Token.balance ctxt user_account >>>=? fun (_, user_balance') ->
  (* Ensure user's balance decreased. *)
  Assert.equal_tez ~loc:__LOC__ user_balance' user_balance

(** Tested scenario:
    1. freeze a deposit,
    2. user contract delegate to 'delegate',
    3. check that staking balance of delegate has increased as expected,
    4. unfreeze the deposit,
    5. check that staking balance has not changed,
    6. remove delegation,
    7. check that staking balance has decreased as expected,
    8. check that the user's balance is unchanged. *)
let test_freeze_deposit_then_delegate () =
  init_test ~user_is_delegate:false
  >>=? fun (ctxt, user_contract, user_account, delegate) ->
  (* Fetch user's initial balance before freeze. *)
  Token.balance ctxt user_account >>>=? fun (ctxt, user_balance) ->
  (* Freeze a tx-rollup deposit. *)
  let (tx_rollup, _) = mk_tx_rollup () in
  let bond_id = Bond_id.Tx_rollup_bond_id tx_rollup in
  let deposit_amount = small_random_amount () in
  let deposit_account = `Frozen_bonds (user_contract, bond_id) in
  Token.transfer ctxt user_account deposit_account deposit_amount
  >>>=? fun (ctxt, _) ->
  (* Here, user balance has decreased.
     Now, fetch staking balance before delegation and after freeze. *)
  Delegate.staking_balance ctxt delegate >>>=? fun staking_balance ->
  (* Let user delegate to "delegate". *)
  Delegate.set ctxt user_contract (Some delegate) >>>=? fun ctxt ->
  (* Fetch staking balance after delegation. *)
  Delegate.staking_balance ctxt delegate >>>=? fun staking_balance' ->
  (* ensure staking balance increased by the user's balance. *)
  Assert.equal_tez
    ~loc:__LOC__
    staking_balance'
    (user_balance +! staking_balance)
  >>=? fun () ->
  (* Unfreeze the deposit. *)
  Token.transfer ctxt deposit_account user_account deposit_amount
  >>>=? fun (ctxt, _) ->
  (* Fetch staking balance after unfreeze. *)
  Delegate.staking_balance ctxt delegate >>>=? fun staking_balance'' ->
  (* Ensure that staking balance is unchanged. *)
  Assert.equal_tez ~loc:__LOC__ staking_balance'' staking_balance'
  >>=? fun () ->
  (* Remove delegation. *)
  Delegate.set ctxt user_contract None >>>=? fun ctxt ->
  (* Fetch staking balance. *)
  Delegate.staking_balance ctxt delegate >>>=? fun staking_balance''' ->
  (* Check that staking balance has decreased by the user's initial balance. *)
  Assert.equal_tez
    ~loc:__LOC__
    staking_balance'''
    (staking_balance'' -! user_balance)
  >>=? fun () ->
  (* Fetch user's balance. *)
  Token.balance ctxt user_account >>>=? fun (_, user_balance') ->
  (* Ensure user's balance decreased. *)
  Assert.equal_tez ~loc:__LOC__ user_balance' user_balance

(** Tested scenario:
    1. freeze a deposit (with deposit amount = balance),
    2. check that the user contract is still allocated,
    3. punish the user contract,
    4. check that the user contract is unallocated, except if it's a delegate. *)
let test_allocated_when_frozen_deposits_exists ~user_is_delegate () =
  init_test ~user_is_delegate
  >>=? fun (ctxt, user_contract, user_account, _delegate) ->
  (* Fetch user's initial balance before freeze. *)
  Token.balance ctxt user_account >>>=? fun (ctxt, user_balance) ->
  Assert.equal_bool ~loc:__LOC__ Tez.(user_balance > zero) true >>=? fun () ->
  (* Freeze a tx-rollup deposit. *)
  let (tx_rollup, _) = mk_tx_rollup () in
  let bond_id = Bond_id.Tx_rollup_bond_id tx_rollup in
  let deposit_amount = user_balance in
  let deposit_account = `Frozen_bonds (user_contract, bond_id) in
  Token.transfer ctxt user_account deposit_account deposit_amount
  >>>=? fun (ctxt, _) ->
  (* Check that user contract is still allocated, despite a null balance. *)
  Token.balance ctxt user_account >>>=? fun (ctxt, balance) ->
  Assert.equal_tez ~loc:__LOC__ balance Tez.zero >>=? fun () ->
  Token.allocated ctxt user_account >>>=? fun (ctxt, user_allocated) ->
  Token.allocated ctxt deposit_account >>>=? fun (ctxt, dep_allocated) ->
  Assert.equal_bool ~loc:__LOC__ (user_allocated && dep_allocated) true
  >>=? fun () ->
  (* Punish the user contract. *)
  Token.transfer ctxt deposit_account `Burned deposit_amount
  >>>=? fun (ctxt, _) ->
  (* Check that user and deposit accounts have been unallocated. *)
  Token.allocated ctxt user_account >>>=? fun (ctxt, user_allocated) ->
  Token.allocated ctxt deposit_account >>>=? fun (_, dep_allocated) ->
  if user_is_delegate then
    Assert.equal_bool ~loc:__LOC__ (user_allocated && not dep_allocated) true
  else Assert.equal_bool ~loc:__LOC__ (user_allocated || dep_allocated) false

(** Tested scenario:
    1. freeze two deposits for the user contract,
    2. check that the stake of the user contract is balance + two deposits,
    3. punish for one of the deposits,
    4. check that the stake of the user contract balance + deposit,
    5. punish for the other deposit,
    6. check that the stake of the user contract is equal to balance. *)
let test_total_stake ~user_is_delegate () =
  init_test ~user_is_delegate
  >>=? fun (ctxt, user_contract, user_account, _delegate) ->
  (* Fetch user's initial balance before freeze. *)
  Token.balance ctxt user_account >>>=? fun (ctxt, user_balance) ->
  Assert.equal_bool ~loc:__LOC__ Tez.(user_balance > zero) true >>=? fun () ->
  (* Freeze 2 tx-rollup deposits. *)
  let (tx_rollup, nonce) = mk_tx_rollup () in
  let bond_id1 = Bond_id.Tx_rollup_bond_id tx_rollup in
  let (tx_rollup, _) = mk_tx_rollup ~nonce () in
  let bond_id2 = Bond_id.Tx_rollup_bond_id tx_rollup in
  let deposit_amount = small_random_amount () in
  let deposit_account1 = `Frozen_bonds (user_contract, bond_id1) in
  Token.transfer ctxt user_account deposit_account1 deposit_amount
  >>>=? fun (ctxt, _) ->
  let deposit_account2 = `Frozen_bonds (user_contract, bond_id2) in
  Token.transfer ctxt user_account deposit_account2 deposit_amount
  >>>=? fun (ctxt, _) ->
  (* Test folding on bond ids. *)
  Bond_id.Internal_for_tests.fold_on_bond_ids
    ctxt
    user_contract
    ~init:[]
    ~order:`Sorted
    ~f:(fun id l -> Lwt.return (id :: l))
  >>= fun bond_ids ->
  Assert.assert_equal_list
    ~loc:__LOC__
    (fun id1 id2 -> Bond_id.compare id1 id2 = 0)
    "Unexpected bond identifiers."
    Bond_id.pp
    (List.sort Bond_id.compare bond_ids)
    (List.sort Bond_id.compare [bond_id1; bond_id2])
  >>=? fun () ->
  (* Check that the stake of user contract is balance + two deposits. *)
  Contract.get_balance_and_frozen_bonds ctxt user_contract >>>=? fun stake ->
  Contract.get_frozen_bonds ctxt user_contract >>>=? fun frozen_bonds ->
  Token.balance ctxt user_account >>>=? fun (ctxt, balance) ->
  Assert.equal_tez ~loc:__LOC__ (stake -! balance) frozen_bonds >>=? fun () ->
  Assert.equal_tez ~loc:__LOC__ (stake -! balance) (deposit_amount *! 2L)
  >>=? fun () ->
  (* Punish for one deposit. *)
  Token.transfer ctxt deposit_account2 `Burned deposit_amount
  >>>=? fun (ctxt, _) ->
  (* Check that stake of contract is balance + deposit. *)
  Contract.get_balance_and_frozen_bonds ctxt user_contract >>>=? fun stake ->
  Contract.get_frozen_bonds ctxt user_contract >>>=? fun frozen_bonds ->
  Assert.equal_tez ~loc:__LOC__ (stake -! balance) frozen_bonds >>=? fun () ->
  Assert.equal_tez ~loc:__LOC__ (stake -! balance) deposit_amount >>=? fun () ->
  (* Punish for the other deposit. *)
  Token.transfer ctxt deposit_account1 `Burned deposit_amount
  >>>=? fun (ctxt, _) ->
  (* Check that stake of contract is equal to balance. *)
  Contract.get_balance_and_frozen_bonds ctxt user_contract >>>=? fun stake ->
  Assert.equal_tez ~loc:__LOC__ stake balance

(** Tests that the rpcs [contract/pkh/frozen_bonds] and
    [contract/pkh/balance_and_frozen_bonds] can be called successfully.
    These rpcs call the functions [Contract.get_frozen_bonds] and
    [Contract.get_balance_and_frozen_bonds] already tested in previous tests. *)
let test_rpcs () =
  Context.init 1 >>=? fun (blk, contracts) ->
  match contracts with
  | [contract] ->
      Context.Contract.frozen_bonds (B blk) contract >>=? fun frozen_bonds ->
      Assert.equal_tez ~loc:__LOC__ frozen_bonds Tez.zero >>=? fun () ->
      Context.Contract.balance_and_frozen_bonds (B blk) contract
      >>=? fun balance_and_frozen_bonds ->
      Context.Contract.balance (B blk) contract >>=? fun balance ->
      Assert.equal_tez ~loc:__LOC__ balance_and_frozen_bonds balance
  | _ -> (* Exactly one account has been generated. *) assert false

let tests =
  Tztest.
    [
      tztest
        "frozen bonds - delegate then freeze"
        `Quick
        test_delegate_then_freeze_deposit;
      tztest
        "frozen bonds - freeze then delegate"
        `Quick
        test_freeze_deposit_then_delegate;
      tztest
        "frozen bonds - contract remains allocated, user is not a delegate"
        `Quick
        (test_allocated_when_frozen_deposits_exists ~user_is_delegate:false);
      tztest
        "frozen bonds - contract remains allocated, user is a delegate"
        `Quick
        (test_allocated_when_frozen_deposits_exists ~user_is_delegate:true);
      tztest
        "frozen bonds - total stake, user is not a delegate"
        `Quick
        (test_total_stake ~user_is_delegate:false);
      tztest
        "frozen bonds - total stake, user is a delegate"
        `Quick
        (test_total_stake ~user_is_delegate:true);
      tztest "frozen bonds - test rpcs" `Quick test_rpcs;
    ]
