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

(** Testing
    -------
    Component:  Protocol (transfer)
    Invocation: dune exec \
                src/proto_alpha/lib_protocol/test/integration/operations/main.exe \
                -- test "^transfer$"
    Subject:    Quantities transfer between contracts.
*)

open Protocol
open Alpha_context
open Test_tez
open Transfers

(*********************************************************************)
(* Utility functions                                                 *)
(*********************************************************************)

(**
   [transfer_to_itself_and_check_balances b fee contract amount]
   this function takes a block, an optional parameter fee,
   a contract that is a source and a destination contract,
   and an amount of tez that one wants to transfer.

   1- Transfer the amount of tez (w/wo transfer fee) from/to a contract itself.

   2- Check the equivalent of the balance of the contract before
       and after transfer.

   This function returns a pair:
   - a block that added the valid transaction
   - an valid transaction *)
let transfer_to_itself_and_check_balances ~loc ?policy b ?(fee = Tez.zero)
    contract amount =
  Context.Contract.balance (B b) contract >>=? fun bal ->
  Op.transaction (B b) ~fee contract contract amount >>=? fun operation ->
  Block.bake ?policy ~operation b >>=? fun b ->
  Assert.balance_was_debited ~loc (B b) contract bal fee >|=? fun () ->
  (b, operation)

let ten_tez = of_int 10

(*********************************************************************)
(* Tests                                                             *)
(*********************************************************************)

(** Compute a fraction of 2/[n] of the balance of [contract] *)
let two_over_n_of_balance ctxt contract n =
  Context.Contract.balance ctxt contract >>=? fun balance ->
  Lwt.return (balance /? n >>? fun res -> res *? 2L)

(********************)
(** Single transfer *)

(********************)

let single_transfer ?fee ?expect_apply_failure amount =
  Context.init2 () >>=? fun (b, (contract_1, contract_2)) ->
  Incremental.begin_construction b >>=? fun b ->
  transfer_and_check_balances
    ~loc:__LOC__
    ?fee
    ?expect_apply_failure
    b
    contract_1
    contract_2
    amount
  >>=? fun (b, _) ->
  Incremental.finalize_block b >>=? fun _ -> return_unit

(** Single transfer without fee. *)
let test_block_with_a_single_transfer () = single_transfer Tez.one

(** Single transfer with fee. *)
let test_block_with_a_single_transfer_with_fee () =
  single_transfer ~fee:Tez.one Tez.one

(** Single transfer without fee. *)
let test_transfer_zero_tez () =
  let expect_apply_failure = function
    | Environment.Ecoproto_error (Apply.Empty_transaction _ as err) :: _ ->
        Assert.test_error_encodings err ;
        return_unit
    | _ -> failwith "Empty transaction should fail"
  in
  single_transfer ~expect_apply_failure Tez.zero

(** Transfer zero tez from an implicit contract. *)
let test_transfer_zero_implicit () =
  Context.init1 () >>=? fun (b, dest) ->
  let account = Account.new_account () in
  Incremental.begin_construction b >>=? fun i ->
  let src = Contract.Implicit account.Account.pkh in
  Op.transaction (I i) src dest Tez.zero >>=? fun op ->
  Incremental.add_operation i op >>= fun res ->
  Assert.proto_error ~loc:__LOC__ res (function
      | Contract_storage.Empty_implicit_contract _ as err ->
          Assert.test_error_encodings err ;
          true
      | _ -> false)

(** Transfer to originated contract. *)
let test_transfer_to_originate_with_fee () =
  Context.init1 ~consensus_threshold:0 () >>=? fun (b, contract) ->
  two_over_n_of_balance (B b) contract 10L >>=? fun fee ->
  (* originated contract, paying a fee to originated this contract *)
  Op.contract_origination (B b) ~fee:ten_tez contract ~script:Op.dummy_script
  >>=? fun (operation, new_contract) ->
  Block.bake ~operation b >>=? fun b ->
  two_over_n_of_balance (B b) contract 3L >>=? fun amount ->
  Incremental.begin_construction b >>=? fun i ->
  transfer_and_check_balances ~loc:__LOC__ i ~fee contract new_contract amount
  >>=? fun (i, _) ->
  Incremental.finalize_block i >>=? fun _ -> return_unit

(** Transfer from balance. *)
let test_transfer_amount_of_contract_balance () =
  Context.init2 () >>=? fun (b, (contract_1, contract_2)) ->
  let pkh1 = Context.Contract.pkh contract_1 in
  (* given that contract_1 no longer has a sufficient balance to bake,
     make sure it cannot be chosen as baker *)
  Incremental.begin_construction b ~policy:(Block.Excluding [pkh1])
  >>=? fun b ->
  (* get the balance of the source contract *)
  Context.Contract.balance (I b) contract_1 >>=? fun balance ->
  (* transfer all the tez inside contract 1 *)
  transfer_and_check_balances ~loc:__LOC__ b contract_1 contract_2 balance
  >>=? fun (b, _) ->
  Incremental.finalize_block b >>=? fun _ -> return_unit

(** Transfer to oneself. *)
let test_transfers_to_self () =
  Context.init2 ~consensus_threshold:0 () >>=? fun (b, (contract, _)) ->
  two_over_n_of_balance (B b) contract 3L >>=? fun amount ->
  let pkh1 = Context.Contract.pkh contract in
  transfer_to_itself_and_check_balances
    ~loc:__LOC__
    ~policy:(Block.Excluding [pkh1])
    b
    contract
    amount
  >>=? fun (b, _) ->
  two_over_n_of_balance (B b) contract 5L >>=? fun fee ->
  transfer_to_itself_and_check_balances
    ~loc:__LOC__
    b
    ~policy:(Block.Excluding [pkh1])
    ~fee
    contract
    ten_tez
  >>=? fun _ -> return_unit

(** Forgot to add the valid transaction into the block. *)
let test_missing_transaction () =
  Context.init2 ~consensus_threshold:0 ()
  >>=? fun (b, (contract_1, contract_2)) ->
  (* given that contract_1 no longer has a sufficient balance to bake,
     make sure it cannot be chosen as baker *)
  let pkh1 = Context.Contract.pkh contract_1 in
  Incremental.begin_construction b ~policy:(Block.Excluding [pkh1])
  >>=? fun i ->
  two_over_n_of_balance (B b) contract_1 6L >>=? fun amount ->
  (* Do the transfer 3 times from source contract to destination contract *)
  n_transactions 3 i contract_1 contract_2 amount >>=? fun i ->
  (* do the fourth transfer from source contract to destination contract *)
  Op.transaction (I i) contract_1 contract_2 amount >>=? fun _ ->
  Incremental.finalize_block i >>=? fun _ -> return_unit

(** Transfer zero tez to an implicit contract, with fee equals balance of src. *)
let test_transfer_zero_implicit_with_bal_src_as_fee () =
  Context.init1 ~consensus_threshold:0 () >>=? fun (b, dest) ->
  let account = Account.new_account () in
  let src_pkh = account.Account.pkh in
  let src = Contract.Implicit src_pkh in
  Op.transaction ~force_reveal:true (B b) dest src (Tez.of_mutez_exn 100L)
  >>=? fun operation ->
  Block.bake ~operation b >>=? fun b ->
  Context.Contract.balance (B b) src >>=? fun bal_src ->
  Assert.equal_tez ~loc:__LOC__ bal_src (Tez.of_mutez_exn 100L) >>=? fun () ->
  Op.transaction ~force_reveal:true (B b) ~fee:bal_src src dest Tez.zero
  >>=? fun op ->
  (* Transferring zero tez should result in an application failure as
     the implicit contract has been depleted. *)
  let expect_apply_failure = function
    | [
        Environment.Ecoproto_error (Contract_storage.Empty_implicit_contract pkh);
      ]
      when pkh = src_pkh ->
        return_unit
    | _ -> assert false
  in
  Incremental.begin_construction b >>=? fun i ->
  Incremental.add_operation ~expect_apply_failure i op >>=? fun inc ->
  Context.Contract.balance (I inc) src >>=? fun balance ->
  (* We assert that the failing operation was included and that the
     fees were taken, effectively depleting the contract. *)
  Assert.equal_tez ~loc:__LOC__ balance Tez.zero >>=? fun () ->
  (* Empty contracts should be unrevealed *)
  Context.Contract.is_manager_key_revealed (I inc) src >>=? fun revelead ->
  when_ revelead (fun () ->
      Stdlib.failwith "Empty account still exists and is revealed.")

(** Transfer zero tez to an originated contract, with fee equals balance of src. *)
let test_transfer_zero_to_originated_with_bal_src_as_fee () =
  Context.init1 ~consensus_threshold:0 () >>=? fun (b, dest) ->
  let account = Account.new_account () in
  let src = Contract.Implicit account.Account.pkh in
  Op.transaction (B b) dest src (Tez.of_mutez_exn 100L) >>=? fun operation ->
  Block.bake ~operation b >>=? fun b ->
  Op.contract_origination (B b) dest ~script:Op.dummy_script
  >>=? fun (operation, new_contract) ->
  Block.bake ~operation b >>=? fun b ->
  Context.Contract.balance (B b) src >>=? fun bal_src ->
  Op.revelation (B b) ~fee:Tez.zero account.pk >>=? fun operation ->
  Block.bake ~operation b >>=? fun b ->
  Op.transaction (B b) ~fee:bal_src src new_contract Tez.zero
  >>=? fun operation ->
  Assert.equal_tez ~loc:__LOC__ bal_src (Tez.of_mutez_exn 100L) >>=? fun () ->
  Block.bake ~operation b >>=? fun _ -> return_unit

(** Transfer one tez to an implicit contract, with fee equals balance of src. *)
let test_transfer_one_to_implicit_with_bal_src_as_fee () =
  Context.init1 ~consensus_threshold:0 () >>=? fun (b, dest) ->
  let account = Account.new_account () in
  let src = Contract.Implicit account.Account.pkh in
  Op.transaction (B b) dest src (Tez.of_mutez_exn 100L) >>=? fun operation ->
  Block.bake ~operation b >>=? fun b ->
  Context.Contract.balance (B b) src >>=? fun bal_src ->
  Assert.equal_tez ~loc:__LOC__ bal_src (Tez.of_mutez_exn 100L) >>=? fun () ->
  Op.revelation (B b) ~fee:Tez.zero account.pk >>=? fun operation ->
  Block.bake ~operation b >>=? fun b ->
  Op.transaction (B b) ~fee:bal_src src dest Tez.one >>=? fun op ->
  Incremental.begin_construction b >>=? fun i ->
  Incremental.add_operation i op ~expect_apply_failure:(function
      | Environment.Ecoproto_error (Contract_storage.Balance_too_low _ as err)
        :: _ ->
          Assert.test_error_encodings err ;
          return_unit
      | t -> failwith "Unexpected error: %a" Error_monad.pp_print_trace t)
  >>=? fun _ -> return_unit

(********************)
(* The following tests are for different kind of contracts:
   - implicit to implicit
   - implicit to originated
   - originated to implicit
   - originated to originated *)

(********************)

(** Implicit to Implicit. *)
let test_transfer_from_implicit_to_implicit_contract () =
  Context.init1 ~consensus_threshold:0 () >>=? fun (b, bootstrap_contract) ->
  let account_a = Account.new_account () in
  let account_b = Account.new_account () in
  let src = Contract.Implicit account_a.Account.pkh in
  two_over_n_of_balance (B b) bootstrap_contract 3L >>=? fun amount1 ->
  two_over_n_of_balance (B b) bootstrap_contract 10L >>=? fun fee1 ->
  Incremental.begin_construction b >>=? fun i ->
  transfer_and_check_balances
    ~with_burn:true
    ~loc:__LOC__
    ~fee:fee1
    i
    bootstrap_contract
    src
    amount1
  >>=? fun (i, _) ->
  Incremental.finalize_block i >>=? fun b ->
  Incremental.begin_construction b >>=? fun i ->
  (* Create an implicit contract as a destination contract. *)
  let dest = Contract.Implicit account_b.pkh in
  two_over_n_of_balance (I i) bootstrap_contract 4L >>=? fun amount2 ->
  two_over_n_of_balance (I i) bootstrap_contract 10L >>=? fun fee2 ->
  (* Transfer from implicit contract to another implicit contract. *)
  transfer_and_check_balances
    ~with_burn:true
    ~loc:__LOC__
    ~fee:fee2
    i
    src
    dest
    amount2
  >>=? fun (b, _) ->
  Incremental.finalize_block b >>=? fun _ -> return_unit

(** Implicit to originated. *)
let test_transfer_from_implicit_to_originated_contract () =
  Context.init1 ~consensus_threshold:0 () >>=? fun (b, bootstrap_contract) ->
  let contract = bootstrap_contract in
  let account = Account.new_account () in
  let src = Contract.Implicit account.Account.pkh in
  two_over_n_of_balance (B b) bootstrap_contract 3L >>=? fun amount1 ->
  Incremental.begin_construction b >>=? fun i ->
  (* transfer the money to implicit contract *)
  transfer_and_check_balances
    ~with_burn:true
    ~loc:__LOC__
    i
    bootstrap_contract
    src
    amount1
  >>=? fun (i, _) ->
  Incremental.finalize_block i >>=? fun b ->
  Incremental.begin_construction b >>=? fun i ->
  (* originated contract *)
  Op.contract_origination
    ~force_reveal:true
    (I i)
    contract
    ~script:Op.dummy_script
  >>=? fun (operation, new_contract) ->
  Incremental.add_operation i operation >>=? fun i ->
  two_over_n_of_balance (I i) bootstrap_contract 4L >>=? fun amount2 ->
  (* transfer from implicit contract to originated contract *)
  transfer_and_check_balances ~loc:__LOC__ i src new_contract amount2
  >>=? fun (i, _) ->
  Incremental.finalize_block i >>=? fun _ -> return_unit

(********************)
(* Slow tests case *)

(********************)

let multiple_transfer n ?fee amount =
  Context.init2 ~consensus_threshold:0 ()
  >>=? fun (b, (contract_1, contract_2)) ->
  Incremental.begin_construction b >>=? fun b ->
  n_transactions n b ?fee contract_1 contract_2 amount >>=? fun b ->
  Incremental.finalize_block b >>=? fun _ -> return_unit

(** 1- Create a block with two contracts;
    2- Apply 100 transfers.
*)
let test_block_with_multiple_transfers () = multiple_transfer 99 (of_int 1000)

(** 1- Create a block with two contracts;
    2- Apply 100 transfers with 10tz fee. *)
let test_block_with_multiple_transfers_pay_fee () =
  multiple_transfer 10 ~fee:ten_tez (of_int 1000)

(* TODO : increase the number of operations and add a `Slow tag to it in `tests` *)

(** 1- Create a block with 8 contracts;
    2- Apply multiple transfers without fees;
    3- Apply multiple transfers with fees. *)
let test_block_with_multiple_transfers_with_without_fee () =
  Context.init_n ~consensus_threshold:0 8 () >>=? fun (b, contracts) ->
  let contracts = Array.of_list contracts in
  Incremental.begin_construction b >>=? fun b ->
  let hundred = of_int 100 in
  let ten = of_int 10 in
  let twenty = of_int 20 in
  n_transactions 10 b contracts.(0) contracts.(1) Tez.one >>=? fun b ->
  n_transactions 30 b contracts.(1) contracts.(2) hundred >>=? fun b ->
  n_transactions 30 b contracts.(1) contracts.(3) hundred >>=? fun b ->
  n_transactions 30 b contracts.(4) contracts.(3) hundred >>=? fun b ->
  n_transactions 20 b contracts.(0) contracts.(1) hundred >>=? fun b ->
  n_transactions 10 b contracts.(1) contracts.(3) hundred >>=? fun b ->
  n_transactions 10 b contracts.(1) contracts.(3) hundred >>=? fun b ->
  n_transactions 20 ~fee:ten b contracts.(3) contracts.(4) ten >>=? fun b ->
  n_transactions 10 ~fee:twenty b contracts.(4) contracts.(5) ten >>=? fun b ->
  n_transactions 70 ~fee:twenty b contracts.(6) contracts.(0) twenty
  >>=? fun b ->
  n_transactions 550 ~fee:twenty b contracts.(6) contracts.(4) twenty
  >>=? fun b ->
  n_transactions 50 ~fee:ten b contracts.(7) contracts.(5) twenty >>=? fun b ->
  n_transactions 30 ~fee:ten b contracts.(0) contracts.(7) hundred >>=? fun b ->
  n_transactions 20 ~fee:ten b contracts.(1) contracts.(0) twenty >>=? fun b ->
  Incremental.finalize_block b >>=? fun _ -> return_unit

(** Build a chain that has 10 blocks. *)
let test_build_a_chain () =
  Context.init2 ~consensus_threshold:0 ()
  >>=? fun (b, (contract_1, contract_2)) ->
  let ten = of_int 10 in
  List.fold_left_es
    (fun b _ ->
      Incremental.begin_construction b >>=? fun b ->
      transfer_and_check_balances ~loc:__LOC__ b contract_1 contract_2 ten
      >>=? fun (b, _) -> Incremental.finalize_block b)
    b
    (1 -- 10)
  >>=? fun _ -> return_unit

(*********************************************************************)
(* Expected error test cases                                         *)
(*********************************************************************)

(** Transferring zero tez is forbidden in implicit contract. *)
let test_empty_implicit () =
  Context.init1 () >>=? fun (b, dest) ->
  let account = Account.new_account () in
  let src = Contract.Implicit account.Account.pkh in
  two_over_n_of_balance (B b) dest 3L >>=? fun amount ->
  (* Transfer zero tez from an implicit contract. *)
  Op.transaction (B b) src dest amount >>=? fun op ->
  Incremental.begin_construction b >>=? fun incr ->
  Incremental.add_operation incr op >>= fun res ->
  Assert.proto_error ~loc:__LOC__ res (function
      | Contract_storage.Empty_implicit_contract _ as err ->
          Assert.test_error_encodings err ;
          true
      | _ -> false)

(** Balance is too low to transfer. *)
let test_balance_too_low fee () =
  Context.init2 ~consensus_threshold:0 ()
  >>=? fun (b, (contract_1, contract_2)) ->
  Context.Contract.balance (B b) contract_1 >>=? fun balance1 ->
  Context.Contract.balance (B b) contract_2 >>=? fun balance2 ->
  (* transfer the amount of tez that is bigger than the balance in the source contract *)
  Op.transaction ~fee (B b) contract_1 contract_2 max_tez >>=? fun op ->
  let expect_apply_failure = function
    | Environment.Ecoproto_error (Contract_storage.Balance_too_low _ as err)
      :: _ ->
        Assert.test_error_encodings err ;
        return_unit
    | t -> failwith "Unexpected error: %a" Error_monad.pp_print_trace t
  in
  (* the fee is higher than the balance then raise an error "Balance_too_low" *)
  Incremental.begin_construction b >>=? fun i ->
  if fee > balance1 then
    Incremental.add_operation ~expect_apply_failure i op >>= fun _res ->
    return_unit
    (* the fee is smaller than the balance, then the transfer is accepted
       but it is not processed, and fees are taken *)
  else
    Incremental.add_operation ~expect_apply_failure i op >>=? fun i ->
    (* contract_1 loses the fees *)
    Assert.balance_was_debited ~loc:__LOC__ (I i) contract_1 balance1 fee
    >>=? fun () ->
    (* contract_2 is not credited *)
    Assert.balance_was_credited ~loc:__LOC__ (I i) contract_2 balance2 Tez.zero

(** 1- Create a block, and three contracts;
    2- Add a transfer that at the end the balance of a contract is
       zero into this block;
    3- Add another transfer that send tez from a zero balance contract;
    4- Catch the expected error: Balance_too_low. *)
let test_balance_too_low_two_transfers fee () =
  Context.init3 ~consensus_threshold:0 ()
  >>=? fun (b, (contract_1, contract_2, contract_3)) ->
  Incremental.begin_construction b >>=? fun i ->
  Context.Contract.balance (I i) contract_1 >>=? fun balance ->
  balance /? 3L >>?= fun res ->
  res *? 2L >>?= fun two_third_of_balance ->
  transfer_and_check_balances
    ~loc:__LOC__
    i
    contract_1
    contract_2
    two_third_of_balance
  >>=? fun (i, _) ->
  Incremental.finalize_block i >>=? fun b ->
  Context.Contract.balance (B b) contract_1 >>=? fun balance1 ->
  Context.Contract.balance (B b) contract_3 >>=? fun balance3 ->
  Op.transaction ~fee (B b) contract_1 contract_3 two_third_of_balance
  >>=? fun operation ->
  let expect_apply_failure = function
    | Environment.Ecoproto_error (Contract_storage.Balance_too_low _ as err)
      :: _ ->
        Assert.test_error_encodings err ;
        return_unit
    | t ->
        failwith "Unexpected error: %a" Error_monad.pp_print_trace t
        >>=? fun _ -> return_unit
  in
  Incremental.begin_construction b >>=? fun i ->
  Incremental.add_operation ~expect_apply_failure i operation >>=? fun i ->
  (* contract_1 loses the fees *)
  Assert.balance_was_debited ~loc:__LOC__ (I i) contract_1 balance1 fee
  >>=? fun () ->
  (* contract_3 is not credited *)
  Assert.balance_was_credited ~loc:__LOC__ (I i) contract_3 balance3 Tez.zero

(** The counter is already used for the previous operation. *)
let invalid_counter () =
  Context.init2 ~consensus_threshold:0 ()
  >>=? fun (b, (contract_1, contract_2)) ->
  Op.transaction (B b) contract_1 contract_2 Tez.one >>=? fun op1 ->
  Op.transaction (B b) contract_1 contract_2 Tez.one >>=? fun op2 ->
  Block.bake ~operation:op1 b >>=? fun b ->
  Incremental.begin_construction b >>=? fun i ->
  Incremental.add_operation i op2 >>= fun b ->
  Assert.proto_error ~loc:__LOC__ b (function
      | Contract_storage.Counter_in_the_past _ as err ->
          Assert.test_error_encodings err ;
          true
      | _ -> false)

(** Same as before but through a different way to perform this
    error. *)
let test_add_the_same_operation_twice () =
  Context.init2 () >>=? fun (b, (contract_1, contract_2)) ->
  Incremental.begin_construction b >>=? fun i ->
  transfer_and_check_balances ~loc:__LOC__ i contract_1 contract_2 ten_tez
  >>=? fun (i, op_transfer) ->
  Incremental.finalize_block i >>=? fun b ->
  Incremental.begin_construction b >>=? fun i ->
  Op.transaction (I i) contract_1 contract_2 ten_tez >>=? fun _ ->
  Incremental.add_operation i op_transfer >>= fun b ->
  Assert.proto_error ~loc:__LOC__ b (function
      | Contract_storage.Counter_in_the_past _ as err ->
          Assert.test_error_encodings err ;
          true
      | _ -> false)

(** The counter is in the future *)
let invalid_counter_in_the_future () =
  Context.init2 () >>=? fun (b, (contract_1, contract_2)) ->
  Incremental.begin_construction b >>=? fun b ->
  Context.Contract.counter (I b) contract_1 >>=? fun cpt ->
  let counter = Z.add cpt (Z.of_int 10) in
  Op.transaction (I b) contract_1 contract_2 Tez.one ~counter >>=? fun op ->
  Incremental.add_operation b op >>= fun b ->
  Assert.proto_error ~loc:__LOC__ b (function
      | Contract_storage.Counter_in_the_future _ as err ->
          Assert.test_error_encodings err ;
          true
      | _ -> false)

(** Check ownership. *)
let test_ownership_sender () =
  Context.init2 () >>=? fun (b, (contract_1, contract_2)) ->
  Incremental.begin_construction b >>=? fun b ->
  (* get the manager of the contract_1 as a sender *)
  Context.Contract.manager (I b) contract_1 >>=? fun manager ->
  let imcontract_1 = Alpha_context.Contract.Implicit manager.pkh in
  transfer_and_check_balances ~loc:__LOC__ b imcontract_1 contract_2 Tez.one
  >>=? fun (b, _) ->
  Incremental.finalize_block b >>=? fun _ -> return_unit

(*********************************************************************)
(* Random transfer *)

(* Return a pair of minimum and maximum random number. *)
let random_range (min, max) =
  let interv = max - min + 1 in
  let init =
    Random.self_init () ;
    Random.int interv + min
  in
  init

(* Return a random contract. *)
let random_contract contract_array =
  let i = Random.int (Array.length contract_array) in
  contract_array.(i)

(** Transfer by randomly choose amount 10 contracts, and randomly
    choose the amount in the source contract. *)
let test_random_transfer () =
  Context.init_n 10 () >>=? fun (b, contracts) ->
  let contracts = Array.of_list contracts in
  let source = random_contract contracts in
  let dest = random_contract contracts in
  let source_pkh = Context.Contract.pkh source in
  (* given that source may not have a sufficient balance for the transfer + to bake,
     make sure it cannot be chosen as baker *)
  Context.Contract.balance (B b) source >>=? fun amount ->
  if source = dest then
    transfer_to_itself_and_check_balances
      ~loc:__LOC__
      ~policy:(Block.Excluding [source_pkh])
      b
      source
      amount
    >>=? fun _ -> return_unit
  else
    Incremental.begin_construction ~policy:(Block.Excluding [source_pkh]) b
    >>=? fun i ->
    transfer_and_check_balances ~loc:__LOC__ i source dest amount >>=? fun _ ->
    return_unit

(** Transfer random transactions. *)
let test_random_multi_transactions () =
  let n = random_range (1, 100) in
  multiple_transfer n (of_int 100)

(*********************************************************************)

let test_bad_entrypoint () =
  Context.init1 () >>=? fun (b, _c) ->
  Incremental.begin_construction b >>=? fun v ->
  let ctxt = Incremental.alpha_ctxt v in
  let storage = "Unit" in
  let parameter = "Unit" in
  let entrypoint = Entrypoint.of_string_strict_exn "bad entrypoint" in
  (* bad entrypoint *)
  Contract_helpers.run_script
    ctxt
    "{parameter unit; storage unit; code { CAR; NIL operation; PAIR }}"
    ~entrypoint
    ~storage
    ~parameter
    ()
  >>= function
  | Ok _ -> Alcotest.fail "expected error"
  | Error lst
    when List.mem
           ~equal:( = )
           (Environment.Ecoproto_error
              (Script_tc_errors.No_such_entrypoint entrypoint))
           lst ->
      return ()
  | Error errs ->
      Alcotest.failf "Unexpected error: %a" Error_monad.pp_print_trace errs

let test_bad_parameter () =
  Context.init1 () >>=? fun (b, _c) ->
  Incremental.begin_construction b >>=? fun v ->
  let ctxt = Incremental.alpha_ctxt v in
  let storage = "Unit" in
  let parameter = "1" in
  (* bad parameter *)
  Contract_helpers.run_script
    ctxt
    "{parameter unit; storage unit; code { CAR; NIL operation; PAIR }}"
    ~storage
    ~parameter
    ()
  >>= function
  | Ok _ -> Alcotest.fail "expected error"
  | Error lst
    when List.mem
           ~equal:( = )
           (Environment.Ecoproto_error
              (Script_interpreter.Bad_contract_parameter
                 (Contract.Originated Contract_helpers.default_self)))
           lst ->
      return ()
  | Error errs ->
      Alcotest.failf "Unexpected error: %a" Error_monad.pp_print_trace errs

let transfer_to_itself_with_no_such_entrypoint () =
  let entrypoint = Entrypoint.of_string_strict_exn "bad entrypoint" in
  Context.init1 () >>=? fun (b, addr) ->
  Incremental.begin_construction b >>=? fun i ->
  Op.transaction (B b) addr addr Tez.one ~entrypoint >>=? fun transaction ->
  let expect_apply_failure = function
    | Environment.Ecoproto_error (Script_tc_errors.No_such_entrypoint _ as e)
      :: _ ->
        Assert.test_error_encodings e ;
        return ()
    | _ -> failwith "no such entrypoint should fail"
  in
  Incremental.add_operation ~expect_apply_failure i transaction >>= fun _res ->
  return ()

(** A module with a type that tracks a block's predecessor. *)
module State = struct
  type t = {predecessor : Block.t option; current : Block.t}

  let init () =
    let open Lwt_result_syntax in
    let+ block, b1 = Context.init1 () in
    ({predecessor = None; current = block}, b1)

  (** Applies an operation to a state and returns the resulting state. *)
  let apply ~baker ~operation ~state =
    let block = state.current in
    let open Lwt_result_syntax in
    let open Incremental in
    let* inc = begin_construction ~policy:Block.(By_account baker) block in
    let* inc = add_operation inc operation in
    let* inc =
      match state.predecessor with
      | None -> return inc
      | Some predecessor ->
          (* Include all endorsements. *)
          let* endorsers = Context.get_endorsers (B block) in
          List.fold_left_es
            (fun inc {Plugin.RPC.Validators.delegate; slots; _} ->
              let* endorsement =
                Op.endorsement
                  ~delegate:(delegate, slots)
                  ~endorsed_block:block
                  (B predecessor)
                  ()
              in
              add_operation inc (Operation.pack endorsement))
            inc
            endorsers
    in
    let+ next = finalize_block inc in
    {predecessor = Some block; current = next}

  let current {current; _} = current

  (** Originates a contract with a [script] and an initial [credit] and
      [storage]. *)
  let contract_originate ~baker ~(state : t) ~script ~credit ~storage ~source =
    let open Lwt_result_syntax in
    let block = current state in
    let code = Expr.from_string script in
    let script =
      Alpha_context.Script.{code = lazy_expr code; storage = lazy_expr storage}
    in
    let* op, dst =
      Op.contract_origination_hash
        (B block)
        source
        ~fee:Tez.zero
        ~script
        ~credit
    in
    let+ state = apply ~operation:op ~state ~baker in
    (state, dst)

  (** Runs a transaction from a [source] to a [destination]. *)
  let transfer ?force_reveal ?parameters ~baker ~state ~source ~destination
      amount =
    let open Lwt_result_syntax in
    let block = current state in
    let* operation =
      Op.transaction
        ?force_reveal
        ?parameters
        ~fee:Tez.zero
        (B block)
        source
        destination
        amount
    in
    apply ~operation ~state ~baker
end

(** The script of a contract that transfers its balance to the caller, and
    stores the parameter of the call. *)
let script =
  {| { parameter string ;
     storage string ;
       code {
         CAR ;
         SOURCE ;
         CONTRACT unit ;
         ASSERT_SOME ;
         BALANCE ;
         UNIT ;
         TRANSFER_TOKENS ;
         NIL operation ;
         SWAP ;
         CONS ;
         PAIR }
} |}

(** The tested scenarios are the following :

    - originate a contract with the above [script] and no initial balance,
    call it from an account short of sufficient funds to cover storage fees,
    and check that this indeed fails.

    - originate a contract with the above [script] and sufficient balance to
    cover storage fees of a subsequent call, call the originated contract from
    an account short of sufficient funds to cover storage fees, as expected,
    this succeeds since the caller receives the originated contract's initial
    balance. *)
let test_storage_fees_and_internal_operation () =
  let open Lwt_result_syntax in
  let* initial_state, b1 = State.init () in
  let null_string = Expr.from_string "\"\"" in
  let caller = Account.new_account () in
  (* Initialize a caller account. *)
  let* initial_state =
    State.transfer
      ~state:initial_state
      ~baker:(Context.Contract.pkh b1)
      ~source:b1
      ~destination:(Contract.Implicit caller.pkh)
      Tez.one_mutez
  in
  (* [originate_and_call] first, originates a contract with an empty string as
     initial storage, and an initial credit of [initial_amount]. And then, calls
     the originated contract from [caller] with a parameter that allocates
     additional storage. *)
  let originate_and_call ~initial_state ~initial_amount =
    let* state, contract_hash =
      State.contract_originate
        ~state:initial_state
        ~baker:(Context.Contract.pkh b1)
        ~script
        ~source:b1
        ~credit:initial_amount
        ~storage:null_string
    in
    let random_string = Expr.from_string "\"Abracadabra\"" in
    State.transfer
      ~force_reveal:true
      ~parameters:(Alpha_context.Script.lazy_expr random_string)
      ~state
      ~baker:(Context.Contract.pkh b1)
      ~source:(Contract.Implicit caller.pkh)
      ~destination:(Contract.Originated contract_hash)
      Tez.zero
  in
  (* Ensure failure when the initial balance of the originated contract is not
     sufficient to pay storage fees. *)
  let*! res = originate_and_call ~initial_state ~initial_amount:Tez.one_mutez in
  let* () =
    Assert.proto_error_with_info ~loc:__LOC__ res "Cannot pay storage fee"
  in
  (* Ensure success when the initial balance of the originated contract is
     sufficient to pay storage fees. *)
  let+ _ = originate_and_call ~initial_state ~initial_amount:Tez.one_cent in
  ()

let tests =
  [
    (* single transfer *)
    Tztest.tztest "single transfer" `Quick test_block_with_a_single_transfer;
    Tztest.tztest
      "single transfer with fee"
      `Quick
      test_block_with_a_single_transfer_with_fee;
    (* transfer zero tez *)
    Tztest.tztest "single transfer zero tez" `Quick test_transfer_zero_tez;
    Tztest.tztest
      "transfer zero tez from implicit contract"
      `Quick
      test_transfer_zero_implicit;
    Tztest.tztest
      "transfer zero tez to an implicit contract with balance of src as fee"
      `Quick
      test_transfer_zero_implicit_with_bal_src_as_fee;
    (* transfer to originated contract *)
    Tztest.tztest
      "transfer to originated contract paying transaction fee"
      `Quick
      test_transfer_to_originate_with_fee;
    Tztest.tztest
      "transfer zero tez to an originated contract with balance of src as fee"
      `Quick
      test_transfer_zero_to_originated_with_bal_src_as_fee;
    (* transfer by the balance of contract *)
    Tztest.tztest
      "transfer the amount from source contract balance"
      `Quick
      test_transfer_amount_of_contract_balance;
    (* transfer to itself *)
    Tztest.tztest "transfers to itself" `Quick test_transfers_to_self;
    (* missing operation *)
    Tztest.tztest "missing transaction" `Quick test_missing_transaction;
    (* transfer from/to implicit/originated contracts*)
    Tztest.tztest
      "transfer from an implicit to implicit contract"
      `Quick
      test_transfer_from_implicit_to_implicit_contract;
    Tztest.tztest
      "transfer from an implicit to an originated contract"
      `Quick
      test_transfer_from_implicit_to_originated_contract;
    (* Slow tests *)
    Tztest.tztest
      "block with multiple transfers"
      `Slow
      test_block_with_multiple_transfers;
    (* TODO increase the number of transaction times *)
    Tztest.tztest
      "block with multiple transfer paying fee"
      `Slow
      test_block_with_multiple_transfers_pay_fee;
    Tztest.tztest
      "block with multiple transfer without paying fee"
      `Slow
      test_block_with_multiple_transfers_with_without_fee;
    (* build the chain *)
    Tztest.tztest "build a chain" `Quick test_build_a_chain;
    (* Erroneous *)
    Tztest.tztest "empty implicit" `Quick test_empty_implicit;
    Tztest.tztest
      "balance too low - transfer zero"
      `Quick
      (test_balance_too_low Tez.zero);
    Tztest.tztest "balance too low" `Quick (test_balance_too_low Tez.one);
    Tztest.tztest
      "balance too low (max fee)"
      `Quick
      (test_balance_too_low max_tez);
    Tztest.tztest
      "balance too low with two transfers - transfer zero"
      `Quick
      (test_balance_too_low_two_transfers Tez.zero);
    Tztest.tztest
      "balance too low with two transfers"
      `Quick
      (test_balance_too_low_two_transfers Tez.one);
    Tztest.tztest
      "transfer one tez to an implicit contract with balance of src as fee"
      `Quick
      test_transfer_one_to_implicit_with_bal_src_as_fee;
    Tztest.tztest "invalid_counter" `Quick invalid_counter;
    Tztest.tztest
      "add the same operation twice"
      `Quick
      test_add_the_same_operation_twice;
    Tztest.tztest
      "invalid_counter_in_the_future"
      `Quick
      invalid_counter_in_the_future;
    Tztest.tztest "ownership sender" `Quick test_ownership_sender;
    (* Random tests *)
    Tztest.tztest "random transfer" `Quick test_random_transfer;
    Tztest.tztest "random multi transfer" `Quick test_random_multi_transactions;
    Tztest.tztest "bad entrypoint" `Quick test_bad_entrypoint;
    Tztest.tztest "bad parameter" `Quick test_bad_parameter;
    Tztest.tztest
      "no such entrypoint"
      `Quick
      transfer_to_itself_with_no_such_entrypoint;
    Tztest.tztest
      "storage fees after contract call and allocation"
      `Quick
      test_storage_fees_and_internal_operation;
  ]
