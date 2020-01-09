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

let sign ?(watermark = Signature.Generic_operation) sk ctxt contents =
  let branch = Context.branch ctxt in
  let unsigned =
    Data_encoding.Binary.to_bytes_exn
      Operation.unsigned_encoding
      ({branch}, Contents_list contents)
  in
  let signature = Some (Signature.sign ~watermark sk unsigned) in
  ({shell = {branch}; protocol_data = {contents; signature}} : _ Operation.t)

let endorsement ?delegate ?level ctxt ?(signing_context = ctxt) () =
  ( match delegate with
  | None ->
      Context.get_endorser ctxt >>=? fun (delegate, _slots) -> return delegate
  | Some delegate ->
      return delegate )
  >>=? fun delegate_pkh ->
  Account.find delegate_pkh
  >>=? fun delegate ->
  ( match level with
  | None ->
      Context.get_level ctxt
  | Some level ->
      return level )
  >>=? fun level ->
  let op = Single (Endorsement {level}) in
  return
    (sign
       ~watermark:Signature.(Endorsement Chain_id.zero)
       delegate.sk
       signing_context
       op)

let sign ?watermark sk ctxt (Contents_list contents) =
  Operation.pack (sign ?watermark sk ctxt contents)

let combine_operations ?public_key ?counter ~source ctxt
    (packed_operations : packed_operation list) =
  assert (List.length packed_operations > 0) ;
  (* Hypothesis : each operation must have the same branch (is this really true?) *)
  let {Tezos_base.Operation.branch} = (List.hd packed_operations).shell in
  assert (
    List.for_all
      (fun {shell = {Tezos_base.Operation.branch = b; _}; _} ->
        Block_hash.(branch = b))
      packed_operations ) ;
  (* TODO? : check signatures consistency *)
  let unpacked_operations =
    List.map
      (function
        | {Alpha_context.protocol_data = Operation_data {contents; _}; _} -> (
          match Contents_list contents with
          | Contents_list (Single o) ->
              Contents o
          | Contents_list
              (Cons (Manager_operation {operation = Reveal _; _}, Single o)) ->
              Contents o
          | _ ->
              (* TODO : decent error *) assert false ))
      packed_operations
  in
  ( match counter with
  | Some counter ->
      return counter
  | None ->
      Context.Contract.counter ctxt source )
  >>=? fun counter ->
  (* We increment the counter *)
  let counter = Z.succ counter in
  Context.Contract.manager ctxt source
  >>=? fun account ->
  let public_key = Option.unopt ~default:account.pk public_key in
  Context.Contract.is_manager_key_revealed ctxt source
  >>=? (function
         | false ->
             let reveal_op =
               Manager_operation
                 {
                   source = Signature.Public_key.hash public_key;
                   fee = Tez.zero;
                   counter;
                   operation = Reveal public_key;
                   gas_limit = Z.of_int 10000;
                   storage_limit = Z.zero;
                 }
             in
             return (Some (Contents reveal_op), Z.succ counter)
         | true ->
             return (None, counter))
  >>=? fun (manager_op, counter) ->
  (* Update counters and transform into a contents_list *)
  let operations =
    List.fold_left
      (fun (counter, acc) -> function Contents (Manager_operation m) ->
            ( Z.succ counter,
              Contents (Manager_operation {m with counter}) :: acc ) | x ->
            (counter, x :: acc))
      (counter, match manager_op with None -> [] | Some op -> [op])
      unpacked_operations
    |> snd |> List.rev
  in
  let operations = Operation.of_list operations in
  return @@ sign account.sk ctxt operations

let manager_operation ?counter ?(fee = Tez.zero) ?gas_limit ?storage_limit
    ?public_key ~source ctxt operation =
  ( match counter with
  | Some counter ->
      return counter
  | None ->
      Context.Contract.counter ctxt source )
  >>=? fun counter ->
  Context.get_constants ctxt
  >>=? fun c ->
  let gas_limit =
    Option.unopt
      ~default:c.parametric.hard_storage_limit_per_operation
      gas_limit
  in
  let storage_limit =
    Option.unopt
      ~default:c.parametric.hard_storage_limit_per_operation
      storage_limit
  in
  Context.Contract.manager ctxt source
  >>=? fun account ->
  let public_key = Option.unopt ~default:account.pk public_key in
  let counter = Z.succ counter in
  Context.Contract.is_manager_key_revealed ctxt source
  >>=? function
  | true ->
      let op =
        Manager_operation
          {
            source = Signature.Public_key.hash public_key;
            fee;
            counter;
            operation;
            gas_limit;
            storage_limit;
          }
      in
      return (Contents_list (Single op))
  | false ->
      let op_reveal =
        Manager_operation
          {
            source = Signature.Public_key.hash public_key;
            fee = Tez.zero;
            counter;
            operation = Reveal public_key;
            gas_limit = Z.of_int 10000;
            storage_limit = Z.zero;
          }
      in
      let op =
        Manager_operation
          {
            source = Signature.Public_key.hash public_key;
            fee;
            counter = Z.succ counter;
            operation;
            gas_limit;
            storage_limit;
          }
      in
      return (Contents_list (Cons (op_reveal, Single op)))

let revelation ctxt public_key =
  let pkh = Signature.Public_key.hash public_key in
  let source = Contract.implicit_contract pkh in
  Context.Contract.counter ctxt source
  >>=? fun counter ->
  Context.Contract.manager ctxt source
  >>=? fun account ->
  let counter = Z.succ counter in
  let sop =
    Contents_list
      (Single
         (Manager_operation
            {
              source = Signature.Public_key.hash public_key;
              fee = Tez.zero;
              counter;
              operation = Reveal public_key;
              gas_limit = Z.of_int 10000;
              storage_limit = Z.zero;
            }))
  in
  return @@ sign account.sk ctxt sop

let originated_contract op =
  let nonce = Contract.initial_origination_nonce (Operation.hash_packed op) in
  Contract.originated_contract nonce

exception Impossible

let origination ?counter ?delegate ~script ?(preorigination = None) ?public_key
    ?credit ?fee ?gas_limit ?storage_limit ctxt source =
  Context.Contract.manager ctxt source
  >>=? fun account ->
  let default_credit = Tez.of_mutez @@ Int64.of_int 1000001 in
  let default_credit = Option.unopt_exn Impossible default_credit in
  let credit = Option.unopt ~default:default_credit credit in
  let operation = Origination {delegate; script; credit; preorigination} in
  manager_operation
    ?counter
    ?public_key
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    operation
  >>=? fun sop ->
  let op = sign account.sk ctxt sop in
  return (op, originated_contract op)

let miss_signed_endorsement ?level ctxt =
  ( match level with
  | None ->
      Context.get_level ctxt
  | Some level ->
      return level )
  >>=? fun level ->
  Context.get_endorser ctxt
  >>=? fun (real_delegate_pkh, _slots) ->
  let delegate = Account.find_alternate real_delegate_pkh in
  endorsement ~delegate:delegate.pkh ~level ctxt ()

let transaction ?fee ?gas_limit ?storage_limit
    ?(parameters = Script.unit_parameter) ?(entrypoint = "default") ctxt
    (src : Contract.t) (dst : Contract.t) (amount : Tez.t) =
  let top = Transaction {amount; parameters; destination = dst; entrypoint} in
  manager_operation ?fee ?gas_limit ?storage_limit ~source:src ctxt top
  >>=? fun sop ->
  Context.Contract.manager ctxt src
  >>=? fun account -> return @@ sign account.sk ctxt sop

let delegation ?fee ctxt source dst =
  let top = Delegation dst in
  manager_operation ?fee ~source ctxt top
  >>=? fun sop ->
  Context.Contract.manager ctxt source
  >>=? fun account -> return @@ sign account.sk ctxt sop

let activation ctxt (pkh : Signature.Public_key_hash.t) activation_code =
  ( match pkh with
  | Ed25519 edpkh ->
      return edpkh
  | _ ->
      failwith
        "Wrong public key hash : %a - Commitments must be activated with an \
         Ed25519 encrypted public key hash"
        Signature.Public_key_hash.pp
        pkh )
  >>=? fun id ->
  let contents = Single (Activate_account {id; activation_code}) in
  let branch = Context.branch ctxt in
  return
    {
      shell = {branch};
      protocol_data = Operation_data {contents; signature = None};
    }

let double_endorsement ctxt op1 op2 =
  let contents = Single (Double_endorsement_evidence {op1; op2}) in
  let branch = Context.branch ctxt in
  return
    {
      shell = {branch};
      protocol_data = Operation_data {contents; signature = None};
    }

let double_baking ctxt bh1 bh2 =
  let contents = Single (Double_baking_evidence {bh1; bh2}) in
  let branch = Context.branch ctxt in
  return
    {
      shell = {branch};
      protocol_data = Operation_data {contents; signature = None};
    }

let seed_nonce_revelation ctxt level nonce =
  return
    {
      shell = {branch = Context.branch ctxt};
      protocol_data =
        Operation_data
          {
            contents = Single (Seed_nonce_revelation {level; nonce});
            signature = None;
          };
    }

let proposals ctxt (pkh : Contract.t) proposals =
  Context.Contract.pkh pkh
  >>=? fun source ->
  Context.Vote.get_voting_period ctxt
  >>=? fun period ->
  let op = Proposals {source; period; proposals} in
  Account.find source
  >>=? fun account -> return (sign account.sk ctxt (Contents_list (Single op)))

let ballot ctxt (pkh : Contract.t) proposal ballot =
  Context.Contract.pkh pkh
  >>=? fun source ->
  Context.Vote.get_voting_period ctxt
  >>=? fun period ->
  let op = Ballot {source; period; proposal; ballot} in
  Account.find source
  >>=? fun account -> return (sign account.sk ctxt (Contents_list (Single op)))

let dummy_script =
  let open Micheline in
  Script.
    {
      code =
        lazy_expr
          (strip_locations
             (Seq
                ( 0,
                  [ Prim (0, K_parameter, [Prim (0, T_unit, [], [])], []);
                    Prim (0, K_storage, [Prim (0, T_unit, [], [])], []);
                    Prim
                      ( 0,
                        K_code,
                        [ Seq
                            ( 0,
                              [ Prim (0, I_CDR, [], []);
                                Prim
                                  ( 0,
                                    I_NIL,
                                    [Prim (0, T_operation, [], [])],
                                    [] );
                                Prim (0, I_PAIR, [], []) ] ) ],
                        [] ) ] )));
      storage = lazy_expr (strip_locations (Prim (0, D_Unit, [], [])));
    }

let dummy_script_cost = Test_tez.Tez.of_mutez_exn 38_000L
