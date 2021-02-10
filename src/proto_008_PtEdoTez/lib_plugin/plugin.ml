(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Nomadic Development. <contact@tezcore.com>             *)
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
module Proto = Registerer.Registered

module Mempool = struct
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

  type config = {
    minimal_fees : Tez.t;
    minimal_nanotez_per_gas_unit : nanotez;
    minimal_nanotez_per_byte : nanotez;
    allow_script_failure : bool;
  }

  let default_minimal_fees =
    match Tez.of_mutez 100L with None -> assert false | Some t -> t

  let default_minimal_nanotez_per_gas_unit = Q.of_int 100

  let default_minimal_nanotez_per_byte = Q.of_int 1000

  let config_encoding : config Data_encoding.t =
    let open Data_encoding in
    conv
      (fun { minimal_fees;
             minimal_nanotez_per_gas_unit;
             minimal_nanotez_per_byte;
             allow_script_failure } ->
        ( minimal_fees,
          minimal_nanotez_per_gas_unit,
          minimal_nanotez_per_byte,
          allow_script_failure ))
      (fun ( minimal_fees,
             minimal_nanotez_per_gas_unit,
             minimal_nanotez_per_byte,
             allow_script_failure ) ->
        {
          minimal_fees;
          minimal_nanotez_per_gas_unit;
          minimal_nanotez_per_byte;
          allow_script_failure;
        })
      (obj4
         (dft "minimal_fees" Tez.encoding default_minimal_fees)
         (dft
            "minimal_nanotez_per_gas_unit"
            nanotez_enc
            default_minimal_nanotez_per_gas_unit)
         (dft
            "minimal_nanotez_per_byte"
            nanotez_enc
            default_minimal_nanotez_per_byte)
         (dft "allow_script_failure" bool true))

  let default_config =
    {
      minimal_fees = default_minimal_fees;
      minimal_nanotez_per_gas_unit = default_minimal_nanotez_per_gas_unit;
      minimal_nanotez_per_byte = default_minimal_nanotez_per_byte;
      allow_script_failure = true;
    }

  let get_manager_operation_gas_and_fee contents =
    let open Operation in
    let l = to_list (Contents_list contents) in
    List.fold_left
      (fun acc -> function
        | Contents (Manager_operation {fee; gas_limit; _}) -> (
          match acc with
          | Error _ as e ->
              e
          | Ok (total_fee, total_gas) -> (
            match Tez.(total_fee +? fee) with
            | Ok total_fee ->
                Ok (total_fee, Gas.Arith.add total_gas gas_limit)
            | Error _ as e ->
                e ) ) | _ -> acc)
      (Ok (Tez.zero, Gas.Arith.zero))
      l

  let pre_filter_manager :
      type t. config -> t Kind.manager contents_list -> int -> bool =
   fun config op size ->
    match get_manager_operation_gas_and_fee op with
    | Error _ ->
        false
    | Ok (fee, gas) ->
        let fees_in_nanotez =
          Q.mul (Q.of_int64 (Tez.to_mutez fee)) (Q.of_int 1000)
        in
        let minimal_fees_in_nanotez =
          Q.mul (Q.of_int64 (Tez.to_mutez config.minimal_fees)) (Q.of_int 1000)
        in
        let minimal_fees_for_gas_in_nanotez =
          Q.mul
            config.minimal_nanotez_per_gas_unit
            (Q.of_bigint @@ Gas.Arith.integral_to_z gas)
        in
        let minimal_fees_for_size_in_nanotez =
          Q.mul config.minimal_nanotez_per_byte (Q.of_int size)
        in
        Q.compare
          fees_in_nanotez
          (Q.add
             minimal_fees_in_nanotez
             (Q.add
                minimal_fees_for_gas_in_nanotez
                minimal_fees_for_size_in_nanotez))
        >= 0

  let pre_filter config
      (Operation_data {contents; _} as op : Operation.packed_protocol_data) =
    let bytes =
      Data_encoding.Binary.fixed_length_exn
        Tezos_base.Operation.shell_header_encoding
      + Data_encoding.Binary.length Operation.protocol_data_encoding op
    in
    match contents with
    | Single (Endorsement _) ->
        true
    | Single (Seed_nonce_revelation _) ->
        true
    | Single (Double_endorsement_evidence _) ->
        true
    | Single (Double_baking_evidence _) ->
        true
    | Single (Activate_account _) ->
        true
    | Single (Proposals _) ->
        true
    | Single (Ballot _) ->
        true
    | Single (Manager_operation _) as op ->
        pre_filter_manager config op bytes
    | Cons (Manager_operation _, _) as op ->
        pre_filter_manager config op bytes

  open Apply_results

  let rec post_filter_manager :
      type t.
      Alpha_context.t ->
      t Kind.manager contents_result_list ->
      config ->
      bool Lwt.t =
   fun ctxt op config ->
    match op with
    | Single_result (Manager_operation_result {operation_result; _}) -> (
      match operation_result with
      | Applied _ ->
          Lwt.return_true
      | Skipped _ | Failed _ | Backtracked _ ->
          Lwt.return config.allow_script_failure )
    | Cons_result (Manager_operation_result res, rest) -> (
        post_filter_manager
          ctxt
          (Single_result (Manager_operation_result res))
          config
        >>= function
        | false ->
            Lwt.return_false
        | true ->
            post_filter_manager ctxt rest config )

  let post_filter config ~validation_state_before:_
      ~validation_state_after:({ctxt; _} : validation_state) (_op, receipt) =
    match receipt with
    | No_operation_metadata ->
        assert false (* only for multipass validator *)
    | Operation_metadata {contents} -> (
      match contents with
      | Single_result (Endorsement_result _) ->
          Lwt.return_true
      | Single_result (Seed_nonce_revelation_result _) ->
          Lwt.return_true
      | Single_result (Double_endorsement_evidence_result _) ->
          Lwt.return_true
      | Single_result (Double_baking_evidence_result _) ->
          Lwt.return_true
      | Single_result (Activate_account_result _) ->
          Lwt.return_true
      | Single_result Proposals_result ->
          Lwt.return_true
      | Single_result Ballot_result ->
          Lwt.return_true
      | Single_result (Manager_operation_result _) as op ->
          post_filter_manager ctxt op config
      | Cons_result (Manager_operation_result _, _) as op ->
          post_filter_manager ctxt op config )
end

module RPC = struct
  open Environment

  type Environment.Error_monad.error += Cannot_serialize_log_normalized

  let () =
    (* Cannot serialize log *)
    Environment.Error_monad.register_error_kind
      `Temporary
      ~id:"michelson_v1.cannot_serialize_log_normalized"
      ~title:"Not enough gas to serialize normalized execution trace"
      ~description:
        "Execution trace with normalized stacks was to big to be serialized \
         with the provided gas"
      Data_encoding.empty
      (function Cannot_serialize_log_normalized -> Some () | _ -> None)
      (fun () -> Cannot_serialize_log_normalized)

  module Unparse_types = struct
    (* Same as the unparsing functions for types in Script_ir_translator but
       does not consume gas and never folds (pair a (pair b c)) *)

    open Script_ir_translator
    open Micheline
    open Michelson_v1_primitives
    open Script_ir_annot
    open Script_typed_ir

    let rec unparse_comparable_ty : type a. a comparable_ty -> Script.node =
      function
      | Unit_key tname ->
          Prim (-1, T_unit, [], unparse_type_annot tname)
      | Never_key tname ->
          Prim (-1, T_never, [], unparse_type_annot tname)
      | Int_key tname ->
          Prim (-1, T_int, [], unparse_type_annot tname)
      | Nat_key tname ->
          Prim (-1, T_nat, [], unparse_type_annot tname)
      | Signature_key tname ->
          Prim (-1, T_signature, [], unparse_type_annot tname)
      | String_key tname ->
          Prim (-1, T_string, [], unparse_type_annot tname)
      | Bytes_key tname ->
          Prim (-1, T_bytes, [], unparse_type_annot tname)
      | Mutez_key tname ->
          Prim (-1, T_mutez, [], unparse_type_annot tname)
      | Bool_key tname ->
          Prim (-1, T_bool, [], unparse_type_annot tname)
      | Key_hash_key tname ->
          Prim (-1, T_key_hash, [], unparse_type_annot tname)
      | Key_key tname ->
          Prim (-1, T_key, [], unparse_type_annot tname)
      | Timestamp_key tname ->
          Prim (-1, T_timestamp, [], unparse_type_annot tname)
      | Address_key tname ->
          Prim (-1, T_address, [], unparse_type_annot tname)
      | Chain_id_key tname ->
          Prim (-1, T_chain_id, [], unparse_type_annot tname)
      | Pair_key ((l, al), (r, ar), pname) ->
          let tl = add_field_annot al None (unparse_comparable_ty l) in
          let tr = add_field_annot ar None (unparse_comparable_ty r) in
          Prim (-1, T_pair, [tl; tr], unparse_type_annot pname)
      | Union_key ((l, al), (r, ar), tname) ->
          let tl = add_field_annot al None (unparse_comparable_ty l) in
          let tr = add_field_annot ar None (unparse_comparable_ty r) in
          Prim (-1, T_or, [tl; tr], unparse_type_annot tname)
      | Option_key (t, tname) ->
          Prim
            (-1, T_option, [unparse_comparable_ty t], unparse_type_annot tname)

    let unparse_memo_size memo_size =
      let z = Alpha_context.Sapling.Memo_size.unparse_to_z memo_size in
      Int (-1, z)

    let rec unparse_ty : type a. a ty -> Script.node =
     fun ty ->
      let return (name, args, annot) = Prim (-1, name, args, annot) in
      match ty with
      | Unit_t tname ->
          return (T_unit, [], unparse_type_annot tname)
      | Int_t tname ->
          return (T_int, [], unparse_type_annot tname)
      | Nat_t tname ->
          return (T_nat, [], unparse_type_annot tname)
      | Signature_t tname ->
          return (T_signature, [], unparse_type_annot tname)
      | String_t tname ->
          return (T_string, [], unparse_type_annot tname)
      | Bytes_t tname ->
          return (T_bytes, [], unparse_type_annot tname)
      | Mutez_t tname ->
          return (T_mutez, [], unparse_type_annot tname)
      | Bool_t tname ->
          return (T_bool, [], unparse_type_annot tname)
      | Key_hash_t tname ->
          return (T_key_hash, [], unparse_type_annot tname)
      | Key_t tname ->
          return (T_key, [], unparse_type_annot tname)
      | Timestamp_t tname ->
          return (T_timestamp, [], unparse_type_annot tname)
      | Address_t tname ->
          return (T_address, [], unparse_type_annot tname)
      | Operation_t tname ->
          return (T_operation, [], unparse_type_annot tname)
      | Chain_id_t tname ->
          return (T_chain_id, [], unparse_type_annot tname)
      | Never_t tname ->
          return (T_never, [], unparse_type_annot tname)
      | Bls12_381_g1_t tname ->
          return (T_bls12_381_g1, [], unparse_type_annot tname)
      | Bls12_381_g2_t tname ->
          return (T_bls12_381_g2, [], unparse_type_annot tname)
      | Bls12_381_fr_t tname ->
          return (T_bls12_381_fr, [], unparse_type_annot tname)
      | Contract_t (ut, tname) ->
          let t = unparse_ty ut in
          return (T_contract, [t], unparse_type_annot tname)
      | Pair_t ((utl, l_field, l_var), (utr, r_field, r_var), tname) ->
          let annot = unparse_type_annot tname in
          let utl = unparse_ty utl in
          let tl = add_field_annot l_field l_var utl in
          let utr = unparse_ty utr in
          let tr = add_field_annot r_field r_var utr in
          return (T_pair, [tl; tr], annot)
      | Union_t ((utl, l_field), (utr, r_field), tname) ->
          let annot = unparse_type_annot tname in
          let utl = unparse_ty utl in
          let tl = add_field_annot l_field None utl in
          let utr = unparse_ty utr in
          let tr = add_field_annot r_field None utr in
          return (T_or, [tl; tr], annot)
      | Lambda_t (uta, utr, tname) ->
          let ta = unparse_ty uta in
          let tr = unparse_ty utr in
          return (T_lambda, [ta; tr], unparse_type_annot tname)
      | Option_t (ut, tname) ->
          let annot = unparse_type_annot tname in
          let ut = unparse_ty ut in
          return (T_option, [ut], annot)
      | List_t (ut, tname) ->
          let t = unparse_ty ut in
          return (T_list, [t], unparse_type_annot tname)
      | Ticket_t (ut, tname) ->
          let t = unparse_comparable_ty ut in
          return (T_ticket, [t], unparse_type_annot tname)
      | Set_t (ut, tname) ->
          let t = unparse_comparable_ty ut in
          return (T_set, [t], unparse_type_annot tname)
      | Map_t (uta, utr, tname) ->
          let ta = unparse_comparable_ty uta in
          let tr = unparse_ty utr in
          return (T_map, [ta; tr], unparse_type_annot tname)
      | Big_map_t (uta, utr, tname) ->
          let ta = unparse_comparable_ty uta in
          let tr = unparse_ty utr in
          return (T_big_map, [ta; tr], unparse_type_annot tname)
      | Sapling_transaction_t (memo_size, tname) ->
          return
            ( T_sapling_transaction,
              [unparse_memo_size memo_size],
              unparse_type_annot tname )
      | Sapling_state_t (memo_size, tname) ->
          return
            ( T_sapling_state,
              [unparse_memo_size memo_size],
              unparse_type_annot tname )
  end

  let helpers_path = RPC_path.(open_root / "helpers" / "scripts")

  let contract_root =
    ( RPC_path.(open_root / "context" / "contracts")
      : RPC_context.t RPC_path.context )

  let big_map_root =
    ( RPC_path.(open_root / "context" / "big_maps")
      : RPC_context.t RPC_path.context )

  let unparsing_mode_encoding =
    let open Data_encoding in
    union
      ~tag_size:`Uint8
      [ case
          (Tag 0)
          ~title:"Readable"
          (constant "Readable")
          (function
            | Script_ir_translator.Readable ->
                Some ()
            | Script_ir_translator.Optimized
            | Script_ir_translator.Optimized_legacy ->
                None)
          (fun () -> Script_ir_translator.Readable);
        case
          (Tag 1)
          ~title:"Optimized"
          (constant "Optimized")
          (function
            | Script_ir_translator.Optimized ->
                Some ()
            | Script_ir_translator.Readable
            | Script_ir_translator.Optimized_legacy ->
                None)
          (fun () -> Script_ir_translator.Optimized);
        case
          (Tag 2)
          ~title:"Optimized_legacy"
          (constant "Optimized_legacy")
          (function
            | Script_ir_translator.Optimized_legacy ->
                Some ()
            | Script_ir_translator.Readable | Script_ir_translator.Optimized ->
                None)
          (fun () -> Script_ir_translator.Optimized_legacy) ]

  let run_code_input_encoding =
    let open Data_encoding in
    merge_objs
      (obj10
         (req "script" Script.expr_encoding)
         (req "storage" Script.expr_encoding)
         (req "input" Script.expr_encoding)
         (req "amount" Tez.encoding)
         (req "balance" Tez.encoding)
         (req "chain_id" Chain_id.encoding)
         (opt "source" Contract.encoding)
         (opt "payer" Contract.encoding)
         (opt "gas" Gas.Arith.z_integral_encoding)
         (dft "entrypoint" string "default"))
      (obj1 (req "unparsing_mode" unparsing_mode_encoding))

  let normalize_data =
    let open Data_encoding in
    RPC_service.post_service
      ~description:
        "Normalizes some data expression using the requested unparsing mode"
      ~input:
        (obj4
           (req "data" Script.expr_encoding)
           (req "type" Script.expr_encoding)
           (req "unparsing_mode" unparsing_mode_encoding)
           (opt "legacy" bool))
      ~output:(obj1 (req "normalized" Script.expr_encoding))
      ~query:RPC_query.empty
      RPC_path.(helpers_path / "normalize_data")

  let normalize_script =
    let open Data_encoding in
    RPC_service.post_service
      ~description:
        "Normalizes a Michelson script using the requested unparsing mode"
      ~input:
        (obj2
           (req "script" Script.expr_encoding)
           (req "unparsing_mode" unparsing_mode_encoding))
      ~output:(obj1 (req "normalized" Script.expr_encoding))
      ~query:RPC_query.empty
      RPC_path.(helpers_path / "normalize_script")

  let normalize_type =
    let open Data_encoding in
    RPC_service.post_service
      ~description:
        "Normalizes some Michelson type by expanding `pair a b c` as `pair a \
         (pair b c)"
      ~input:(obj1 (req "type" Script.expr_encoding))
      ~output:(obj1 (req "normalized" Script.expr_encoding))
      ~query:RPC_query.empty
      RPC_path.(helpers_path / "normalize_type")

  let get_storage_normalized =
    let open Data_encoding in
    RPC_service.post_service
      ~description:
        "Access the data of the contract and normalize it using the requested \
         unparsing mode."
      ~input:(obj1 (req "unparsing_mode" unparsing_mode_encoding))
      ~query:RPC_query.empty
      ~output:(option Script.expr_encoding)
      RPC_path.(contract_root /: Contract.rpc_arg / "storage" / "normalized")

  let get_script_normalized =
    let open Data_encoding in
    RPC_service.post_service
      ~description:
        "Access the script of the contract and normalize it using the \
         requested unparsing mode."
      ~input:(obj1 (req "unparsing_mode" unparsing_mode_encoding))
      ~query:RPC_query.empty
      ~output:(option Script.encoding)
      RPC_path.(contract_root /: Contract.rpc_arg / "script" / "normalized")

  let run_code_normalized =
    let open Data_encoding in
    RPC_service.post_service
      ~description:
        "Run a piece of code in the current context, normalize the output \
         using the requested unparsing mode."
      ~query:RPC_query.empty
      ~input:run_code_input_encoding
      ~output:
        (conv
           (fun (storage, operations, lazy_storage_diff) ->
             (storage, operations, lazy_storage_diff, lazy_storage_diff))
           (fun ( storage,
                  operations,
                  legacy_lazy_storage_diff,
                  lazy_storage_diff ) ->
             let lazy_storage_diff =
               Option.first_some lazy_storage_diff legacy_lazy_storage_diff
             in
             (storage, operations, lazy_storage_diff))
           (obj4
              (req "storage" Script.expr_encoding)
              (req
                 "operations"
                 (list Alpha_context.Operation.internal_operation_encoding))
              (opt "big_map_diff" Lazy_storage.legacy_big_map_diff_encoding)
              (opt "lazy_storage_diff" Lazy_storage.encoding)))
      RPC_path.(helpers_path / "run_code" / "normalized")

  let trace_encoding =
    let open Data_encoding in
    def "scripted.trace" @@ list
    @@ obj3
         (req "location" Script.location_encoding)
         (req "gas" Gas.encoding)
         (req
            "stack"
            (list (obj2 (req "item" Script.expr_encoding) (opt "annot" string))))

  let trace_code_normalized =
    let open Data_encoding in
    RPC_service.post_service
      ~description:
        "Run a piece of code in the current context, keeping a trace, \
         normalize the output using the requested unparsing mode."
      ~query:RPC_query.empty
      ~input:run_code_input_encoding
      ~output:
        (conv
           (fun (storage, operations, trace, lazy_storage_diff) ->
             (storage, operations, trace, lazy_storage_diff, lazy_storage_diff))
           (fun ( storage,
                  operations,
                  trace,
                  legacy_lazy_storage_diff,
                  lazy_storage_diff ) ->
             let lazy_storage_diff =
               Option.first_some lazy_storage_diff legacy_lazy_storage_diff
             in
             (storage, operations, trace, lazy_storage_diff))
           (obj5
              (req "storage" Script.expr_encoding)
              (req
                 "operations"
                 (list Alpha_context.Operation.internal_operation_encoding))
              (req "trace" trace_encoding)
              (opt "big_map_diff" Lazy_storage.legacy_big_map_diff_encoding)
              (opt "lazy_storage_diff" Lazy_storage.encoding)))
      RPC_path.(helpers_path / "trace_code" / "normalized")

  let big_map_get_normalized =
    let open Data_encoding in
    RPC_service.post_service
      ~description:
        "Access the value associated with a key in a big map, normalize the \
         output using the requested unparsing mode."
      ~query:RPC_query.empty
      ~input:(obj1 (req "unparsing_mode" unparsing_mode_encoding))
      ~output:Script.expr_encoding
      RPC_path.(
        big_map_root /: Big_map.Id.rpc_arg /: Script_expr_hash.rpc_arg
        / "normalized")

  let rpc_services =
    let patched_services =
      ref (RPC_directory.empty : Updater.rpc_context RPC_directory.t)
    in
    let register0_fullctxt s f =
      patched_services :=
        RPC_directory.register !patched_services s (fun ctxt q i ->
            Services_registration.rpc_init ctxt >>=? fun ctxt -> f ctxt q i)
    in
    let register0 s f = register0_fullctxt s (fun {context; _} -> f context) in
    let register1_fullctxt s f =
      patched_services :=
        RPC_directory.register !patched_services s (fun (ctxt, arg) q i ->
            Services_registration.rpc_init ctxt >>=? fun ctxt -> f ctxt arg q i)
    in
    let register1 s f =
      register1_fullctxt s (fun {context; _} x -> f context x)
    in
    let _register1_noctxt s f =
      patched_services :=
        RPC_directory.register !patched_services s (fun (_, arg) q i ->
            f arg q i)
    in
    let register2_fullctxt s f =
      patched_services :=
        RPC_directory.register
          !patched_services
          s
          (fun ((ctxt, arg1), arg2) q i ->
            Services_registration.rpc_init ctxt
            >>=? fun ctxt -> f ctxt arg1 arg2 q i)
    in
    let register2 s f =
      register2_fullctxt s (fun {context; _} a1 a2 q i -> f context a1 a2 q i)
    in
    let register_field s f =
      register1 s (fun ctxt contract () () ->
          Contract.exists ctxt contract
          >>=? function true -> f ctxt contract | false -> raise Not_found)
    in
    let _register_opt_field s f =
      register_field s (fun ctxt a1 ->
          f ctxt a1 >|=? function None -> raise Not_found | Some v -> v)
    in
    let originate_dummy_contract ctxt script balance =
      let ctxt = Contract.init_origination_nonce ctxt Operation_hash.zero in
      Lwt.return (Contract.fresh_contract_from_current_nonce ctxt)
      >>=? fun (ctxt, dummy_contract) ->
      Contract.originate
        ctxt
        dummy_contract
        ~balance
        ~delegate:None
        ~script:(script, None)
      >>=? fun ctxt -> return (ctxt, dummy_contract)
    in
    register0
      normalize_data
      (fun ctxt () (expr, typ, unparsing_mode, legacy) ->
        let open Script_ir_translator in
        let legacy = Option.value ~default:false legacy in
        let ctxt = Gas.set_unlimited ctxt in
        (* Unfortunately, Script_ir_translator.parse_any_ty is not exported *)
        Script_ir_translator.parse_ty
          ctxt
          ~legacy
          ~allow_lazy_storage:true
          ~allow_operation:true
          ~allow_contract:true
          ~allow_ticket:true
          (Micheline.root typ)
        >>?= fun (Ex_ty typ, ctxt) ->
        parse_data ctxt ~legacy ~allow_forged:true typ (Micheline.root expr)
        >>=? fun (data, ctxt) ->
        Script_ir_translator.unparse_data ctxt unparsing_mode typ data
        >|=? fun (normalized, _ctxt) -> Micheline.strip_locations normalized) ;
    register0 normalize_script (fun ctxt () (script, unparsing_mode) ->
        let ctxt = Gas.set_unlimited ctxt in
        Script_ir_translator.unparse_code
          ctxt
          unparsing_mode
          (Micheline.root script)
        >|=? fun (normalized, _ctxt) -> Micheline.strip_locations normalized) ;
    register0 normalize_type (fun ctxt () typ ->
        let open Script_ir_translator in
        let ctxt = Gas.set_unlimited ctxt in
        (* Unfortunately, Script_ir_translator.parse_any_ty is not exported *)
        Script_ir_translator.parse_ty
          ctxt
          ~legacy:true
          ~allow_lazy_storage:true
          ~allow_operation:true
          ~allow_contract:true
          ~allow_ticket:true
          (Micheline.root typ)
        >>?= fun (Ex_ty typ, _ctxt) ->
        let normalized = Unparse_types.unparse_ty typ in
        return @@ Micheline.strip_locations normalized) ;
    (* Patched RPC: get_storage *)
    register1 get_storage_normalized (fun ctxt contract () unparsing_mode ->
        Contract.get_script ctxt contract
        >>=? fun (ctxt, script) ->
        match script with
        | None ->
            return_none
        | Some script ->
            let ctxt = Gas.set_unlimited ctxt in
            let open Script_ir_translator in
            parse_script ctxt ~legacy:true ~allow_forged_in_storage:true script
            >>=? fun (Ex_script script, ctxt) ->
            unparse_script ctxt unparsing_mode script
            >>=? fun (script, ctxt) ->
            Script.force_decode_in_context ctxt script.storage
            >>?= fun (storage, _ctxt) -> return_some storage) ;
    (* Patched RPC: get_script *)
    register1 get_script_normalized (fun ctxt contract () unparsing_mode ->
        Contract.get_script ctxt contract
        >>=? fun (ctxt, script) ->
        match script with
        | None ->
            return_none
        | Some script ->
            let ctxt = Gas.set_unlimited ctxt in
            let open Script_ir_translator in
            parse_script ctxt ~legacy:true ~allow_forged_in_storage:true script
            >>=? fun (Ex_script script, ctxt) ->
            unparse_script ctxt unparsing_mode script
            >>=? fun (script, _ctxt) -> return_some script) ;
    register0
      run_code_normalized
      (fun ctxt
           ()
           ( ( code,
               storage,
               parameter,
               amount,
               balance,
               chain_id,
               source,
               payer,
               gas,
               entrypoint ),
             unparsing_mode )
           ->
        let storage = Script.lazy_expr storage in
        let code = Script.lazy_expr code in
        originate_dummy_contract ctxt {storage; code} balance
        >>=? fun (ctxt, dummy_contract) ->
        let (source, payer) =
          match (source, payer) with
          | (Some source, Some payer) ->
              (source, payer)
          | (Some source, None) ->
              (source, source)
          | (None, Some payer) ->
              (payer, payer)
          | (None, None) ->
              (dummy_contract, dummy_contract)
        in
        let gas =
          match gas with
          | Some gas ->
              gas
          | None ->
              Constants.hard_gas_limit_per_operation ctxt
        in
        let ctxt = Gas.set_limit ctxt gas in
        let step_constants =
          let open Script_interpreter in
          {source; payer; self = dummy_contract; amount; chain_id}
        in
        Script_interpreter.execute
          ctxt
          unparsing_mode
          step_constants
          ~script:{storage; code}
          ~entrypoint
          ~parameter
          ~internal:true
        >|=? fun {Script_interpreter.storage; operations; lazy_storage_diff; _} ->
        (storage, operations, lazy_storage_diff)) ;
    register0
      trace_code_normalized
      (fun ctxt
           ()
           ( ( code,
               storage,
               parameter,
               amount,
               balance,
               chain_id,
               source,
               payer,
               gas,
               entrypoint ),
             unparsing_mode )
           ->
        let module Traced_interpreter = struct
          type log_element =
            | Log :
                context * Script.location * 'a * 'a Script_typed_ir.stack_ty
                -> log_element

          let unparse_stack ctxt (stack, stack_ty) =
            (* We drop the gas limit as this function is only used for debugging/errors. *)
            let ctxt = Gas.set_unlimited ctxt in
            let rec unparse_stack :
                type a.
                a Script_typed_ir.stack_ty * a ->
                (Script.expr * string option) list
                Environment.Error_monad.tzresult
                Lwt.t = function
              | (Empty_t, ()) ->
                  return_nil
              | (Item_t (ty, rest_ty, annot), (v, rest)) ->
                  Script_ir_translator.unparse_data ctxt unparsing_mode ty v
                  >>=? fun (data, _ctxt) ->
                  unparse_stack (rest_ty, rest)
                  >|=? fun rest ->
                  let annot =
                    match Script_ir_annot.unparse_var_annot annot with
                    | [] ->
                        None
                    | [a] ->
                        Some a
                    | _ ->
                        assert false
                  in
                  let data = Micheline.strip_locations data in
                  (data, annot) :: rest
            in
            unparse_stack (stack_ty, stack)

          module Trace_logger () : Script_interpreter.STEP_LOGGER = struct
            let log : log_element list ref = ref []

            let log_interp ctxt (descr : (_, _) Script_typed_ir.descr) stack =
              log := Log (ctxt, descr.loc, stack, descr.bef) :: !log

            let log_entry _ctxt _descr _stack = ()

            let log_exit ctxt (descr : (_, _) Script_typed_ir.descr) stack =
              log := Log (ctxt, descr.loc, stack, descr.aft) :: !log

            let get_log () =
              Environment.Error_monad.map_s
                (fun (Log (ctxt, loc, stack, stack_ty)) ->
                  Environment.Error_monad.trace
                    Cannot_serialize_log_normalized
                    (unparse_stack ctxt (stack, stack_ty))
                  >>=? fun stack -> return (loc, Gas.level ctxt, stack))
                !log
              >>=? fun res -> return (Some (List.rev res))
          end
        end in
        let storage = Script.lazy_expr storage in
        let code = Script.lazy_expr code in
        originate_dummy_contract ctxt {storage; code} balance
        >>=? fun (ctxt, dummy_contract) ->
        let (source, payer) =
          match (source, payer) with
          | (Some source, Some payer) ->
              (source, payer)
          | (Some source, None) ->
              (source, source)
          | (None, Some payer) ->
              (payer, payer)
          | (None, None) ->
              (dummy_contract, dummy_contract)
        in
        let gas =
          match gas with
          | Some gas ->
              gas
          | None ->
              Constants.hard_gas_limit_per_operation ctxt
        in
        let ctxt = Gas.set_limit ctxt gas in
        let step_constants =
          let open Script_interpreter in
          {source; payer; self = dummy_contract; amount; chain_id}
        in
        let module Logger = Traced_interpreter.Trace_logger () in
        let logger = (module Logger : Script_interpreter.STEP_LOGGER) in
        Script_interpreter.execute
          ~logger
          ctxt
          unparsing_mode
          step_constants
          ~script:{storage; code}
          ~entrypoint
          ~parameter
          ~internal:true
        >>=? fun {storage; lazy_storage_diff; operations; _} ->
        Logger.get_log ()
        >|=? fun trace ->
        let trace = Option.value ~default:[] trace in
        (storage, operations, trace, lazy_storage_diff)) ;
    register2 big_map_get_normalized (fun ctxt id key () unparsing_mode ->
        let open Script_ir_translator in
        let ctxt = Gas.set_unlimited ctxt in
        Big_map.exists ctxt id
        >>=? fun (ctxt, types) ->
        match types with
        | None ->
            raise Not_found
        | Some (_, value_type) -> (
            parse_big_map_value_ty
              ctxt
              ~legacy:true
              (Micheline.root value_type)
            >>?= fun (Ex_ty value_type, ctxt) ->
            Big_map.get_opt ctxt id key
            >>=? fun (_ctxt, value) ->
            match value with
            | None ->
                raise Not_found
            | Some value ->
                parse_data
                  ctxt
                  ~legacy:true
                  ~allow_forged:true
                  value_type
                  (Micheline.root value)
                >>=? fun (value, ctxt) ->
                unparse_data ctxt unparsing_mode value_type value
                >|=? fun (value, _ctxt) -> Micheline.strip_locations value )) ;
    RPC_directory.merge rpc_services !patched_services

  let normalize_data ctxt block ?legacy ~data ~ty ~unparsing_mode =
    RPC_context.make_call0
      normalize_data
      ctxt
      block
      ()
      (data, ty, unparsing_mode, legacy)

  let normalize_script ctxt block ~script ~unparsing_mode =
    RPC_context.make_call0
      normalize_script
      ctxt
      block
      ()
      (script, unparsing_mode)

  let normalize_type ctxt block ~ty =
    RPC_context.make_call0 normalize_type ctxt block () ty

  let get_storage_normalized ctxt block ~contract ~unparsing_mode =
    RPC_context.make_call1
      get_storage_normalized
      ctxt
      block
      contract
      ()
      unparsing_mode

  let get_script_normalized ctxt block ~contract ~unparsing_mode =
    RPC_context.make_call1
      get_script_normalized
      ctxt
      block
      contract
      ()
      unparsing_mode

  let run_code_normalized ctxt block ?gas ?(entrypoint = "default") ~script
      ~storage ~input ~amount ~balance ~chain_id ~source ~payer ~unparsing_mode
      =
    RPC_context.make_call0
      run_code_normalized
      ctxt
      block
      ()
      ( ( script,
          storage,
          input,
          amount,
          balance,
          chain_id,
          source,
          payer,
          gas,
          entrypoint ),
        unparsing_mode )

  let trace_code_normalized ctxt block ?gas ?(entrypoint = "default") ~script
      ~storage ~input ~amount ~balance ~chain_id ~source ~payer ~unparsing_mode
      =
    RPC_context.make_call0
      trace_code_normalized
      ctxt
      block
      ()
      ( ( script,
          storage,
          input,
          amount,
          balance,
          chain_id,
          source,
          payer,
          gas,
          entrypoint ),
        unparsing_mode )

  let big_map_get_normalized ctxt block id key ~unparsing_mode =
    RPC_context.make_call2
      big_map_get_normalized
      ctxt
      block
      id
      key
      ()
      unparsing_mode
end
