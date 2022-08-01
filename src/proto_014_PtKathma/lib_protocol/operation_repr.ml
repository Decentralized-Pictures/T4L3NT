(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(* Tezos Protocol Implementation - Low level Repr. of Operations *)

module Kind = struct
  type preendorsement_consensus_kind = Preendorsement_consensus_kind

  type endorsement_consensus_kind = Endorsement_consensus_kind

  type 'a consensus =
    | Preendorsement_kind : preendorsement_consensus_kind consensus
    | Endorsement_kind : endorsement_consensus_kind consensus

  type preendorsement = preendorsement_consensus_kind consensus

  type endorsement = endorsement_consensus_kind consensus

  type dal_slot_availability = Dal_slot_availability_kind

  type seed_nonce_revelation = Seed_nonce_revelation_kind

  type vdf_revelation = Vdf_revelation_kind

  type 'a double_consensus_operation_evidence =
    | Double_consensus_operation_evidence

  type double_endorsement_evidence =
    endorsement_consensus_kind double_consensus_operation_evidence

  type double_preendorsement_evidence =
    preendorsement_consensus_kind double_consensus_operation_evidence

  type double_baking_evidence = Double_baking_evidence_kind

  type activate_account = Activate_account_kind

  type proposals = Proposals_kind

  type ballot = Ballot_kind

  type reveal = Reveal_kind

  type transaction = Transaction_kind

  type origination = Origination_kind

  type delegation = Delegation_kind

  type event = Event_kind

  type set_deposits_limit = Set_deposits_limit_kind

  type increase_paid_storage = Increase_paid_storage_kind

  type failing_noop = Failing_noop_kind

  type register_global_constant = Register_global_constant_kind

  type tx_rollup_origination = Tx_rollup_origination_kind

  type tx_rollup_submit_batch = Tx_rollup_submit_batch_kind

  type tx_rollup_commit = Tx_rollup_commit_kind

  type tx_rollup_return_bond = Tx_rollup_return_bond_kind

  type tx_rollup_finalize_commitment = Tx_rollup_finalize_commitment_kind

  type tx_rollup_remove_commitment = Tx_rollup_remove_commitment_kind

  type tx_rollup_rejection = Tx_rollup_rejection_kind

  type tx_rollup_dispatch_tickets = Tx_rollup_dispatch_tickets_kind

  type transfer_ticket = Transfer_ticket_kind

  type dal_publish_slot_header = Dal_publish_slot_header_kind

  type sc_rollup_originate = Sc_rollup_originate_kind

  type sc_rollup_add_messages = Sc_rollup_add_messages_kind

  type sc_rollup_cement = Sc_rollup_cement_kind

  type sc_rollup_publish = Sc_rollup_publish_kind

  type sc_rollup_refute = Sc_rollup_refute_kind

  type sc_rollup_timeout = Sc_rollup_timeout_kind

  type sc_rollup_execute_outbox_message =
    | Sc_rollup_execute_outbox_message_kind

  type sc_rollup_recover_bond = Sc_rollup_recover_bond_kind

  type sc_rollup_dal_slot_subscribe = Sc_rollup_dal_slot_subscribe_kind

  type 'a manager =
    | Reveal_manager_kind : reveal manager
    | Transaction_manager_kind : transaction manager
    | Origination_manager_kind : origination manager
    | Delegation_manager_kind : delegation manager
    | Event_manager_kind : event manager
    | Register_global_constant_manager_kind : register_global_constant manager
    | Set_deposits_limit_manager_kind : set_deposits_limit manager
    | Increase_paid_storage_manager_kind : increase_paid_storage manager
    | Tx_rollup_origination_manager_kind : tx_rollup_origination manager
    | Tx_rollup_submit_batch_manager_kind : tx_rollup_submit_batch manager
    | Tx_rollup_commit_manager_kind : tx_rollup_commit manager
    | Tx_rollup_return_bond_manager_kind : tx_rollup_return_bond manager
    | Tx_rollup_finalize_commitment_manager_kind
        : tx_rollup_finalize_commitment manager
    | Tx_rollup_remove_commitment_manager_kind
        : tx_rollup_remove_commitment manager
    | Tx_rollup_rejection_manager_kind : tx_rollup_rejection manager
    | Tx_rollup_dispatch_tickets_manager_kind
        : tx_rollup_dispatch_tickets manager
    | Transfer_ticket_manager_kind : transfer_ticket manager
    | Dal_publish_slot_header_manager_kind : dal_publish_slot_header manager
    | Sc_rollup_originate_manager_kind : sc_rollup_originate manager
    | Sc_rollup_add_messages_manager_kind : sc_rollup_add_messages manager
    | Sc_rollup_cement_manager_kind : sc_rollup_cement manager
    | Sc_rollup_publish_manager_kind : sc_rollup_publish manager
    | Sc_rollup_refute_manager_kind : sc_rollup_refute manager
    | Sc_rollup_timeout_manager_kind : sc_rollup_timeout manager
    | Sc_rollup_execute_outbox_message_manager_kind
        : sc_rollup_execute_outbox_message manager
    | Sc_rollup_recover_bond_manager_kind : sc_rollup_recover_bond manager
    | Sc_rollup_dal_slot_subscribe_manager_kind
        : sc_rollup_dal_slot_subscribe manager
end

type 'a consensus_operation_type =
  | Endorsement : Kind.endorsement consensus_operation_type
  | Preendorsement : Kind.preendorsement consensus_operation_type

let pp_operation_kind (type kind) ppf
    (operation_kind : kind consensus_operation_type) =
  match operation_kind with
  | Endorsement -> Format.fprintf ppf "Endorsement"
  | Preendorsement -> Format.fprintf ppf "Preendorsement"

type consensus_content = {
  slot : Slot_repr.t;
  level : Raw_level_repr.t;
  (* The level is not required to validate an endorsement when it corresponds
     to the current payload, but if we want to filter endorsements, we need
     the level. *)
  round : Round_repr.t;
  block_payload_hash : Block_payload_hash.t;
      (* NOTE: This could be just the hash of the set of operations (the
         actual payload). The grandfather block hash should already be
         fixed by the operation.shell.branch field.  This is not really
         important but could make things easier for debugging *)
}

let consensus_content_encoding =
  let open Data_encoding in
  conv
    (fun {slot; level; round; block_payload_hash} ->
      (slot, level, round, block_payload_hash))
    (fun (slot, level, round, block_payload_hash) ->
      {slot; level; round; block_payload_hash})
    (obj4
       (req "slot" Slot_repr.encoding)
       (req "level" Raw_level_repr.encoding)
       (req "round" Round_repr.encoding)
       (req "block_payload_hash" Block_payload_hash.encoding))

let pp_consensus_content ppf content =
  Format.fprintf
    ppf
    "(%ld, %a, %a, %a)"
    (Raw_level_repr.to_int32 content.level)
    Round_repr.pp
    content.round
    Slot_repr.pp
    content.slot
    Block_payload_hash.pp_short
    content.block_payload_hash

type consensus_watermark =
  | Endorsement of Chain_id.t
  | Preendorsement of Chain_id.t
  | Dal_slot_availability of Chain_id.t

let bytes_of_consensus_watermark = function
  | Preendorsement chain_id ->
      Bytes.cat (Bytes.of_string "\x12") (Chain_id.to_bytes chain_id)
  | Dal_slot_availability chain_id
  (* We reuse the watermark of an endorsement. This is because this
     operation is temporary and aims to be merged with an endorsement
     later on. Moreover, there is a leak of abstraction with the shell
     which makes adding a new watermark a bit awkward. *)
  | Endorsement chain_id ->
      Bytes.cat (Bytes.of_string "\x13") (Chain_id.to_bytes chain_id)

let to_watermark w = Signature.Custom (bytes_of_consensus_watermark w)

let of_watermark = function
  | Signature.Custom b ->
      if Compare.Int.(Bytes.length b > 0) then
        match Bytes.get b 0 with
        | '\x12' ->
            Option.map
              (fun chain_id -> Endorsement chain_id)
              (Chain_id.of_bytes_opt (Bytes.sub b 1 (Bytes.length b - 1)))
        | '\x13' ->
            Option.map
              (fun chain_id -> Preendorsement chain_id)
              (Chain_id.of_bytes_opt (Bytes.sub b 1 (Bytes.length b - 1)))
        | '\x14' ->
            Option.map
              (fun chain_id -> Dal_slot_availability chain_id)
              (Chain_id.of_bytes_opt (Bytes.sub b 1 (Bytes.length b - 1)))
        | _ -> None
      else None
  | _ -> None

type raw = Operation.t = {shell : Operation.shell_header; proto : bytes}

let raw_encoding = Operation.encoding

type 'kind operation = {
  shell : Operation.shell_header;
  protocol_data : 'kind protocol_data;
}

and 'kind protocol_data = {
  contents : 'kind contents_list;
  signature : Signature.t option;
}

and _ contents_list =
  | Single : 'kind contents -> 'kind contents_list
  | Cons :
      'kind Kind.manager contents * 'rest Kind.manager contents_list
      -> ('kind * 'rest) Kind.manager contents_list

and _ contents =
  | Preendorsement : consensus_content -> Kind.preendorsement contents
  | Endorsement : consensus_content -> Kind.endorsement contents
  | Dal_slot_availability :
      Signature.Public_key_hash.t * Dal_endorsement_repr.t
      -> Kind.dal_slot_availability contents
  | Seed_nonce_revelation : {
      level : Raw_level_repr.t;
      nonce : Seed_repr.nonce;
    }
      -> Kind.seed_nonce_revelation contents
  | Vdf_revelation : {
      solution : Seed_repr.vdf_solution;
    }
      -> Kind.vdf_revelation contents
  | Double_preendorsement_evidence : {
      op1 : Kind.preendorsement operation;
      op2 : Kind.preendorsement operation;
    }
      -> Kind.double_preendorsement_evidence contents
  | Double_endorsement_evidence : {
      op1 : Kind.endorsement operation;
      op2 : Kind.endorsement operation;
    }
      -> Kind.double_endorsement_evidence contents
  | Double_baking_evidence : {
      bh1 : Block_header_repr.t;
      bh2 : Block_header_repr.t;
    }
      -> Kind.double_baking_evidence contents
  | Activate_account : {
      id : Ed25519.Public_key_hash.t;
      activation_code : Blinded_public_key_hash.activation_code;
    }
      -> Kind.activate_account contents
  | Proposals : {
      source : Signature.Public_key_hash.t;
      period : int32;
      proposals : Protocol_hash.t list;
    }
      -> Kind.proposals contents
  | Ballot : {
      source : Signature.Public_key_hash.t;
      period : int32;
      proposal : Protocol_hash.t;
      ballot : Vote_repr.ballot;
    }
      -> Kind.ballot contents
  | Failing_noop : string -> Kind.failing_noop contents
  | Manager_operation : {
      source : Signature.public_key_hash;
      fee : Tez_repr.tez;
      counter : counter;
      operation : 'kind manager_operation;
      gas_limit : Gas_limit_repr.Arith.integral;
      storage_limit : Z.t;
    }
      -> 'kind Kind.manager contents

and _ manager_operation =
  | Reveal : Signature.Public_key.t -> Kind.reveal manager_operation
  | Transaction : {
      amount : Tez_repr.tez;
      parameters : Script_repr.lazy_expr;
      entrypoint : Entrypoint_repr.t;
      destination : Contract_repr.t;
    }
      -> Kind.transaction manager_operation
  | Origination : {
      delegate : Signature.Public_key_hash.t option;
      script : Script_repr.t;
      credit : Tez_repr.tez;
    }
      -> Kind.origination manager_operation
  | Delegation :
      Signature.Public_key_hash.t option
      -> Kind.delegation manager_operation
  | Register_global_constant : {
      value : Script_repr.lazy_expr;
    }
      -> Kind.register_global_constant manager_operation
  | Set_deposits_limit :
      Tez_repr.t option
      -> Kind.set_deposits_limit manager_operation
  | Increase_paid_storage : {
      amount_in_bytes : Z.t;
      destination : Contract_hash.t;
    }
      -> Kind.increase_paid_storage manager_operation
  | Tx_rollup_origination : Kind.tx_rollup_origination manager_operation
  | Tx_rollup_submit_batch : {
      tx_rollup : Tx_rollup_repr.t;
      content : string;
      burn_limit : Tez_repr.t option;
    }
      -> Kind.tx_rollup_submit_batch manager_operation
  | Tx_rollup_commit : {
      tx_rollup : Tx_rollup_repr.t;
      commitment : Tx_rollup_commitment_repr.Full.t;
    }
      -> Kind.tx_rollup_commit manager_operation
  | Tx_rollup_return_bond : {
      tx_rollup : Tx_rollup_repr.t;
    }
      -> Kind.tx_rollup_return_bond manager_operation
  | Tx_rollup_finalize_commitment : {
      tx_rollup : Tx_rollup_repr.t;
    }
      -> Kind.tx_rollup_finalize_commitment manager_operation
  | Tx_rollup_remove_commitment : {
      tx_rollup : Tx_rollup_repr.t;
    }
      -> Kind.tx_rollup_remove_commitment manager_operation
  | Tx_rollup_rejection : {
      tx_rollup : Tx_rollup_repr.t;
      level : Tx_rollup_level_repr.t;
      message : Tx_rollup_message_repr.t;
      message_position : int;
      message_path : Tx_rollup_inbox_repr.Merkle.path;
      message_result_hash : Tx_rollup_message_result_hash_repr.t;
      message_result_path : Tx_rollup_commitment_repr.Merkle.path;
      previous_message_result : Tx_rollup_message_result_repr.t;
      previous_message_result_path : Tx_rollup_commitment_repr.Merkle.path;
      proof : Tx_rollup_l2_proof.t;
    }
      -> Kind.tx_rollup_rejection manager_operation
  | Tx_rollup_dispatch_tickets : {
      tx_rollup : Tx_rollup_repr.t;
      level : Tx_rollup_level_repr.t;
      context_hash : Context_hash.t;
      message_index : int;
      message_result_path : Tx_rollup_commitment_repr.Merkle.path;
      tickets_info : Tx_rollup_reveal_repr.t list;
    }
      -> Kind.tx_rollup_dispatch_tickets manager_operation
  | Transfer_ticket : {
      contents : Script_repr.lazy_expr;
      ty : Script_repr.lazy_expr;
      ticketer : Contract_repr.t;
      amount : Z.t;
      destination : Contract_repr.t;
      entrypoint : Entrypoint_repr.t;
    }
      -> Kind.transfer_ticket manager_operation
  | Dal_publish_slot_header : {
      slot : Dal_slot_repr.t;
    }
      -> Kind.dal_publish_slot_header manager_operation
  | Sc_rollup_originate : {
      kind : Sc_rollups.Kind.t;
      boot_sector : string;
      parameters_ty : Script_repr.lazy_expr;
    }
      -> Kind.sc_rollup_originate manager_operation
  | Sc_rollup_add_messages : {
      rollup : Sc_rollup_repr.t;
      messages : string list;
    }
      -> Kind.sc_rollup_add_messages manager_operation
  | Sc_rollup_cement : {
      rollup : Sc_rollup_repr.t;
      commitment : Sc_rollup_commitment_repr.Hash.t;
    }
      -> Kind.sc_rollup_cement manager_operation
  | Sc_rollup_publish : {
      rollup : Sc_rollup_repr.t;
      commitment : Sc_rollup_commitment_repr.t;
    }
      -> Kind.sc_rollup_publish manager_operation
  | Sc_rollup_refute : {
      rollup : Sc_rollup_repr.t;
      opponent : Sc_rollup_repr.Staker.t;
      refutation : Sc_rollup_game_repr.refutation;
      is_opening_move : bool;
    }
      -> Kind.sc_rollup_refute manager_operation
  | Sc_rollup_timeout : {
      rollup : Sc_rollup_repr.t;
      stakers : Sc_rollup_game_repr.Index.t;
    }
      -> Kind.sc_rollup_timeout manager_operation
  | Sc_rollup_execute_outbox_message : {
      rollup : Sc_rollup_repr.t;
      cemented_commitment : Sc_rollup_commitment_repr.Hash.t;
      outbox_level : Raw_level_repr.t;
      message_index : int;
      inclusion_proof : string;
      message : string;
    }
      -> Kind.sc_rollup_execute_outbox_message manager_operation
  | Sc_rollup_recover_bond : {
      sc_rollup : Sc_rollup_repr.t;
    }
      -> Kind.sc_rollup_recover_bond manager_operation
  | Sc_rollup_dal_slot_subscribe : {
      rollup : Sc_rollup_repr.t;
      slot_index : Dal_slot_repr.Index.t;
    }
      -> Kind.sc_rollup_dal_slot_subscribe manager_operation

and counter = Z.t

let manager_kind : type kind. kind manager_operation -> kind Kind.manager =
  function
  | Reveal _ -> Kind.Reveal_manager_kind
  | Transaction _ -> Kind.Transaction_manager_kind
  | Origination _ -> Kind.Origination_manager_kind
  | Delegation _ -> Kind.Delegation_manager_kind
  | Register_global_constant _ -> Kind.Register_global_constant_manager_kind
  | Set_deposits_limit _ -> Kind.Set_deposits_limit_manager_kind
  | Increase_paid_storage _ -> Kind.Increase_paid_storage_manager_kind
  | Tx_rollup_origination -> Kind.Tx_rollup_origination_manager_kind
  | Tx_rollup_submit_batch _ -> Kind.Tx_rollup_submit_batch_manager_kind
  | Tx_rollup_commit _ -> Kind.Tx_rollup_commit_manager_kind
  | Tx_rollup_return_bond _ -> Kind.Tx_rollup_return_bond_manager_kind
  | Tx_rollup_finalize_commitment _ ->
      Kind.Tx_rollup_finalize_commitment_manager_kind
  | Tx_rollup_remove_commitment _ ->
      Kind.Tx_rollup_remove_commitment_manager_kind
  | Tx_rollup_rejection _ -> Kind.Tx_rollup_rejection_manager_kind
  | Tx_rollup_dispatch_tickets _ -> Kind.Tx_rollup_dispatch_tickets_manager_kind
  | Transfer_ticket _ -> Kind.Transfer_ticket_manager_kind
  | Dal_publish_slot_header _ -> Kind.Dal_publish_slot_header_manager_kind
  | Sc_rollup_originate _ -> Kind.Sc_rollup_originate_manager_kind
  | Sc_rollup_add_messages _ -> Kind.Sc_rollup_add_messages_manager_kind
  | Sc_rollup_cement _ -> Kind.Sc_rollup_cement_manager_kind
  | Sc_rollup_publish _ -> Kind.Sc_rollup_publish_manager_kind
  | Sc_rollup_refute _ -> Kind.Sc_rollup_refute_manager_kind
  | Sc_rollup_timeout _ -> Kind.Sc_rollup_timeout_manager_kind
  | Sc_rollup_execute_outbox_message _ ->
      Kind.Sc_rollup_execute_outbox_message_manager_kind
  | Sc_rollup_recover_bond _ -> Kind.Sc_rollup_recover_bond_manager_kind
  | Sc_rollup_dal_slot_subscribe _ ->
      Kind.Sc_rollup_dal_slot_subscribe_manager_kind

type packed_manager_operation =
  | Manager : 'kind manager_operation -> packed_manager_operation

type packed_contents = Contents : 'kind contents -> packed_contents

type packed_contents_list =
  | Contents_list : 'kind contents_list -> packed_contents_list

type packed_protocol_data =
  | Operation_data : 'kind protocol_data -> packed_protocol_data

type packed_operation = {
  shell : Operation.shell_header;
  protocol_data : packed_protocol_data;
}

let pack ({shell; protocol_data} : _ operation) : packed_operation =
  {shell; protocol_data = Operation_data protocol_data}

let rec contents_list_to_list : type a. a contents_list -> _ = function
  | Single o -> [Contents o]
  | Cons (o, os) -> Contents o :: contents_list_to_list os

let to_list = function Contents_list l -> contents_list_to_list l

(* This first version of of_list has the type (_, string) result expected by
   the conv_with_guard combinator of Data_encoding. For a more conventional
   return type see [of_list] below. *)
let rec of_list_internal = function
  | [] -> Error "Operation lists should not be empty."
  | [Contents o] -> Ok (Contents_list (Single o))
  | Contents o :: os -> (
      of_list_internal os >>? fun (Contents_list os) ->
      match (o, os) with
      | Manager_operation _, Single (Manager_operation _) ->
          Ok (Contents_list (Cons (o, os)))
      | Manager_operation _, Cons _ -> Ok (Contents_list (Cons (o, os)))
      | _ ->
          Error
            "Operation list of length > 1 should only contains manager \
             operations.")

type error += Contents_list_error of string (* `Permanent *)

let of_list l =
  match of_list_internal l with
  | Ok contents -> Ok contents
  | Error s -> error @@ Contents_list_error s

let tx_rollup_operation_tag_offset = 150

let tx_rollup_operation_origination_tag = tx_rollup_operation_tag_offset + 0

let tx_rollup_operation_submit_batch_tag = tx_rollup_operation_tag_offset + 1

let tx_rollup_operation_commit_tag = tx_rollup_operation_tag_offset + 2

let tx_rollup_operation_return_bond_tag = tx_rollup_operation_tag_offset + 3

let tx_rollup_operation_finalize_commitment_tag =
  tx_rollup_operation_tag_offset + 4

let tx_rollup_operation_remove_commitment_tag =
  tx_rollup_operation_tag_offset + 5

let tx_rollup_operation_rejection_tag = tx_rollup_operation_tag_offset + 6

let tx_rollup_operation_dispatch_tickets_tag =
  tx_rollup_operation_tag_offset + 7

let transfer_ticket_tag = tx_rollup_operation_tag_offset + 8

let sc_rollup_operation_tag_offset = 200

let sc_rollup_operation_origination_tag = sc_rollup_operation_tag_offset + 0

let sc_rollup_operation_add_message_tag = sc_rollup_operation_tag_offset + 1

let sc_rollup_operation_cement_tag = sc_rollup_operation_tag_offset + 2

let sc_rollup_operation_publish_tag = sc_rollup_operation_tag_offset + 3

let sc_rollup_operation_refute_tag = sc_rollup_operation_tag_offset + 4

let sc_rollup_operation_timeout_tag = sc_rollup_operation_tag_offset + 5

let sc_rollup_execute_outbox_message_tag = sc_rollup_operation_tag_offset + 6

let sc_rollup_operation_recover_bond_tag = sc_rollup_operation_tag_offset + 7

let sc_rollup_operation_dal_slot_subscribe_tag =
  sc_rollup_operation_tag_offset + 8

let dal_offset = 230

let dal_publish_slot_header_tag = dal_offset + 0

module Encoding = struct
  open Data_encoding

  let case tag name args proj inj =
    case
      tag
      ~title:(String.capitalize_ascii name)
      (merge_objs (obj1 (req "kind" (constant name))) args)
      (fun x -> match proj x with None -> None | Some x -> Some ((), x))
      (fun ((), x) -> inj x)

  module Manager_operations = struct
    type 'kind case =
      | MCase : {
          tag : int;
          name : string;
          encoding : 'a Data_encoding.t;
          select : packed_manager_operation -> 'kind manager_operation option;
          proj : 'kind manager_operation -> 'a;
          inj : 'a -> 'kind manager_operation;
        }
          -> 'kind case
    [@@coq_force_gadt]

    let[@coq_axiom_with_reason "gadt"] reveal_case =
      MCase
        {
          tag = 0;
          name = "reveal";
          encoding = obj1 (req "public_key" Signature.Public_key.encoding);
          select = (function Manager (Reveal _ as op) -> Some op | _ -> None);
          proj = (function Reveal pkh -> pkh);
          inj = (fun pkh -> Reveal pkh);
        }

    let[@coq_axiom_with_reason "gadt"] transaction_case =
      MCase
        {
          tag = 1;
          name = "transaction";
          encoding =
            obj3
              (req "amount" Tez_repr.encoding)
              (req "destination" Contract_repr.encoding)
              (opt
                 "parameters"
                 (obj2
                    (req "entrypoint" Entrypoint_repr.smart_encoding)
                    (req "value" Script_repr.lazy_expr_encoding)));
          select =
            (function Manager (Transaction _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Transaction {amount; destination; parameters; entrypoint} ->
                let parameters =
                  if
                    Script_repr.is_unit_parameter parameters
                    && Entrypoint_repr.is_default entrypoint
                  then None
                  else Some (entrypoint, parameters)
                in
                (amount, destination, parameters));
          inj =
            (fun (amount, destination, parameters) ->
              let entrypoint, parameters =
                match parameters with
                | None -> (Entrypoint_repr.default, Script_repr.unit_parameter)
                | Some (entrypoint, value) -> (entrypoint, value)
              in
              Transaction {amount; destination; parameters; entrypoint});
        }

    let[@coq_axiom_with_reason "gadt"] origination_case =
      MCase
        {
          tag = 2;
          name = "origination";
          encoding =
            obj3
              (req "balance" Tez_repr.encoding)
              (opt "delegate" Signature.Public_key_hash.encoding)
              (req "script" Script_repr.encoding);
          select =
            (function Manager (Origination _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Origination {credit; delegate; script} ->
                (credit, delegate, script));
          inj =
            (fun (credit, delegate, script) ->
              Origination {credit; delegate; script});
        }

    let[@coq_axiom_with_reason "gadt"] delegation_case =
      MCase
        {
          tag = 3;
          name = "delegation";
          encoding = obj1 (opt "delegate" Signature.Public_key_hash.encoding);
          select =
            (function Manager (Delegation _ as op) -> Some op | _ -> None);
          proj = (function Delegation key -> key);
          inj = (fun key -> Delegation key);
        }

    let[@coq_axiom_with_reason "gadt"] register_global_constant_case =
      MCase
        {
          tag = 4;
          name = "register_global_constant";
          encoding = obj1 (req "value" Script_repr.lazy_expr_encoding);
          select =
            (function
            | Manager (Register_global_constant _ as op) -> Some op | _ -> None);
          proj = (function Register_global_constant {value} -> value);
          inj = (fun value -> Register_global_constant {value});
        }

    let[@coq_axiom_with_reason "gadt"] set_deposits_limit_case =
      MCase
        {
          tag = 5;
          name = "set_deposits_limit";
          encoding = obj1 (opt "limit" Tez_repr.encoding);
          select =
            (function
            | Manager (Set_deposits_limit _ as op) -> Some op | _ -> None);
          proj = (function Set_deposits_limit key -> key);
          inj = (fun key -> Set_deposits_limit key);
        }

    let[@coq_axiom_with_reason "gadt"] increase_paid_storage_case =
      MCase
        {
          tag = 9;
          name = "increase_paid_storage";
          encoding =
            obj2
              (req "amount" Data_encoding.z)
              (req "destination" Contract_repr.originated_encoding);
          select =
            (function
            | Manager (Increase_paid_storage _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Increase_paid_storage {amount_in_bytes; destination} ->
                (amount_in_bytes, destination));
          inj =
            (fun (amount_in_bytes, destination) ->
              Increase_paid_storage {amount_in_bytes; destination});
        }

    let[@coq_axiom_with_reason "gadt"] tx_rollup_origination_case =
      MCase
        {
          tag = tx_rollup_operation_origination_tag;
          name = "tx_rollup_origination";
          encoding = obj1 (req "tx_rollup_origination" Data_encoding.unit);
          select =
            (function
            | Manager (Tx_rollup_origination as op) -> Some op | _ -> None);
          proj = (function Tx_rollup_origination -> ());
          inj = (fun () -> Tx_rollup_origination);
        }

    let tx_rollup_batch_content =
      (* The content of batches is a string, but stands for an immutable byte
         sequence. JSON only allows unicode strings so we use the [bytes]
         encoding which is in hexadecimal for JSON. *)
      conv Bytes.of_string Bytes.to_string bytes

    let[@coq_axiom_with_reason "gadt"] tx_rollup_submit_batch_case =
      MCase
        {
          tag = tx_rollup_operation_submit_batch_tag;
          name = "tx_rollup_submit_batch";
          encoding =
            obj3
              (req "rollup" Tx_rollup_repr.encoding)
              (req "content" tx_rollup_batch_content)
              (opt "burn_limit" Tez_repr.encoding);
          select =
            (function
            | Manager (Tx_rollup_submit_batch _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Tx_rollup_submit_batch {tx_rollup; content; burn_limit} ->
                (tx_rollup, content, burn_limit));
          inj =
            (fun (tx_rollup, content, burn_limit) ->
              Tx_rollup_submit_batch {tx_rollup; content; burn_limit});
        }

    let[@coq_axiom_with_reason "gadt"] tx_rollup_commit_case =
      MCase
        {
          tag = tx_rollup_operation_commit_tag;
          name = "tx_rollup_commit";
          encoding =
            obj2
              (req "rollup" Tx_rollup_repr.encoding)
              (req "commitment" Tx_rollup_commitment_repr.Full.encoding);
          select =
            (function
            | Manager (Tx_rollup_commit _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Tx_rollup_commit {tx_rollup; commitment} -> (tx_rollup, commitment));
          inj =
            (fun (tx_rollup, commitment) ->
              Tx_rollup_commit {tx_rollup; commitment});
        }

    let[@coq_axiom_with_reason "gadt"] tx_rollup_return_bond_case =
      MCase
        {
          tag = tx_rollup_operation_return_bond_tag;
          name = "tx_rollup_return_bond";
          encoding = obj1 (req "rollup" Tx_rollup_repr.encoding);
          select =
            (function
            | Manager (Tx_rollup_return_bond _ as op) -> Some op | _ -> None);
          proj = (function Tx_rollup_return_bond {tx_rollup} -> tx_rollup);
          inj = (fun tx_rollup -> Tx_rollup_return_bond {tx_rollup});
        }

    let[@coq_axiom_with_reason "gadt"] tx_rollup_finalize_commitment_case =
      MCase
        {
          tag = tx_rollup_operation_finalize_commitment_tag;
          name = "tx_rollup_finalize_commitment";
          encoding = obj1 (req "rollup" Tx_rollup_repr.encoding);
          select =
            (function
            | Manager (Tx_rollup_finalize_commitment _ as op) -> Some op
            | _ -> None);
          proj =
            (function Tx_rollup_finalize_commitment {tx_rollup} -> tx_rollup);
          inj = (fun tx_rollup -> Tx_rollup_finalize_commitment {tx_rollup});
        }

    let[@coq_axiom_with_reason "gadt"] tx_rollup_remove_commitment_case =
      MCase
        {
          tag = tx_rollup_operation_remove_commitment_tag;
          name = "tx_rollup_remove_commitment";
          encoding = obj1 (req "rollup" Tx_rollup_repr.encoding);
          select =
            (function
            | Manager (Tx_rollup_remove_commitment _ as op) -> Some op
            | _ -> None);
          proj =
            (function Tx_rollup_remove_commitment {tx_rollup} -> tx_rollup);
          inj = (fun tx_rollup -> Tx_rollup_remove_commitment {tx_rollup});
        }

    let[@coq_axiom_with_reason "gadt"] tx_rollup_rejection_case =
      MCase
        {
          tag = tx_rollup_operation_rejection_tag;
          name = "tx_rollup_rejection";
          encoding =
            obj10
              (req "rollup" Tx_rollup_repr.encoding)
              (req "level" Tx_rollup_level_repr.encoding)
              (req "message" Tx_rollup_message_repr.encoding)
              (req "message_position" n)
              (req "message_path" Tx_rollup_inbox_repr.Merkle.path_encoding)
              (req
                 "message_result_hash"
                 Tx_rollup_message_result_hash_repr.encoding)
              (req
                 "message_result_path"
                 Tx_rollup_commitment_repr.Merkle.path_encoding)
              (req
                 "previous_message_result"
                 Tx_rollup_message_result_repr.encoding)
              (req
                 "previous_message_result_path"
                 Tx_rollup_commitment_repr.Merkle.path_encoding)
              (req "proof" Tx_rollup_l2_proof.encoding);
          select =
            (function
            | Manager (Tx_rollup_rejection _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Tx_rollup_rejection
                {
                  tx_rollup;
                  level;
                  message;
                  message_position;
                  message_path;
                  message_result_hash;
                  message_result_path;
                  previous_message_result;
                  previous_message_result_path;
                  proof;
                } ->
                ( tx_rollup,
                  level,
                  message,
                  Z.of_int message_position,
                  message_path,
                  message_result_hash,
                  message_result_path,
                  previous_message_result,
                  previous_message_result_path,
                  proof ));
          inj =
            (fun ( tx_rollup,
                   level,
                   message,
                   message_position,
                   message_path,
                   message_result_hash,
                   message_result_path,
                   previous_message_result,
                   previous_message_result_path,
                   proof ) ->
              Tx_rollup_rejection
                {
                  tx_rollup;
                  level;
                  message;
                  message_position = Z.to_int message_position;
                  message_path;
                  message_result_hash;
                  message_result_path;
                  previous_message_result;
                  previous_message_result_path;
                  proof;
                });
        }

    let[@coq_axiom_with_reason "gadt"] tx_rollup_dispatch_tickets_case =
      MCase
        {
          tag = tx_rollup_operation_dispatch_tickets_tag;
          name = "tx_rollup_dispatch_tickets";
          encoding =
            obj6
              (req "tx_rollup" Tx_rollup_repr.encoding)
              (req "level" Tx_rollup_level_repr.encoding)
              (req "context_hash" Context_hash.encoding)
              (req "message_index" int31)
              (req
                 "message_result_path"
                 Tx_rollup_commitment_repr.Merkle.path_encoding)
              (req
                 "tickets_info"
                 (Data_encoding.list Tx_rollup_reveal_repr.encoding));
          select =
            (function
            | Manager (Tx_rollup_dispatch_tickets _ as op) -> Some op
            | _ -> None);
          proj =
            (function
            | Tx_rollup_dispatch_tickets
                {
                  tx_rollup;
                  level;
                  context_hash;
                  message_index;
                  message_result_path;
                  tickets_info;
                } ->
                ( tx_rollup,
                  level,
                  context_hash,
                  message_index,
                  message_result_path,
                  tickets_info ));
          inj =
            (fun ( tx_rollup,
                   level,
                   context_hash,
                   message_index,
                   message_result_path,
                   tickets_info ) ->
              Tx_rollup_dispatch_tickets
                {
                  tx_rollup;
                  level;
                  context_hash;
                  message_index;
                  message_result_path;
                  tickets_info;
                });
        }

    let[@coq_axiom_with_reason "gadt"] transfer_ticket_case =
      MCase
        {
          tag = transfer_ticket_tag;
          name = "transfer_ticket";
          encoding =
            obj6
              (req "ticket_contents" Script_repr.lazy_expr_encoding)
              (req "ticket_ty" Script_repr.lazy_expr_encoding)
              (req "ticket_ticketer" Contract_repr.encoding)
              (req "ticket_amount" n)
              (req "destination" Contract_repr.encoding)
              (req "entrypoint" Entrypoint_repr.simple_encoding);
          select =
            (function
            | Manager (Transfer_ticket _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Transfer_ticket
                {contents; ty; ticketer; amount; destination; entrypoint} ->
                (contents, ty, ticketer, amount, destination, entrypoint));
          inj =
            (fun (contents, ty, ticketer, amount, destination, entrypoint) ->
              Transfer_ticket
                {contents; ty; ticketer; amount; destination; entrypoint});
        }

    let[@coq_axiom_with_reason "gadt"] sc_rollup_originate_case =
      MCase
        {
          tag = sc_rollup_operation_origination_tag;
          name = "sc_rollup_originate";
          encoding =
            obj3
              (req "kind" Sc_rollups.Kind.encoding)
              (req "boot_sector" Data_encoding.string)
              (req "parameters_ty" Script_repr.lazy_expr_encoding);
          select =
            (function
            | Manager (Sc_rollup_originate _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Sc_rollup_originate {kind; boot_sector; parameters_ty} ->
                (kind, boot_sector, parameters_ty));
          inj =
            (fun (kind, boot_sector, parameters_ty) ->
              Sc_rollup_originate {kind; boot_sector; parameters_ty});
        }

    let[@coq_axiom_with_reason "gadt"] dal_publish_slot_header_case =
      MCase
        {
          tag = dal_publish_slot_header_tag;
          name = "dal_publish_slot_header";
          encoding = obj1 (req "slot" Dal_slot_repr.encoding);
          select =
            (function
            | Manager (Dal_publish_slot_header _ as op) -> Some op | _ -> None);
          proj = (function Dal_publish_slot_header {slot} -> slot);
          inj = (fun slot -> Dal_publish_slot_header {slot});
        }

    let[@coq_axiom_with_reason "gadt"] sc_rollup_add_messages_case =
      MCase
        {
          tag = sc_rollup_operation_add_message_tag;
          name = "sc_rollup_add_messages";
          encoding =
            obj2
              (req "rollup" Sc_rollup_repr.encoding)
              (req "message" (list string));
          select =
            (function
            | Manager (Sc_rollup_add_messages _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Sc_rollup_add_messages {rollup; messages} -> (rollup, messages));
          inj =
            (fun (rollup, messages) ->
              Sc_rollup_add_messages {rollup; messages});
        }

    let[@coq_axiom_with_reason "gadt"] sc_rollup_cement_case =
      MCase
        {
          tag = sc_rollup_operation_cement_tag;
          name = "sc_rollup_cement";
          encoding =
            obj2
              (req "rollup" Sc_rollup_repr.encoding)
              (req "commitment" Sc_rollup_commitment_repr.Hash.encoding);
          select =
            (function
            | Manager (Sc_rollup_cement _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Sc_rollup_cement {rollup; commitment} -> (rollup, commitment));
          inj =
            (fun (rollup, commitment) -> Sc_rollup_cement {rollup; commitment});
        }

    let[@coq_axiom_with_reason "gadt"] sc_rollup_publish_case =
      MCase
        {
          tag = sc_rollup_operation_publish_tag;
          name = "sc_rollup_publish";
          encoding =
            obj2
              (req "rollup" Sc_rollup_repr.encoding)
              (req "commitment" Sc_rollup_commitment_repr.encoding);
          select =
            (function
            | Manager (Sc_rollup_publish _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Sc_rollup_publish {rollup; commitment} -> (rollup, commitment));
          inj =
            (fun (rollup, commitment) -> Sc_rollup_publish {rollup; commitment});
        }

    let[@coq_axiom_with_reason "gadt"] sc_rollup_refute_case =
      MCase
        {
          tag = sc_rollup_operation_refute_tag;
          name = "sc_rollup_refute";
          encoding =
            obj4
              (req "rollup" Sc_rollup_repr.encoding)
              (req "opponent" Sc_rollup_repr.Staker.encoding)
              (req "refutation" Sc_rollup_game_repr.refutation_encoding)
              (req "is_opening_move" bool);
          select =
            (function
            | Manager (Sc_rollup_refute _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Sc_rollup_refute {rollup; opponent; refutation; is_opening_move}
              ->
                (rollup, opponent, refutation, is_opening_move));
          inj =
            (fun (rollup, opponent, refutation, is_opening_move) ->
              Sc_rollup_refute {rollup; opponent; refutation; is_opening_move});
        }

    let[@coq_axiom_with_reason "gadt"] sc_rollup_timeout_case =
      MCase
        {
          tag = sc_rollup_operation_timeout_tag;
          name = "sc_rollup_timeout";
          encoding =
            obj2
              (req "rollup" Sc_rollup_repr.encoding)
              (req "stakers" Sc_rollup_game_repr.Index.encoding);
          select =
            (function
            | Manager (Sc_rollup_timeout _ as op) -> Some op | _ -> None);
          proj =
            (function
            | Sc_rollup_timeout {rollup; stakers} -> (rollup, stakers));
          inj = (fun (rollup, stakers) -> Sc_rollup_timeout {rollup; stakers});
        }

    let[@coq_axiom_with_reason "gadt"] sc_rollup_execute_outbox_message_case =
      MCase
        {
          tag = sc_rollup_execute_outbox_message_tag;
          name = "sc_rollup_execute_outbox_message";
          encoding =
            obj6
              (req "rollup" Sc_rollup_repr.encoding)
              (req
                 "cemented_commitment"
                 Sc_rollup_commitment_repr.Hash.encoding)
              (req "outbox_level" Raw_level_repr.encoding)
              (req "message_index" Data_encoding.int31)
              (req "inclusion proof" Data_encoding.string)
              (req "message" Data_encoding.string);
          select =
            (function
            | Manager (Sc_rollup_execute_outbox_message _ as op) -> Some op
            | _ -> None);
          proj =
            (function
            | Sc_rollup_execute_outbox_message
                {
                  rollup;
                  cemented_commitment;
                  outbox_level;
                  message_index;
                  inclusion_proof;
                  message;
                } ->
                ( rollup,
                  cemented_commitment,
                  outbox_level,
                  message_index,
                  inclusion_proof,
                  message ));
          inj =
            (fun ( rollup,
                   cemented_commitment,
                   outbox_level,
                   message_index,
                   inclusion_proof,
                   message ) ->
              Sc_rollup_execute_outbox_message
                {
                  rollup;
                  cemented_commitment;
                  outbox_level;
                  message_index;
                  inclusion_proof;
                  message;
                });
        }

    let[@coq_axiom_with_reason "gadt"] sc_rollup_recover_bond_case =
      MCase
        {
          tag = sc_rollup_operation_recover_bond_tag;
          name = "sc_rollup_recover_bond";
          encoding = obj1 (req "rollup" Sc_rollup_repr.Address.encoding);
          select =
            (function
            | Manager (Sc_rollup_recover_bond _ as op) -> Some op | _ -> None);
          proj = (function Sc_rollup_recover_bond {sc_rollup} -> sc_rollup);
          inj = (fun sc_rollup -> Sc_rollup_recover_bond {sc_rollup});
        }

    let[@coq_axiom_with_reason "gadt"] sc_rollup_dal_slot_subscribe_case =
      MCase
        {
          tag = sc_rollup_operation_dal_slot_subscribe_tag;
          name = "sc_rollup_dal_slot_subscribe";
          encoding =
            obj2
              (req "rollup" Sc_rollup_repr.encoding)
              (req "slot_index" Dal_slot_repr.Index.encoding);
          select =
            (function
            | Manager (Sc_rollup_dal_slot_subscribe _ as op) -> Some op
            | _ -> None);
          proj =
            (function
            | Sc_rollup_dal_slot_subscribe {rollup; slot_index} ->
                (rollup, slot_index));
          inj =
            (fun (rollup, slot_index) ->
              Sc_rollup_dal_slot_subscribe {rollup; slot_index});
        }
  end

  type 'b case =
    | Case : {
        tag : int;
        name : string;
        encoding : 'a Data_encoding.t;
        select : packed_contents -> 'b contents option;
        proj : 'b contents -> 'a;
        inj : 'a -> 'b contents;
      }
        -> 'b case

  let preendorsement_case =
    Case
      {
        tag = 20;
        name = "preendorsement";
        encoding = consensus_content_encoding;
        select =
          (function Contents (Preendorsement _ as op) -> Some op | _ -> None);
        proj = (fun (Preendorsement preendorsement) -> preendorsement);
        inj = (fun preendorsement -> Preendorsement preendorsement);
      }

  let preendorsement_encoding =
    let make (Case {tag; name; encoding; select = _; proj; inj}) =
      case (Tag tag) name encoding (fun o -> Some (proj o)) (fun x -> inj x)
    in
    let to_list : Kind.preendorsement contents_list -> _ = function
      | Single o -> o
    in
    let of_list : Kind.preendorsement contents -> _ = function
      | o -> Single o
    in
    def "inlined.preendorsement"
    @@ conv
         (fun ({shell; protocol_data = {contents; signature}} : _ operation) ->
           (shell, (contents, signature)))
         (fun (shell, (contents, signature)) : _ operation ->
           {shell; protocol_data = {contents; signature}})
         (merge_objs
            Operation.shell_header_encoding
            (obj2
               (req
                  "operations"
                  (conv to_list of_list
                  @@ def "inlined.preendorsement.contents"
                  @@ union [make preendorsement_case]))
               (varopt "signature" Signature.encoding)))

  let endorsement_encoding =
    obj4
      (req "slot" Slot_repr.encoding)
      (req "level" Raw_level_repr.encoding)
      (req "round" Round_repr.encoding)
      (req "block_payload_hash" Block_payload_hash.encoding)

  let endorsement_case =
    Case
      {
        tag = 21;
        name = "endorsement";
        encoding = endorsement_encoding;
        select =
          (function Contents (Endorsement _ as op) -> Some op | _ -> None);
        proj =
          (fun [@coq_match_with_default] (Endorsement consensus_content) ->
            ( consensus_content.slot,
              consensus_content.level,
              consensus_content.round,
              consensus_content.block_payload_hash ));
        inj =
          (fun (slot, level, round, block_payload_hash) ->
            Endorsement {slot; level; round; block_payload_hash});
      }

  let[@coq_axiom_with_reason "gadt"] endorsement_encoding =
    let make (Case {tag; name; encoding; select = _; proj; inj}) =
      case (Tag tag) name encoding (fun o -> Some (proj o)) (fun x -> inj x)
    in
    let to_list : Kind.endorsement contents_list -> _ = fun (Single o) -> o in
    let of_list : Kind.endorsement contents -> _ = fun o -> Single o in
    def "inlined.endorsement"
    @@ conv
         (fun ({shell; protocol_data = {contents; signature}} : _ operation) ->
           (shell, (contents, signature)))
         (fun (shell, (contents, signature)) : _ operation ->
           {shell; protocol_data = {contents; signature}})
         (merge_objs
            Operation.shell_header_encoding
            (obj2
               (req
                  "operations"
                  (conv to_list of_list
                  @@ def "inlined.endorsement_mempool.contents"
                  @@ union [make endorsement_case]))
               (varopt "signature" Signature.encoding)))

  let dal_slot_availability_encoding =
    obj2
      (req "endorser" Signature.Public_key_hash.encoding)
      (req "endorsement" Dal_endorsement_repr.encoding)

  let dal_slot_availability_case =
    Case
      {
        tag = 22;
        name = "dal_slot_availability";
        encoding = dal_slot_availability_encoding;
        select =
          (function
          | Contents (Dal_slot_availability _ as op) -> Some op | _ -> None);
        proj =
          (fun [@coq_match_with_default] (Dal_slot_availability
                                           (endorser, endorsement)) ->
            (endorser, endorsement));
        inj =
          (fun (endorser, endorsement) ->
            Dal_slot_availability (endorser, endorsement));
      }

  let[@coq_axiom_with_reason "gadt"] seed_nonce_revelation_case =
    Case
      {
        tag = 1;
        name = "seed_nonce_revelation";
        encoding =
          obj2
            (req "level" Raw_level_repr.encoding)
            (req "nonce" Seed_repr.nonce_encoding);
        select =
          (function
          | Contents (Seed_nonce_revelation _ as op) -> Some op | _ -> None);
        proj = (fun (Seed_nonce_revelation {level; nonce}) -> (level, nonce));
        inj = (fun (level, nonce) -> Seed_nonce_revelation {level; nonce});
      }

  let[@coq_axiom_with_reason "gadt"] vdf_revelation_case =
    Case
      {
        tag = 8;
        name = "vdf_revelation";
        encoding = obj1 (req "solution" Seed_repr.vdf_solution_encoding);
        select =
          (function Contents (Vdf_revelation _ as op) -> Some op | _ -> None);
        proj = (function Vdf_revelation {solution} -> solution);
        inj = (fun solution -> Vdf_revelation {solution});
      }

  let[@coq_axiom_with_reason "gadt"] double_preendorsement_evidence_case :
      Kind.double_preendorsement_evidence case =
    Case
      {
        tag = 7;
        name = "double_preendorsement_evidence";
        encoding =
          obj2
            (req "op1" (dynamic_size preendorsement_encoding))
            (req "op2" (dynamic_size preendorsement_encoding));
        select =
          (function
          | Contents (Double_preendorsement_evidence _ as op) -> Some op
          | _ -> None);
        proj = (fun (Double_preendorsement_evidence {op1; op2}) -> (op1, op2));
        inj = (fun (op1, op2) -> Double_preendorsement_evidence {op1; op2});
      }

  let[@coq_axiom_with_reason "gadt"] double_endorsement_evidence_case :
      Kind.double_endorsement_evidence case =
    Case
      {
        tag = 2;
        name = "double_endorsement_evidence";
        encoding =
          obj2
            (req "op1" (dynamic_size endorsement_encoding))
            (req "op2" (dynamic_size endorsement_encoding));
        select =
          (function
          | Contents (Double_endorsement_evidence _ as op) -> Some op
          | _ -> None);
        proj = (fun (Double_endorsement_evidence {op1; op2}) -> (op1, op2));
        inj = (fun (op1, op2) -> Double_endorsement_evidence {op1; op2});
      }

  let[@coq_axiom_with_reason "gadt"] double_baking_evidence_case =
    Case
      {
        tag = 3;
        name = "double_baking_evidence";
        encoding =
          obj2
            (req "bh1" (dynamic_size Block_header_repr.encoding))
            (req "bh2" (dynamic_size Block_header_repr.encoding));
        select =
          (function
          | Contents (Double_baking_evidence _ as op) -> Some op | _ -> None);
        proj = (fun (Double_baking_evidence {bh1; bh2}) -> (bh1, bh2));
        inj = (fun (bh1, bh2) -> Double_baking_evidence {bh1; bh2});
      }

  let[@coq_axiom_with_reason "gadt"] activate_account_case =
    Case
      {
        tag = 4;
        name = "activate_account";
        encoding =
          obj2
            (req "pkh" Ed25519.Public_key_hash.encoding)
            (req "secret" Blinded_public_key_hash.activation_code_encoding);
        select =
          (function
          | Contents (Activate_account _ as op) -> Some op | _ -> None);
        proj =
          (fun (Activate_account {id; activation_code}) ->
            (id, activation_code));
        inj =
          (fun (id, activation_code) -> Activate_account {id; activation_code});
      }

  let[@coq_axiom_with_reason "gadt"] proposals_case =
    Case
      {
        tag = 5;
        name = "proposals";
        encoding =
          obj3
            (req "source" Signature.Public_key_hash.encoding)
            (req "period" int32)
            (req "proposals" (list Protocol_hash.encoding));
        select =
          (function Contents (Proposals _ as op) -> Some op | _ -> None);
        proj =
          (fun (Proposals {source; period; proposals}) ->
            (source, period, proposals));
        inj =
          (fun (source, period, proposals) ->
            Proposals {source; period; proposals});
      }

  let[@coq_axiom_with_reason "gadt"] ballot_case =
    Case
      {
        tag = 6;
        name = "ballot";
        encoding =
          obj4
            (req "source" Signature.Public_key_hash.encoding)
            (req "period" int32)
            (req "proposal" Protocol_hash.encoding)
            (req "ballot" Vote_repr.ballot_encoding);
        select = (function Contents (Ballot _ as op) -> Some op | _ -> None);
        proj =
          (function
          | Ballot {source; period; proposal; ballot} ->
              (source, period, proposal, ballot));
        inj =
          (fun (source, period, proposal, ballot) ->
            Ballot {source; period; proposal; ballot});
      }

  let failing_noop_case =
    Case
      {
        tag = 17;
        name = "failing_noop";
        encoding = obj1 (req "arbitrary" Data_encoding.string);
        select =
          (function Contents (Failing_noop _ as op) -> Some op | _ -> None);
        proj =
          (function[@coq_match_with_default] Failing_noop message -> message);
        inj = (function message -> Failing_noop message);
      }

  let manager_encoding =
    obj5
      (req "source" Signature.Public_key_hash.encoding)
      (req "fee" Tez_repr.encoding)
      (req "counter" (check_size 10 n))
      (req "gas_limit" (check_size 10 Gas_limit_repr.Arith.n_integral_encoding))
      (req "storage_limit" (check_size 10 n))

  let extract : type kind. kind Kind.manager contents -> _ =
    function[@coq_match_with_default]
    | Manager_operation
        {source; fee; counter; gas_limit; storage_limit; operation = _} ->
        (source, fee, counter, gas_limit, storage_limit)

  let rebuild (source, fee, counter, gas_limit, storage_limit) operation =
    Manager_operation
      {source; fee; counter; gas_limit; storage_limit; operation}

  let[@coq_axiom_with_reason "gadt"] make_manager_case tag (type kind)
      (Manager_operations.MCase mcase : kind Manager_operations.case) =
    Case
      {
        tag;
        name = mcase.name;
        encoding = merge_objs manager_encoding mcase.encoding;
        select =
          (function
          | Contents (Manager_operation ({operation; _} as op)) -> (
              match mcase.select (Manager operation) with
              | None -> None
              | Some operation -> Some (Manager_operation {op with operation}))
          | _ -> None);
        proj =
          (function
          | Manager_operation {operation; _} as op ->
              (extract op, mcase.proj operation));
        inj = (fun (op, contents) -> rebuild op (mcase.inj contents));
      }

  let reveal_case = make_manager_case 107 Manager_operations.reveal_case

  let transaction_case =
    make_manager_case 108 Manager_operations.transaction_case

  let origination_case =
    make_manager_case 109 Manager_operations.origination_case

  let delegation_case = make_manager_case 110 Manager_operations.delegation_case

  let register_global_constant_case =
    make_manager_case 111 Manager_operations.register_global_constant_case

  let set_deposits_limit_case =
    make_manager_case 112 Manager_operations.set_deposits_limit_case

  let increase_paid_storage_case =
    make_manager_case 113 Manager_operations.increase_paid_storage_case

  let tx_rollup_origination_case =
    make_manager_case
      tx_rollup_operation_tag_offset
      Manager_operations.tx_rollup_origination_case

  let tx_rollup_submit_batch_case =
    make_manager_case
      tx_rollup_operation_submit_batch_tag
      Manager_operations.tx_rollup_submit_batch_case

  let tx_rollup_commit_case =
    make_manager_case
      tx_rollup_operation_commit_tag
      Manager_operations.tx_rollup_commit_case

  let tx_rollup_return_bond_case =
    make_manager_case
      tx_rollup_operation_return_bond_tag
      Manager_operations.tx_rollup_return_bond_case

  let tx_rollup_finalize_commitment_case =
    make_manager_case
      tx_rollup_operation_finalize_commitment_tag
      Manager_operations.tx_rollup_finalize_commitment_case

  let tx_rollup_remove_commitment_case =
    make_manager_case
      tx_rollup_operation_remove_commitment_tag
      Manager_operations.tx_rollup_remove_commitment_case

  let tx_rollup_rejection_case =
    make_manager_case
      tx_rollup_operation_rejection_tag
      Manager_operations.tx_rollup_rejection_case

  let tx_rollup_dispatch_tickets_case =
    make_manager_case
      tx_rollup_operation_dispatch_tickets_tag
      Manager_operations.tx_rollup_dispatch_tickets_case

  let transfer_ticket_case =
    make_manager_case
      transfer_ticket_tag
      Manager_operations.transfer_ticket_case

  let dal_publish_slot_header_case =
    make_manager_case
      dal_publish_slot_header_tag
      Manager_operations.dal_publish_slot_header_case

  let sc_rollup_originate_case =
    make_manager_case
      sc_rollup_operation_origination_tag
      Manager_operations.sc_rollup_originate_case

  let sc_rollup_add_messages_case =
    make_manager_case
      sc_rollup_operation_add_message_tag
      Manager_operations.sc_rollup_add_messages_case

  let sc_rollup_cement_case =
    make_manager_case
      sc_rollup_operation_cement_tag
      Manager_operations.sc_rollup_cement_case

  let sc_rollup_publish_case =
    make_manager_case
      sc_rollup_operation_publish_tag
      Manager_operations.sc_rollup_publish_case

  let sc_rollup_refute_case =
    make_manager_case
      sc_rollup_operation_refute_tag
      Manager_operations.sc_rollup_refute_case

  let sc_rollup_timeout_case =
    make_manager_case
      sc_rollup_operation_timeout_tag
      Manager_operations.sc_rollup_timeout_case

  let sc_rollup_execute_outbox_message_case =
    make_manager_case
      sc_rollup_execute_outbox_message_tag
      Manager_operations.sc_rollup_execute_outbox_message_case

  let sc_rollup_recover_bond_case =
    make_manager_case
      sc_rollup_operation_recover_bond_tag
      Manager_operations.sc_rollup_recover_bond_case

  let sc_rollup_dal_slot_subscribe_case =
    make_manager_case
      sc_rollup_operation_dal_slot_subscribe_tag
      Manager_operations.sc_rollup_dal_slot_subscribe_case

  let contents_encoding =
    let make (Case {tag; name; encoding; select; proj; inj}) =
      case
        (Tag tag)
        name
        encoding
        (fun o -> match select o with None -> None | Some o -> Some (proj o))
        (fun x -> Contents (inj x))
    in
    def "operation.alpha.contents"
    @@ union
         [
           make endorsement_case;
           make preendorsement_case;
           make dal_slot_availability_case;
           make seed_nonce_revelation_case;
           make vdf_revelation_case;
           make double_endorsement_evidence_case;
           make double_preendorsement_evidence_case;
           make double_baking_evidence_case;
           make activate_account_case;
           make proposals_case;
           make ballot_case;
           make reveal_case;
           make transaction_case;
           make origination_case;
           make delegation_case;
           make set_deposits_limit_case;
           make increase_paid_storage_case;
           make failing_noop_case;
           make register_global_constant_case;
           make tx_rollup_origination_case;
           make tx_rollup_submit_batch_case;
           make tx_rollup_commit_case;
           make tx_rollup_return_bond_case;
           make tx_rollup_finalize_commitment_case;
           make tx_rollup_remove_commitment_case;
           make tx_rollup_rejection_case;
           make tx_rollup_dispatch_tickets_case;
           make transfer_ticket_case;
           make dal_publish_slot_header_case;
           make sc_rollup_originate_case;
           make sc_rollup_add_messages_case;
           make sc_rollup_cement_case;
           make sc_rollup_publish_case;
           make sc_rollup_refute_case;
           make sc_rollup_timeout_case;
           make sc_rollup_execute_outbox_message_case;
           make sc_rollup_recover_bond_case;
           make sc_rollup_dal_slot_subscribe_case;
         ]

  let contents_list_encoding =
    conv_with_guard to_list of_list_internal (Variable.list contents_encoding)

  let optional_signature_encoding =
    conv
      (function Some s -> s | None -> Signature.zero)
      (fun s -> if Signature.equal s Signature.zero then None else Some s)
      Signature.encoding

  let protocol_data_encoding =
    def "operation.alpha.contents_and_signature"
    @@ conv
         (fun (Operation_data {contents; signature}) ->
           (Contents_list contents, signature))
         (fun (Contents_list contents, signature) ->
           Operation_data {contents; signature})
         (obj2
            (req "contents" contents_list_encoding)
            (req "signature" optional_signature_encoding))

  let operation_encoding =
    conv
      (fun {shell; protocol_data} -> (shell, protocol_data))
      (fun (shell, protocol_data) -> {shell; protocol_data})
      (merge_objs Operation.shell_header_encoding protocol_data_encoding)

  let unsigned_operation_encoding =
    def "operation.alpha.unsigned_operation"
    @@ merge_objs
         Operation.shell_header_encoding
         (obj1 (req "contents" contents_list_encoding))
end

let encoding = Encoding.operation_encoding

let contents_encoding = Encoding.contents_encoding

let contents_list_encoding = Encoding.contents_list_encoding

let protocol_data_encoding = Encoding.protocol_data_encoding

let unsigned_operation_encoding = Encoding.unsigned_operation_encoding

let raw ({shell; protocol_data} : _ operation) =
  let proto =
    Data_encoding.Binary.to_bytes_exn
      protocol_data_encoding
      (Operation_data protocol_data)
  in
  {Operation.shell; proto}

let acceptable_passes (op : packed_operation) =
  let (Operation_data protocol_data) = op.protocol_data in
  match protocol_data.contents with
  | Single (Failing_noop _) -> []
  | Single (Preendorsement _) -> [0]
  | Single (Endorsement _) -> [0]
  | Single (Dal_slot_availability _) -> [0]
  | Single (Proposals _) -> [1]
  | Single (Ballot _) -> [1]
  | Single (Seed_nonce_revelation _) -> [2]
  | Single (Vdf_revelation _) -> [2]
  | Single (Double_endorsement_evidence _) -> [2]
  | Single (Double_preendorsement_evidence _) -> [2]
  | Single (Double_baking_evidence _) -> [2]
  | Single (Activate_account _) -> [2]
  | Single (Manager_operation _) -> [3]
  | Cons (Manager_operation _, _ops) -> [3]

type error += Invalid_signature (* `Permanent *)

type error += Missing_signature (* `Permanent *)

let () =
  register_error_kind
    `Permanent
    ~id:"operation.invalid_signature"
    ~title:"Invalid operation signature"
    ~description:
      "The operation signature is ill-formed or has been made with the wrong \
       public key"
    ~pp:(fun ppf () -> Format.fprintf ppf "The operation signature is invalid")
    Data_encoding.unit
    (function Invalid_signature -> Some () | _ -> None)
    (fun () -> Invalid_signature) ;
  register_error_kind
    `Permanent
    ~id:"operation.missing_signature"
    ~title:"Missing operation signature"
    ~description:
      "The operation is of a kind that must be signed, but the signature is \
       missing"
    ~pp:(fun ppf () -> Format.fprintf ppf "The operation requires a signature")
    Data_encoding.unit
    (function Missing_signature -> Some () | _ -> None)
    (fun () -> Missing_signature) ;
  register_error_kind
    `Permanent
    ~id:"operation.contents_list_error"
    ~title:"Invalid list of operation contents."
    ~description:
      "An operation contents list has an unexpected shape; it should be either \
       a single operation or a non-empty list of manager operations"
    ~pp:(fun ppf s ->
      Format.fprintf
        ppf
        "An operation contents list has an unexpected shape: %s"
        s)
    Data_encoding.(obj1 (req "message" string))
    (function Contents_list_error s -> Some s | _ -> None)
    (fun s -> Contents_list_error s)

let check_signature (type kind) key chain_id
    ({shell; protocol_data} : kind operation) =
  let check ~watermark contents signature =
    let unsigned_operation =
      Data_encoding.Binary.to_bytes_exn
        unsigned_operation_encoding
        (shell, contents)
    in
    if Signature.check ~watermark key signature unsigned_operation then Ok ()
    else error Invalid_signature
  in
  match protocol_data.signature with
  | None -> error Missing_signature
  | Some signature -> (
      match protocol_data.contents with
      | Single (Preendorsement _) as contents ->
          check
            ~watermark:(to_watermark (Preendorsement chain_id))
            (Contents_list contents)
            signature
      | Single (Endorsement _) as contents ->
          check
            ~watermark:(to_watermark (Endorsement chain_id))
            (Contents_list contents)
            signature
      | Single (Dal_slot_availability _) as contents ->
          check
            ~watermark:(to_watermark (Dal_slot_availability chain_id))
            (Contents_list contents)
            signature
      | Single
          ( Failing_noop _ | Proposals _ | Ballot _ | Seed_nonce_revelation _
          | Vdf_revelation _ | Double_endorsement_evidence _
          | Double_preendorsement_evidence _ | Double_baking_evidence _
          | Activate_account _ | Manager_operation _ ) ->
          check
            ~watermark:Generic_operation
            (Contents_list protocol_data.contents)
            signature
      | Cons (Manager_operation _, _ops) ->
          check
            ~watermark:Generic_operation
            (Contents_list protocol_data.contents)
            signature)

let hash_raw = Operation.hash

let hash (o : _ operation) =
  let proto =
    Data_encoding.Binary.to_bytes_exn
      protocol_data_encoding
      (Operation_data o.protocol_data)
  in
  Operation.hash {shell = o.shell; proto}

let hash_packed (o : packed_operation) =
  let proto =
    Data_encoding.Binary.to_bytes_exn protocol_data_encoding o.protocol_data
  in
  Operation.hash {shell = o.shell; proto}

type ('a, 'b) eq = Eq : ('a, 'a) eq [@@coq_force_gadt]

let equal_manager_operation_kind :
    type a b. a manager_operation -> b manager_operation -> (a, b) eq option =
 fun op1 op2 ->
  match (op1, op2) with
  | Reveal _, Reveal _ -> Some Eq
  | Reveal _, _ -> None
  | Transaction _, Transaction _ -> Some Eq
  | Transaction _, _ -> None
  | Origination _, Origination _ -> Some Eq
  | Origination _, _ -> None
  | Delegation _, Delegation _ -> Some Eq
  | Delegation _, _ -> None
  | Register_global_constant _, Register_global_constant _ -> Some Eq
  | Register_global_constant _, _ -> None
  | Set_deposits_limit _, Set_deposits_limit _ -> Some Eq
  | Set_deposits_limit _, _ -> None
  | Increase_paid_storage _, Increase_paid_storage _ -> Some Eq
  | Increase_paid_storage _, _ -> None
  | Tx_rollup_origination, Tx_rollup_origination -> Some Eq
  | Tx_rollup_origination, _ -> None
  | Tx_rollup_submit_batch _, Tx_rollup_submit_batch _ -> Some Eq
  | Tx_rollup_submit_batch _, _ -> None
  | Tx_rollup_commit _, Tx_rollup_commit _ -> Some Eq
  | Tx_rollup_commit _, _ -> None
  | Tx_rollup_return_bond _, Tx_rollup_return_bond _ -> Some Eq
  | Tx_rollup_return_bond _, _ -> None
  | Tx_rollup_finalize_commitment _, Tx_rollup_finalize_commitment _ -> Some Eq
  | Tx_rollup_finalize_commitment _, _ -> None
  | Tx_rollup_remove_commitment _, Tx_rollup_remove_commitment _ -> Some Eq
  | Tx_rollup_remove_commitment _, _ -> None
  | Tx_rollup_rejection _, Tx_rollup_rejection _ -> Some Eq
  | Tx_rollup_rejection _, _ -> None
  | Tx_rollup_dispatch_tickets _, Tx_rollup_dispatch_tickets _ -> Some Eq
  | Tx_rollup_dispatch_tickets _, _ -> None
  | Transfer_ticket _, Transfer_ticket _ -> Some Eq
  | Transfer_ticket _, _ -> None
  | Dal_publish_slot_header _, Dal_publish_slot_header _ -> Some Eq
  | Dal_publish_slot_header _, _ -> None
  | Sc_rollup_originate _, Sc_rollup_originate _ -> Some Eq
  | Sc_rollup_originate _, _ -> None
  | Sc_rollup_add_messages _, Sc_rollup_add_messages _ -> Some Eq
  | Sc_rollup_add_messages _, _ -> None
  | Sc_rollup_cement _, Sc_rollup_cement _ -> Some Eq
  | Sc_rollup_cement _, _ -> None
  | Sc_rollup_publish _, Sc_rollup_publish _ -> Some Eq
  | Sc_rollup_publish _, _ -> None
  | Sc_rollup_refute _, Sc_rollup_refute _ -> Some Eq
  | Sc_rollup_refute _, _ -> None
  | Sc_rollup_timeout _, Sc_rollup_timeout _ -> Some Eq
  | Sc_rollup_timeout _, _ -> None
  | Sc_rollup_execute_outbox_message _, Sc_rollup_execute_outbox_message _ ->
      Some Eq
  | Sc_rollup_execute_outbox_message _, _ -> None
  | Sc_rollup_recover_bond _, Sc_rollup_recover_bond _ -> Some Eq
  | Sc_rollup_recover_bond _, _ -> None
  | Sc_rollup_dal_slot_subscribe _, Sc_rollup_dal_slot_subscribe _ -> Some Eq
  | Sc_rollup_dal_slot_subscribe _, _ -> None

let equal_contents_kind : type a b. a contents -> b contents -> (a, b) eq option
    =
 fun op1 op2 ->
  match (op1, op2) with
  | Preendorsement _, Preendorsement _ -> Some Eq
  | Preendorsement _, _ -> None
  | Endorsement _, Endorsement _ -> Some Eq
  | Endorsement _, _ -> None
  | Dal_slot_availability _, Dal_slot_availability _ -> Some Eq
  | Dal_slot_availability _, _ -> None
  | Seed_nonce_revelation _, Seed_nonce_revelation _ -> Some Eq
  | Seed_nonce_revelation _, _ -> None
  | Vdf_revelation _, Vdf_revelation _ -> Some Eq
  | Vdf_revelation _, _ -> None
  | Double_endorsement_evidence _, Double_endorsement_evidence _ -> Some Eq
  | Double_endorsement_evidence _, _ -> None
  | Double_preendorsement_evidence _, Double_preendorsement_evidence _ ->
      Some Eq
  | Double_preendorsement_evidence _, _ -> None
  | Double_baking_evidence _, Double_baking_evidence _ -> Some Eq
  | Double_baking_evidence _, _ -> None
  | Activate_account _, Activate_account _ -> Some Eq
  | Activate_account _, _ -> None
  | Proposals _, Proposals _ -> Some Eq
  | Proposals _, _ -> None
  | Ballot _, Ballot _ -> Some Eq
  | Ballot _, _ -> None
  | Failing_noop _, Failing_noop _ -> Some Eq
  | Failing_noop _, _ -> None
  | Manager_operation op1, Manager_operation op2 -> (
      match equal_manager_operation_kind op1.operation op2.operation with
      | None -> None
      | Some Eq -> Some Eq)
  | Manager_operation _, _ -> None

let rec equal_contents_kind_list :
    type a b. a contents_list -> b contents_list -> (a, b) eq option =
 fun op1 op2 ->
  match (op1, op2) with
  | Single op1, Single op2 -> equal_contents_kind op1 op2
  | Single _, Cons _ -> None
  | Cons _, Single _ -> None
  | Cons (op1, ops1), Cons (op2, ops2) -> (
      match equal_contents_kind op1 op2 with
      | None -> None
      | Some Eq -> (
          match equal_contents_kind_list ops1 ops2 with
          | None -> None
          | Some Eq -> Some Eq))

let equal : type a b. a operation -> b operation -> (a, b) eq option =
 fun op1 op2 ->
  if not (Operation_hash.equal (hash op1) (hash op2)) then None
  else
    equal_contents_kind_list
      op1.protocol_data.contents
      op2.protocol_data.contents
