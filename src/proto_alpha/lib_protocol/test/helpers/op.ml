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

let pack_operation ctxt signature contents =
  let branch = Context.branch ctxt in
  Operation.pack
    ({shell = {branch}; protocol_data = {contents; signature}} : _ Operation.t)

let sign ?(watermark = Signature.Generic_operation) sk ctxt contents =
  let branch = Context.branch ctxt in
  let unsigned =
    Data_encoding.Binary.to_bytes_exn
      Operation.unsigned_encoding
      ({branch}, Contents_list contents)
  in
  let signature = Some (Signature.sign ~watermark sk unsigned) in
  ({shell = {branch}; protocol_data = {contents; signature}} : _ Operation.t)

(** Generates the block payload hash based on the hash [pred_hash] of
    the predecessor block and the hash of non-consensus operations of
    the current block [b]. *)
let mk_block_payload_hash predecessor_hash payload_round (b : Block.t) =
  let ops = Block.Forge.classify_operations b.operations in
  let non_consensus_operations =
    List.concat (match List.tl ops with None -> [] | Some l -> l)
  in
  let hashes = List.map Operation.hash_packed non_consensus_operations in
  Block_payload.hash ~predecessor_hash ~payload_round hashes

(* ctxt is used for getting the branch in sign *)
let endorsement ?delegate ?slot ?level ?round ?block_payload_hash
    ~endorsed_block ctxt ?(signing_context = ctxt) () =
  let pred_hash = match ctxt with Context.B b -> b.hash | _ -> assert false in
  (match delegate with
  | None -> Context.get_endorser (B endorsed_block)
  | Some v -> return v)
  >>=? fun (delegate_pkh, slots) ->
  let slot =
    match slot with None -> Stdlib.List.hd slots | Some slot -> slot
  in
  (match level with
  | None -> Context.get_level (B endorsed_block)
  | Some level -> ok level)
  >>?= fun level ->
  (match round with
  | None -> Block.get_round endorsed_block
  | Some round -> ok round)
  >>?= fun round ->
  let block_payload_hash =
    match block_payload_hash with
    | None -> mk_block_payload_hash pred_hash round endorsed_block
    | Some block_payload_hash -> block_payload_hash
  in
  let consensus_content = {slot; level; round; block_payload_hash} in
  let op = Single (Endorsement consensus_content) in
  Account.find delegate_pkh >>=? fun delegate ->
  return
    (sign
       ~watermark:Operation.(to_watermark (Endorsement Chain_id.zero))
       delegate.sk
       signing_context
       op)

let preendorsement ?delegate ?slot ?level ?round ?block_payload_hash
    ~endorsed_block ctxt ?(signing_context = ctxt) () =
  let pred_hash = match ctxt with Context.B b -> b.hash | _ -> assert false in
  (match delegate with
  | None -> Context.get_endorser (B endorsed_block)
  | Some v -> return v)
  >>=? fun (delegate_pkh, slots) ->
  let slot =
    match slot with None -> Stdlib.List.hd slots | Some slot -> slot
  in
  (match level with
  | None -> Context.get_level (B endorsed_block)
  | Some level -> ok level)
  >>?= fun level ->
  (match round with
  | None -> Block.get_round endorsed_block
  | Some round -> ok round)
  >>?= fun round ->
  let block_payload_hash =
    match block_payload_hash with
    | None -> mk_block_payload_hash pred_hash round endorsed_block
    | Some block_payload_hash -> block_payload_hash
  in
  let consensus_content = {slot; level; round; block_payload_hash} in
  let op = Single (Preendorsement consensus_content) in
  Account.find delegate_pkh >>=? fun delegate ->
  return
    (sign
       ~watermark:Operation.(to_watermark (Preendorsement Chain_id.zero))
       delegate.sk
       signing_context
       op)

let sign ?watermark sk ctxt (Contents_list contents) =
  Operation.pack (sign ?watermark sk ctxt contents)

let batch_operations ?(recompute_counters = false) ~source ctxt
    (operations : packed_operation list) =
  let operations =
    List.map
      (function
        | {Alpha_context.protocol_data = Operation_data {contents; _}; _} ->
            Operation.to_list (Contents_list contents))
      operations
    |> List.flatten
  in
  (if recompute_counters then
   Context.Contract.counter ctxt source >>=? fun counter ->
   (* Update counters and transform into a contents_list *)
   let _, rev_operations =
     List.fold_left
       (fun (counter, acc) -> function
         | Contents (Manager_operation m) ->
             ( Z.succ counter,
               Contents (Manager_operation {m with counter}) :: acc )
         | x -> (counter, x :: acc))
       (Z.succ counter, [])
       operations
   in
   return (List.rev rev_operations)
  else return operations)
  >>=? fun operations ->
  Context.Contract.manager ctxt source >>=? fun account ->
  Environment.wrap_tzresult @@ Operation.of_list operations
  >>?= fun operations -> return @@ sign account.sk ctxt operations

type gas_limit = Max | High | Low | Zero | Custom_gas of Gas.Arith.integral

let default_low_gas_limit =
  Gas.Arith.integral_of_int_exn
    Michelson_v1_gas.Internal_for_tests.int_cost_of_manager_operation

let default_high_gas_limit =
  Gas.Arith.integral_of_int_exn
    (49_000 + Michelson_v1_gas.Internal_for_tests.int_cost_of_manager_operation)

let resolve_gas_limit ctxt = function
  | Max ->
      Context.get_constants ctxt >>=? fun c ->
      return c.parametric.hard_gas_limit_per_operation
  | High -> return default_high_gas_limit
  | Low -> return default_low_gas_limit
  | Zero -> return Gas.Arith.zero
  | Custom_gas x -> return x

let pp_gas_limit fmt = function
  | Max -> Format.fprintf fmt "Max"
  | High ->
      Format.fprintf fmt "High: %a" Gas.Arith.pp_integral default_high_gas_limit
  | Low ->
      Format.fprintf fmt "Low: %a" Gas.Arith.pp_integral default_low_gas_limit
  | Zero -> Format.fprintf fmt "Zero: %a" Gas.Arith.pp_integral Gas.Arith.zero
  | Custom_gas x -> Format.fprintf fmt "Custom: %a" Gas.Arith.pp_integral x

let combine_operations ?public_key ?counter ?spurious_operation ~source ctxt
    (packed_operations : packed_operation list) =
  assert (match packed_operations with [] -> false | _ :: _ -> true) ;
  (* Hypothesis : each operation must have the same branch (is this really true?) *)
  let {Tezos_base.Operation.branch} =
    (WithExceptions.Option.get ~loc:__LOC__ @@ List.hd packed_operations).shell
  in
  assert (
    List.for_all
      (fun {shell = {Tezos_base.Operation.branch = b; _}; _} ->
        Block_hash.(branch = b))
      packed_operations) ;
  (* TODO? : check signatures consistency *)
  let unpacked_operations =
    List.map
      (function
        | {Alpha_context.protocol_data = Operation_data {contents; _}; _} -> (
            match Contents_list contents with
            | Contents_list (Single o) -> Contents o
            | Contents_list
                (Cons (Manager_operation {operation = Reveal _; _}, Single o))
              ->
                Contents o
            | _ -> (* TODO : decent error *) assert false))
      packed_operations
  in
  (match counter with
  | Some counter -> return counter
  | None -> Context.Contract.counter ctxt source)
  >>=? fun counter ->
  (* We increment the counter *)
  let counter = Z.succ counter in
  Context.Contract.manager ctxt source >>=? fun account ->
  let public_key = Option.value ~default:account.pk public_key in
  (Context.Contract.is_manager_key_revealed ctxt source >|=? function
   | false ->
       let reveal_op =
         Manager_operation
           {
             source = Signature.Public_key.hash public_key;
             fee = Tez.zero;
             counter;
             operation = Reveal public_key;
             gas_limit = default_high_gas_limit;
             storage_limit = Z.zero;
           }
       in
       (Some (Contents reveal_op), Z.succ counter)
   | true -> (None, counter))
  >>=? fun (manager_op, counter) ->
  (* Update counters and transform into a contents_list *)
  let counter, rev_operations =
    List.fold_left
      (fun (counter, acc) -> function
        | Contents (Manager_operation m) ->
            ( Z.succ counter,
              Contents (Manager_operation {m with counter}) :: acc )
        | x -> (counter, x :: acc))
      (counter, match manager_op with None -> [] | Some op -> [op])
      unpacked_operations
  in
  let operations = List.rev rev_operations in
  (* patch a random operation with a corrupted pkh *)
  let operations =
    match spurious_operation with
    | None -> operations
    | Some op ->
        let op =
          match op with
          | {protocol_data; shell = _} -> (
              match protocol_data with
              | Operation_data {contents; _} -> (
                  match contents with
                  | Cons _ -> assert false
                  | Single (Manager_operation m) ->
                      Alpha_context.Contents
                        (Manager_operation {m with counter})
                  | Single op -> Contents op))
        in
        (* Insert at the end *)
        operations @ [op]
  in
  Environment.wrap_tzresult @@ Operation.of_list operations
  >>?= fun operations -> return @@ sign account.sk ctxt operations

let manager_operation ?(force_reveal = false) ?counter ?(fee = Tez.zero)
    ?(gas_limit = High) ?storage_limit ?public_key ~source ctxt operation =
  (match counter with
  | Some counter -> return counter
  | None -> Context.Contract.counter ctxt source)
  >>=? fun counter ->
  Context.get_constants ctxt >>=? fun c ->
  let storage_limit =
    Option.value
      ~default:c.parametric.hard_storage_limit_per_operation
      storage_limit
  in
  resolve_gas_limit ctxt gas_limit >>=? fun gas_limit ->
  Context.Contract.manager ctxt source >>=? fun account ->
  let public_key = Option.value ~default:account.pk public_key in
  let counter = Z.succ counter in
  Context.Contract.is_manager_key_revealed ctxt source >|=? fun revealed ->
  (* If the manager is revealed or we are not forcing reveals, we
     generate a singleton manager operation. *)
  if revealed || not force_reveal then
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
    Contents_list (Single op)
    (* Otherwise if the manager is unrevealed and we are
       force_revaling managers by default, we pre-attach a revelation
       for it. *)
  else
    let op_reveal =
      Manager_operation
        {
          source = Signature.Public_key.hash public_key;
          fee = Tez.zero;
          counter;
          operation = Reveal public_key;
          gas_limit = default_high_gas_limit;
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
    Contents_list (Cons (op_reveal, Single op))

let revelation ?(fee = Tez.zero) ?(gas_limit = High) ?(storage_limit = Z.zero)
    ?counter ?(forge_pkh = None) ctxt public_key =
  (* If Some pkh is provided to ?forge_pkh we take that hash at face
     value, otherwise we honestly compute the hash from
     [public_key]. This is useful to test forging Reveal operations
     (cf. tezos!5182). *)
  let pkh =
    match forge_pkh with
    | Some pkh -> pkh
    | None -> Signature.Public_key.hash public_key
  in
  resolve_gas_limit ctxt gas_limit >>=? fun gas_limit ->
  let source = Contract.Implicit pkh in
  (match counter with
  | None -> Context.Contract.counter ctxt source
  | Some ctr -> return ctr)
  >>=? fun counter ->
  Context.Contract.manager ctxt source >|=? fun account ->
  let counter = Z.succ counter in
  let sop =
    Contents_list
      (Single
         (Manager_operation
            {
              source = pkh;
              fee;
              counter;
              operation = Reveal public_key;
              gas_limit;
              storage_limit;
            }))
  in
  sign account.sk ctxt sop

let failing_noop ctxt source arbitrary =
  let op = Contents_list (Single (Failing_noop arbitrary)) in
  Account.find source >>=? fun account -> return @@ sign account.sk ctxt op

let originated_contract_hash op =
  let nonce = Protocol.Origination_nonce.initial (Operation.hash_packed op) in
  Contract_hash.of_nonce nonce

let originated_contract op = Contract.Originated (originated_contract_hash op)

exception Impossible

let contract_origination_gen k ?force_reveal ?counter ?delegate ~script
    ?public_key ?credit ?fee ?gas_limit ?storage_limit ctxt source =
  Context.Contract.manager ctxt source >>=? fun account ->
  let default_credit = Tez.of_mutez @@ Int64.of_int 1000001 in
  let default_credit =
    WithExceptions.Option.to_exn ~none:Impossible default_credit
  in
  let credit = Option.value ~default:default_credit credit in
  let operation = Origination {delegate; script; credit} in
  manager_operation
    ?force_reveal
    ?counter
    ?public_key
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    operation
  >|=? fun sop -> k (sign account.sk ctxt sop)

let contract_origination =
  contract_origination_gen (fun op -> (op, originated_contract op))

let contract_origination_hash =
  contract_origination_gen (fun op -> (op, originated_contract_hash op))

let register_global_constant ?force_reveal ?counter ?public_key ?fee ?gas_limit
    ?storage_limit ctxt ~source ~value =
  Context.Contract.manager ctxt source >>=? fun account ->
  let operation = Register_global_constant {value} in
  manager_operation
    ?force_reveal
    ?counter
    ?public_key
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    operation
  >|=? fun sop -> sign account.sk ctxt sop

let miss_signed_endorsement ?level ~endorsed_block ctxt =
  (match level with None -> Context.get_level ctxt | Some level -> ok level)
  >>?= fun level ->
  Context.get_endorser ctxt >>=? fun (real_delegate_pkh, slots) ->
  let delegate = Account.find_alternate real_delegate_pkh in
  endorsement ~delegate:(delegate.pkh, slots) ~level ~endorsed_block ctxt ()

let unsafe_transaction ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ?(parameters = Script.unit_parameter) ?(entrypoint = Entrypoint.default)
    ctxt (src : Contract.t) (destination : Contract.t) (amount : Tez.t) =
  let top = Transaction {amount; parameters; destination; entrypoint} in
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    top
  >>=? fun sop ->
  Context.Contract.manager ctxt src >|=? fun account -> sign account.sk ctxt sop

let transaction ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ?parameters ?entrypoint ctxt (src : Contract.t) (dst : Contract.t)
    (amount : Tez.t) =
  unsafe_transaction
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ?parameters
    ?entrypoint
    ctxt
    src
    dst
    amount

let delegation ?force_reveal ?fee ?gas_limit ?counter ?storage_limit ctxt source
    dst =
  let top = Delegation dst in
  manager_operation
    ?force_reveal
    ?fee
    ?counter
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    top
  >>=? fun sop ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt sop

let set_deposits_limit ?force_reveal ?fee ?gas_limit ?storage_limit ?counter
    ctxt source limit =
  let top = Set_deposits_limit limit in
  manager_operation
    ?force_reveal
    ?fee
    ?counter
    ?storage_limit
    ?gas_limit
    ~source
    ctxt
    top
  >>=? fun sop ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt sop

let increase_paid_storage ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ctxt ~source ~destination (amount : Z.t) =
  let top = Increase_paid_storage {amount_in_bytes = amount; destination} in
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    top
  >>=? fun sop ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt sop

let activation ctxt (pkh : Signature.Public_key_hash.t) activation_code =
  (match pkh with
  | Ed25519 edpkh -> return edpkh
  | _ ->
      failwith
        "Wrong public key hash : %a - Commitments must be activated with an \
         Ed25519 encrypted public key hash"
        Signature.Public_key_hash.pp
        pkh)
  >|=? fun id ->
  let contents = Single (Activate_account {id; activation_code}) in
  let branch = Context.branch ctxt in
  {
    shell = {branch};
    protocol_data = Operation_data {contents; signature = None};
  }

let double_endorsement ctxt op1 op2 =
  let contents = Single (Double_endorsement_evidence {op1; op2}) in
  let branch = Context.branch ctxt in
  {
    shell = {branch};
    protocol_data = Operation_data {contents; signature = None};
  }

let double_preendorsement ctxt op1 op2 =
  let contents = Single (Double_preendorsement_evidence {op1; op2}) in
  let branch = Context.branch ctxt in
  {
    shell = {branch};
    protocol_data = Operation_data {contents; signature = None};
  }

let double_baking ctxt bh1 bh2 =
  let contents = Single (Double_baking_evidence {bh1; bh2}) in
  let branch = Context.branch ctxt in
  {
    shell = {branch};
    protocol_data = Operation_data {contents; signature = None};
  }

let seed_nonce_revelation ctxt level nonce =
  {
    shell = {branch = Context.branch ctxt};
    protocol_data =
      Operation_data
        {
          contents = Single (Seed_nonce_revelation {level; nonce});
          signature = None;
        };
  }

let vdf_revelation ctxt solution =
  {
    shell = {branch = Context.branch ctxt};
    protocol_data =
      Operation_data
        {contents = Single (Vdf_revelation {solution}); signature = None};
  }

let get_period ?period ctxt =
  let open Lwt_result_syntax in
  match period with
  | Some period -> return period
  | None ->
      let* current_period = Context.Vote.get_current_period ctxt in
      return current_period.voting_period.index

let proposals_contents ctxt proposer ?period proposals =
  let open Lwt_result_syntax in
  let source = Context.Contract.pkh proposer in
  let* period = get_period ?period ctxt in
  return (Single (Proposals {source; period; proposals}))

let proposals ctxt proposer ?period proposals =
  let open Lwt_result_syntax in
  let* contents = proposals_contents ctxt proposer ?period proposals in
  let* account = Account.find (Context.Contract.pkh proposer) in
  return (sign account.sk ctxt (Contents_list contents))

let ballot_contents ctxt voter ?period proposal ballot =
  let open Lwt_result_syntax in
  let source = Context.Contract.pkh voter in
  let* period = get_period ?period ctxt in
  return (Single (Ballot {source; period; proposal; ballot}))

let ballot ctxt voter ?period proposal ballot =
  let open Lwt_result_syntax in
  let* contents = ballot_contents ctxt voter ?period proposal ballot in
  let* account = Account.find (Context.Contract.pkh voter) in
  return (sign account.sk ctxt (Contents_list contents))

let dummy_script =
  let open Micheline in
  Script.
    {
      code =
        lazy_expr
          (strip_locations
             (Seq
                ( (),
                  [
                    Prim ((), K_parameter, [Prim ((), T_unit, [], [])], []);
                    Prim ((), K_storage, [Prim ((), T_unit, [], [])], []);
                    Prim
                      ( (),
                        K_code,
                        [
                          Seq
                            ( (),
                              [
                                Prim ((), I_CDR, [], []);
                                Prim
                                  ( (),
                                    I_NIL,
                                    [Prim ((), T_operation, [], [])],
                                    [] );
                                Prim ((), I_PAIR, [], []);
                              ] );
                        ],
                        [] );
                  ] )));
      storage = lazy_expr (strip_locations (Prim ((), D_Unit, [], [])));
    }

let dummy_script_cost = Test_tez.of_mutez_exn 9_500L

let originated_tx_rollup op =
  let nonce =
    Origination_nonce.Internal_for_tests.initial (Operation.hash_packed op)
  in
  (nonce, Tx_rollup.Internal_for_tests.originated_tx_rollup nonce)

let tx_rollup_origination ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ctxt (src : Contract.t) =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    Tx_rollup_origination
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  let op = sign account.sk ctxt to_sign_op in
  (op, originated_tx_rollup op |> snd)

let tx_rollup_submit_batch ?force_reveal ?counter ?fee ?burn_limit ?gas_limit
    ?storage_limit ctxt (source : Contract.t) (tx_rollup : Tx_rollup.t)
    (content : string) =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    (Tx_rollup_submit_batch {tx_rollup; content; burn_limit})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt to_sign_op

let tx_rollup_commit ?force_reveal ?counter ?fee ?gas_limit ?storage_limit ctxt
    (source : Contract.t) (tx_rollup : Tx_rollup.t)
    (commitment : Tx_rollup_commitment.Full.t) =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    (Tx_rollup_commit {tx_rollup; commitment})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt to_sign_op

let tx_rollup_return_bond ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ctxt (source : Contract.t) (tx_rollup : Tx_rollup.t) =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    (Tx_rollup_return_bond {tx_rollup})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt to_sign_op

let tx_rollup_finalize ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ctxt (source : Contract.t) (tx_rollup : Tx_rollup.t) =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    (Tx_rollup_finalize_commitment {tx_rollup})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt to_sign_op

let tx_rollup_remove_commitment ?force_reveal ?counter ?fee ?gas_limit
    ?storage_limit ctxt (source : Contract.t) (tx_rollup : Tx_rollup.t) =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    (Tx_rollup_remove_commitment {tx_rollup})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt to_sign_op

let tx_rollup_dispatch_tickets ?force_reveal ?counter ?fee ?gas_limit
    ?storage_limit ctxt ~(source : Contract.t) ~message_index
    ~message_result_path tx_rollup level context_hash tickets_info =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    (Tx_rollup_dispatch_tickets
       {
         tx_rollup;
         level;
         context_hash;
         message_index;
         tickets_info;
         message_result_path;
       })
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt to_sign_op

let transfer_ticket ?force_reveal ?counter ?fee ?gas_limit ?storage_limit ctxt
    ~(source : Contract.t) ~contents ~ty ~ticketer ~amount ~destination
    ~entrypoint =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    (Transfer_ticket {contents; ty; ticketer; amount; destination; entrypoint})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt to_sign_op

let tx_rollup_raw_reject ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ctxt (source : Contract.t) (tx_rollup : Tx_rollup.t)
    (level : Tx_rollup_level.t) (message : Tx_rollup_message.t)
    ~(message_position : int) ~(message_path : Tx_rollup_inbox.Merkle.path)
    ~message_result_hash ~message_result_path
    ~(proof : Tx_rollup_l2_proof.serialized)
    ~(previous_message_result : Tx_rollup_message_result.t)
    ~previous_message_result_path =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    (Tx_rollup_rejection
       {
         tx_rollup;
         level;
         message;
         message_position;
         message_path;
         message_result_hash;
         proof;
         previous_message_result;
         previous_message_result_path;
         message_result_path;
       })
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt to_sign_op

let tx_rollup_reject ?force_reveal ?counter ?fee ?gas_limit ?storage_limit ctxt
    (source : Contract.t) (tx_rollup : Tx_rollup.t) (level : Tx_rollup_level.t)
    (message : Tx_rollup_message.t) ~(message_position : int)
    ~(message_path : Tx_rollup_inbox.Merkle.path) ~message_result_hash
    ~message_result_path ~(proof : Tx_rollup_l2_proof.t)
    ~(previous_message_result : Tx_rollup_message_result.t)
    ~previous_message_result_path =
  let proof = Tx_rollup_l2_proof.serialize_proof_exn proof in
  tx_rollup_raw_reject
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ctxt
    source
    tx_rollup
    level
    message
    ~message_position
    ~message_path
    ~message_result_hash
    ~message_result_path
    ~proof
    ~previous_message_result
    ~previous_message_result_path

let originated_sc_rollup op =
  let packed = Operation.hash_packed op in
  let nonce = Origination_nonce.Internal_for_tests.initial packed in
  Sc_rollup.Internal_for_tests.originated_sc_rollup nonce

let sc_rollup_origination ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ?origination_proof ctxt (src : Contract.t) kind ~boot_sector ~parameters_ty
    =
  let open Lwt_result_syntax in
  let* origination_proof =
    Sc_rollup_helpers.wrap_origination_proof
      ~boot_sector
      ~kind
      origination_proof
  in

  let (module PVM) = Sc_rollup.wrapped_proof_module origination_proof in
  let origination_proof =
    Data_encoding.Binary.to_string_exn PVM.proof_encoding PVM.proof
  in
  let* to_sign_op =
    manager_operation
      ?force_reveal
      ?counter
      ?fee
      ?gas_limit
      ?storage_limit
      ~source:src
      ctxt
      (Sc_rollup_originate {kind; boot_sector; origination_proof; parameters_ty})
  in
  let* account = Context.Contract.manager ctxt src in
  let op = sign account.sk ctxt to_sign_op in
  let t = originated_sc_rollup op |> fun addr -> (op, addr) in
  return t

let sc_rollup_publish ?force_reveal ?counter ?fee ?gas_limit ?storage_limit ctxt
    (src : Contract.t) rollup commitment =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Sc_rollup_publish {rollup; commitment})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  sign account.sk ctxt to_sign_op

let sc_rollup_cement ?force_reveal ?counter ?fee ?gas_limit ?storage_limit ctxt
    (src : Contract.t) rollup commitment =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Sc_rollup_cement {rollup; commitment})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  sign account.sk ctxt to_sign_op

let sc_rollup_execute_outbox_message ?counter ?fee ?gas_limit ?storage_limit
    ?force_reveal ctxt (src : Contract.t) rollup cemented_commitment
    ~output_proof =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Sc_rollup_execute_outbox_message
       {rollup; cemented_commitment; output_proof})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  sign account.sk ctxt to_sign_op

let sc_rollup_recover_bond ?counter ?fee ?gas_limit ?storage_limit ?force_reveal
    ctxt (source : Contract.t) (sc_rollup : Sc_rollup.t) =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source
    ctxt
    (Sc_rollup_recover_bond {sc_rollup})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt source >|=? fun account ->
  sign account.sk ctxt to_sign_op

let sc_rollup_add_messages ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ctxt (src : Contract.t) rollup messages =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Sc_rollup_add_messages {rollup; messages})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  sign account.sk ctxt to_sign_op

let sc_rollup_refute ?force_reveal ?counter ?fee ?gas_limit ?storage_limit ctxt
    (src : Contract.t) rollup opponent refutation =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Sc_rollup_refute {rollup; opponent; refutation})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  sign account.sk ctxt to_sign_op

let sc_rollup_timeout ?force_reveal ?counter ?fee ?gas_limit ?storage_limit ctxt
    (src : Contract.t) rollup stakers =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Sc_rollup_timeout {rollup; stakers})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  sign account.sk ctxt to_sign_op

let dal_publish_slot_header ?force_reveal ?counter ?fee ?gas_limit
    ?storage_limit ctxt (src : Contract.t) slot_header =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Dal_publish_slot_header {slot_header})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  sign account.sk ctxt to_sign_op

let originated_zk_rollup op =
  let packed = Operation.hash_packed op in
  let nonce = Origination_nonce.Internal_for_tests.initial packed in
  Zk_rollup.Internal_for_tests.originated_zk_rollup nonce

let zk_rollup_origination ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ctxt (src : Contract.t) ~public_parameters ~circuits_info ~init_state
    ~nb_ops =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Zk_rollup_origination
       {public_parameters; circuits_info; init_state; nb_ops})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  let op = sign account.sk ctxt to_sign_op in
  originated_zk_rollup op |> fun addr -> (op, addr)

let update_consensus_key ?force_reveal ?counter ?fee ?gas_limit ?storage_limit
    ctxt (src : Contract.t) pkh =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Update_consensus_key pkh)
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  sign account.sk ctxt to_sign_op

let drain_delegate ctxt ~consensus_key ~delegate ~destination =
  let contents =
    Single (Drain_delegate {consensus_key; delegate; destination})
  in
  Context.Contract.manager ctxt (Contract.Implicit consensus_key)
  >|=? fun account -> sign account.sk ctxt (Contents_list contents)

let zk_rollup_publish ?force_reveal ?counter ?fee ?gas_limit ?storage_limit ctxt
    (src : Contract.t) ~zk_rollup ~ops =
  manager_operation
    ?force_reveal
    ?counter
    ?fee
    ?gas_limit
    ?storage_limit
    ~source:src
    ctxt
    (Zk_rollup_publish {zk_rollup; ops})
  >>=? fun to_sign_op ->
  Context.Contract.manager ctxt src >|=? fun account ->
  sign account.sk ctxt to_sign_op
