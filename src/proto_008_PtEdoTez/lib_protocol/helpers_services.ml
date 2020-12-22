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

open Alpha_context

type error += Cannot_parse_operation (* `Branch *)

let () =
  register_error_kind
    `Branch
    ~id:"operation.cannot_parse"
    ~title:"Cannot parse operation"
    ~description:"The operation is ill-formed or for another protocol version"
    ~pp:(fun ppf () -> Format.fprintf ppf "The operation cannot be parsed")
    Data_encoding.unit
    (function Cannot_parse_operation -> Some () | _ -> None)
    (fun () -> Cannot_parse_operation)

let parse_operation (op : Operation.raw) =
  match
    Data_encoding.Binary.of_bytes Operation.protocol_data_encoding op.proto
  with
  | Some protocol_data ->
      ok {shell = op.shell; protocol_data}
  | None ->
      error Cannot_parse_operation

let path = RPC_path.(open_root / "helpers")

module Scripts = struct
  module S = struct
    open Data_encoding

    let path = RPC_path.(path / "scripts")

    let run_code_input_encoding =
      obj10
        (req "script" Script.expr_encoding)
        (req "storage" Script.expr_encoding)
        (req "input" Script.expr_encoding)
        (req "amount" Tez.encoding)
        (req "balance" Tez.encoding)
        (req "chain_id" Chain_id.encoding)
        (opt "source" Contract.encoding)
        (opt "payer" Contract.encoding)
        (opt "gas" Gas.Arith.z_integral_encoding)
        (dft "entrypoint" string "default")

    let trace_encoding =
      def "scripted.trace" @@ list
      @@ obj3
           (req "location" Script.location_encoding)
           (req "gas" Gas.encoding)
           (req
              "stack"
              (list
                 (obj2 (req "item" Script.expr_encoding) (opt "annot" string))))

    let run_code =
      RPC_service.post_service
        ~description:"Run a piece of code in the current context"
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
                (req "operations" (list Operation.internal_operation_encoding))
                (opt "big_map_diff" Lazy_storage.legacy_big_map_diff_encoding)
                (opt "lazy_storage_diff" Lazy_storage.encoding)))
        RPC_path.(path / "run_code")

    let trace_code =
      RPC_service.post_service
        ~description:
          "Run a piece of code in the current context, keeping a trace"
        ~query:RPC_query.empty
        ~input:run_code_input_encoding
        ~output:
          (conv
             (fun (storage, operations, trace, lazy_storage_diff) ->
               ( storage,
                 operations,
                 trace,
                 lazy_storage_diff,
                 lazy_storage_diff ))
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
                (req "operations" (list Operation.internal_operation_encoding))
                (req "trace" trace_encoding)
                (opt "big_map_diff" Lazy_storage.legacy_big_map_diff_encoding)
                (opt "lazy_storage_diff" Lazy_storage.encoding)))
        RPC_path.(path / "trace_code")

    let typecheck_code =
      RPC_service.post_service
        ~description:"Typecheck a piece of code in the current context"
        ~query:RPC_query.empty
        ~input:
          (obj3
             (req "program" Script.expr_encoding)
             (opt "gas" Gas.Arith.z_integral_encoding)
             (opt "legacy" bool))
        ~output:
          (obj2
             (req "type_map" Script_tc_errors_registration.type_map_enc)
             (req "gas" Gas.encoding))
        RPC_path.(path / "typecheck_code")

    let typecheck_data =
      RPC_service.post_service
        ~description:
          "Check that some data expression is well formed and of a given type \
           in the current context"
        ~query:RPC_query.empty
        ~input:
          (obj4
             (req "data" Script.expr_encoding)
             (req "type" Script.expr_encoding)
             (opt "gas" Gas.Arith.z_integral_encoding)
             (opt "legacy" bool))
        ~output:(obj1 (req "gas" Gas.encoding))
        RPC_path.(path / "typecheck_data")

    let pack_data =
      RPC_service.post_service
        ~description:
          "Computes the serialized version of some data expression using the \
           same algorithm as script instruction PACK"
        ~input:
          (obj3
             (req "data" Script.expr_encoding)
             (req "type" Script.expr_encoding)
             (opt "gas" Gas.Arith.z_integral_encoding))
        ~output:(obj2 (req "packed" bytes) (req "gas" Gas.encoding))
        ~query:RPC_query.empty
        RPC_path.(path / "pack_data")

    let run_operation =
      RPC_service.post_service
        ~description:"Run an operation without signature checks"
        ~query:RPC_query.empty
        ~input:
          (obj2
             (req "operation" Operation.encoding)
             (req "chain_id" Chain_id.encoding))
        ~output:Apply_results.operation_data_and_metadata_encoding
        RPC_path.(path / "run_operation")

    let entrypoint_type =
      RPC_service.post_service
        ~description:"Return the type of the given entrypoint"
        ~query:RPC_query.empty
        ~input:
          (obj2
             (req "script" Script.expr_encoding)
             (dft "entrypoint" string "default"))
        ~output:(obj1 (req "entrypoint_type" Script.expr_encoding))
        RPC_path.(path / "entrypoint")

    let list_entrypoints =
      RPC_service.post_service
        ~description:"Return the list of entrypoints of the given script"
        ~query:RPC_query.empty
        ~input:(obj1 (req "script" Script.expr_encoding))
        ~output:
          (obj2
             (dft
                "unreachable"
                (Data_encoding.list
                   (obj1
                      (req
                         "path"
                         (Data_encoding.list
                            Michelson_v1_primitives.prim_encoding))))
                [])
             (req "entrypoints" (assoc Script.expr_encoding)))
        RPC_path.(path / "entrypoints")
  end

  module Traced_interpreter = struct
    type error += Cannot_serialize_log

    let () =
      (* Cannot serialize log *)
      register_error_kind
        `Temporary
        ~id:"michelson_v1.cannot_serialize_log"
        ~title:"Not enough gas to serialize execution trace"
        ~description:
          "Execution trace with stacks was to big to be serialized with the \
           provided gas"
        Data_encoding.empty
        (function Cannot_serialize_log -> Some () | _ -> None)
        (fun () -> Cannot_serialize_log)

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
          (Script.expr * string option) list tzresult Lwt.t = function
        | (Empty_t, ()) ->
            return_nil
        | (Item_t (ty, rest_ty, annot), (v, rest)) ->
            Script_ir_translator.unparse_data ctxt Readable ty v
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
        map_s
          (fun (Log (ctxt, loc, stack, stack_ty)) ->
            trace Cannot_serialize_log (unparse_stack ctxt (stack, stack_ty))
            >>=? fun stack -> return (loc, Gas.level ctxt, stack))
          !log
        >>=? fun res -> return (Some (List.rev res))
    end

    let execute ctxt mode step_constants ~script ~entrypoint ~parameter =
      let module Logger = Trace_logger () in
      let open Script_interpreter in
      let logger = (module Logger : STEP_LOGGER) in
      execute
        ~logger
        ctxt
        mode
        step_constants
        ~script
        ~entrypoint
        ~parameter
        ~internal:true
      >>=? fun {ctxt; storage; lazy_storage_diff; operations} ->
      Logger.get_log ()
      >|=? fun trace ->
      let trace = Option.value ~default:[] trace in
      ({ctxt; storage; lazy_storage_diff; operations}, trace)
  end

  let typecheck_data :
      legacy:bool ->
      context ->
      Script.expr * Script.expr ->
      context tzresult Lwt.t =
   fun ~legacy ctxt (data, exp_ty) ->
    record_trace
      (Script_tc_errors.Ill_formed_type (None, exp_ty, 0))
      (Script_ir_translator.parse_parameter_ty
         ctxt
         ~legacy
         (Micheline.root exp_ty))
    >>?= fun (Ex_ty exp_ty, ctxt) ->
    trace_eval
      (fun () ->
        Lwt.return
          ( Script_ir_translator.serialize_ty_for_error ctxt exp_ty
          >|? fun (exp_ty, _ctxt) ->
          Script_tc_errors.Ill_typed_data (None, data, exp_ty) ))
      (let allow_forged =
         true
         (* Safe since we ignore the value afterwards. *)
       in
       Script_ir_translator.parse_data
         ctxt
         ~legacy
         ~allow_forged
         exp_ty
         (Micheline.root data))
    >|=? fun (_, ctxt) -> ctxt

  let register () =
    let open Services_registration in
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
      S.run_code
      (fun ctxt
           ()
           ( code,
             storage,
             parameter,
             amount,
             balance,
             chain_id,
             source,
             payer,
             gas,
             entrypoint )
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
          Readable
          step_constants
          ~script:{storage; code}
          ~entrypoint
          ~parameter
          ~internal:true
        >|=? fun {Script_interpreter.storage; operations; lazy_storage_diff; _} ->
        (storage, operations, lazy_storage_diff)) ;
    register0
      S.trace_code
      (fun ctxt
           ()
           ( code,
             storage,
             parameter,
             amount,
             balance,
             chain_id,
             source,
             payer,
             gas,
             entrypoint )
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
        Traced_interpreter.execute
          ctxt
          Readable
          step_constants
          ~script:{storage; code}
          ~entrypoint
          ~parameter
        >|=? fun ( { Script_interpreter.storage;
                     operations;
                     lazy_storage_diff;
                     _ },
                   trace ) ->
        (storage, operations, trace, lazy_storage_diff)) ;
    register0 S.typecheck_code (fun ctxt () (expr, maybe_gas, legacy) ->
        let legacy = Option.value ~default:false legacy in
        let ctxt =
          match maybe_gas with
          | None ->
              Gas.set_unlimited ctxt
          | Some gas ->
              Gas.set_limit ctxt gas
        in
        Script_ir_translator.typecheck_code ~legacy ctxt expr
        >|=? fun (res, ctxt) -> (res, Gas.level ctxt)) ;
    register0 S.typecheck_data (fun ctxt () (data, ty, maybe_gas, legacy) ->
        let legacy = Option.value ~default:false legacy in
        let ctxt =
          match maybe_gas with
          | None ->
              Gas.set_unlimited ctxt
          | Some gas ->
              Gas.set_limit ctxt gas
        in
        typecheck_data ~legacy ctxt (data, ty) >|=? fun ctxt -> Gas.level ctxt) ;
    register0 S.pack_data (fun ctxt () (expr, typ, maybe_gas) ->
        let open Script_ir_translator in
        let ctxt =
          match maybe_gas with
          | None ->
              Gas.set_unlimited ctxt
          | Some gas ->
              Gas.set_limit ctxt gas
        in
        parse_packable_ty ctxt ~legacy:true (Micheline.root typ)
        >>?= fun (Ex_ty typ, ctxt) ->
        parse_data
          ctxt
          ~legacy:true
          ~allow_forged:true
          typ
          (Micheline.root expr)
        >>=? fun (data, ctxt) ->
        Script_ir_translator.pack_data ctxt typ data
        >|=? fun (bytes, ctxt) -> (bytes, Gas.level ctxt)) ;
    register0
      S.run_operation
      (fun ctxt
           ()
           ({shell; protocol_data = Operation_data protocol_data}, chain_id)
           ->
        (* this code is a duplicate of Apply without signature check *)
        let partial_precheck_manager_contents (type kind) ctxt
            (op : kind Kind.manager contents) : context tzresult Lwt.t =
          let (Manager_operation
                {source; fee; counter; operation; gas_limit; storage_limit}) =
            op
          in
          Gas.check_limit ctxt gas_limit
          >>?= fun () ->
          let ctxt = Gas.set_limit ctxt gas_limit in
          Fees.check_storage_limit ctxt storage_limit
          >>?= fun () ->
          Contract.must_be_allocated ctxt (Contract.implicit_contract source)
          >>=? fun () ->
          Contract.check_counter_increment ctxt source counter
          >>=? fun () ->
          ( match operation with
          | Reveal pk ->
              Contract.reveal_manager_key ctxt source pk
          | Transaction {parameters; _} ->
              (* Here the data comes already deserialized, so we need to fake the deserialization to mimic apply *)
              let arg_bytes =
                Data_encoding.Binary.to_bytes_exn
                  Script.lazy_expr_encoding
                  parameters
              in
              let arg =
                match
                  Data_encoding.Binary.of_bytes
                    Script.lazy_expr_encoding
                    arg_bytes
                with
                | Some arg ->
                    arg
                | None ->
                    assert false
              in
              (* Fail quickly if not enough gas for minimal deserialization cost *)
              Lwt.return
              @@ record_trace Apply.Gas_quota_exceeded_init_deserialize
              @@ ( Gas.check_enough ctxt (Script.minimal_deserialize_cost arg)
                 >>? fun () ->
                 (* Fail if not enough gas for complete deserialization cost *)
                 Script.force_decode_in_context ctxt arg
                 >|? fun (_arg, ctxt) -> ctxt )
          | Origination {script; _} ->
              (* Here the data comes already deserialized, so we need to fake the deserialization to mimic apply *)
              let script_bytes =
                Data_encoding.Binary.to_bytes_exn Script.encoding script
              in
              let script =
                match
                  Data_encoding.Binary.of_bytes Script.encoding script_bytes
                with
                | Some script ->
                    script
                | None ->
                    assert false
              in
              Lwt.return
              @@ record_trace Apply.Gas_quota_exceeded_init_deserialize
              @@ ( Gas.(
                     check_enough
                       (* Fail quickly if not enough gas for minimal deserialization cost *)
                       ctxt
                       ( Script.minimal_deserialize_cost script.code
                       +@ Script.minimal_deserialize_cost script.storage ))
                 >>? fun () ->
                 (* Fail if not enough gas for complete deserialization cost *)
                 Script.force_decode_in_context ctxt script.code
                 >>? fun (_code, ctxt) ->
                 Script.force_decode_in_context ctxt script.storage
                 >|? fun (_storage, ctxt) -> ctxt )
          | _ ->
              return ctxt )
          >>=? fun ctxt ->
          Contract.get_manager_key ctxt source
          >>=? fun _public_key ->
          (* signature check unplugged from here *)
          Contract.increment_counter ctxt source
          >>=? fun ctxt ->
          Contract.spend ctxt (Contract.implicit_contract source) fee
        in
        let rec partial_precheck_manager_contents_list :
            type kind.
            Alpha_context.t ->
            kind Kind.manager contents_list ->
            context tzresult Lwt.t =
         fun ctxt contents_list ->
          match contents_list with
          | Single (Manager_operation _ as op) ->
              partial_precheck_manager_contents ctxt op
          | Cons ((Manager_operation _ as op), rest) ->
              partial_precheck_manager_contents ctxt op
              >>=? fun ctxt -> partial_precheck_manager_contents_list ctxt rest
        in
        let ret contents =
          ( Operation_data protocol_data,
            Apply_results.Operation_metadata {contents} )
        in
        let operation : _ operation = {shell; protocol_data} in
        let hash = Operation.hash {shell; protocol_data} in
        let ctxt = Contract.init_origination_nonce ctxt hash in
        let baker = Signature.Public_key_hash.zero in
        match protocol_data.contents with
        | Single (Manager_operation _) as op ->
            partial_precheck_manager_contents_list ctxt op
            >>=? fun ctxt ->
            Apply.apply_manager_contents_list ctxt Optimized baker chain_id op
            >|= fun (_ctxt, result) -> ok @@ ret result
        | Cons (Manager_operation _, _) as op ->
            partial_precheck_manager_contents_list ctxt op
            >>=? fun ctxt ->
            Apply.apply_manager_contents_list ctxt Optimized baker chain_id op
            >|= fun (_ctxt, result) -> ok @@ ret result
        | _ ->
            Apply.apply_contents_list
              ctxt
              chain_id
              Optimized
              shell.branch
              baker
              operation
              operation.protocol_data.contents
            >|=? fun (_ctxt, result) -> ret result) ;
    register0 S.entrypoint_type (fun ctxt () (expr, entrypoint) ->
        let ctxt = Gas.set_unlimited ctxt in
        let legacy = false in
        let open Script_ir_translator in
        Lwt.return
          ( parse_toplevel ~legacy expr
          >>? (fun (arg_type, _, _, root_name) ->
                parse_parameter_ty ctxt ~legacy arg_type
                >>? fun (Ex_ty arg_type, _) ->
                Script_ir_translator.find_entrypoint
                  ~root_name
                  arg_type
                  entrypoint)
          >>? fun (_f, Ex_ty ty) ->
          unparse_ty ctxt ty
          >|? fun (ty_node, _) -> Micheline.strip_locations ty_node )) ;
    register0 S.list_entrypoints (fun ctxt () expr ->
        let ctxt = Gas.set_unlimited ctxt in
        let legacy = false in
        let open Script_ir_translator in
        Lwt.return
          ( parse_toplevel ~legacy expr
          >>? fun (arg_type, _, _, root_name) ->
          parse_parameter_ty ctxt ~legacy arg_type
          >>? fun (Ex_ty arg_type, _) ->
          Script_ir_translator.list_entrypoints ~root_name arg_type ctxt
          >|? fun (unreachable_entrypoint, map) ->
          ( unreachable_entrypoint,
            Entrypoints_map.fold
              (fun entry (_, ty) acc ->
                (entry, Micheline.strip_locations ty) :: acc)
              map
              [] ) ))

  let run_code ctxt block ?gas ?(entrypoint = "default") ~script ~storage
      ~input ~amount ~balance ~chain_id ~source ~payer =
    RPC_context.make_call0
      S.run_code
      ctxt
      block
      ()
      ( script,
        storage,
        input,
        amount,
        balance,
        chain_id,
        source,
        payer,
        gas,
        entrypoint )

  let trace_code ctxt block ?gas ?(entrypoint = "default") ~script ~storage
      ~input ~amount ~balance ~chain_id ~source ~payer =
    RPC_context.make_call0
      S.trace_code
      ctxt
      block
      ()
      ( script,
        storage,
        input,
        amount,
        balance,
        chain_id,
        source,
        payer,
        gas,
        entrypoint )

  let typecheck_code ctxt block ?gas ?legacy ~script =
    RPC_context.make_call0 S.typecheck_code ctxt block () (script, gas, legacy)

  let typecheck_data ctxt block ?gas ?legacy ~data ~ty =
    RPC_context.make_call0
      S.typecheck_data
      ctxt
      block
      ()
      (data, ty, gas, legacy)

  let pack_data ctxt block ?gas ~data ~ty =
    RPC_context.make_call0 S.pack_data ctxt block () (data, ty, gas)

  let run_operation ctxt block ~op ~chain_id =
    RPC_context.make_call0 S.run_operation ctxt block () (op, chain_id)

  let entrypoint_type ctxt block ~script ~entrypoint =
    RPC_context.make_call0 S.entrypoint_type ctxt block () (script, entrypoint)

  let list_entrypoints ctxt block ~script =
    RPC_context.make_call0 S.list_entrypoints ctxt block () script
end

module Forge = struct
  module S = struct
    open Data_encoding

    let path = RPC_path.(path / "forge")

    let operations =
      RPC_service.post_service
        ~description:"Forge an operation"
        ~query:RPC_query.empty
        ~input:Operation.unsigned_encoding
        ~output:bytes
        RPC_path.(path / "operations")

    let empty_proof_of_work_nonce =
      Bytes.make Constants_repr.proof_of_work_nonce_size '\000'

    let protocol_data =
      RPC_service.post_service
        ~description:"Forge the protocol-specific part of a block header"
        ~query:RPC_query.empty
        ~input:
          (obj3
             (req "priority" uint16)
             (opt "nonce_hash" Nonce_hash.encoding)
             (dft
                "proof_of_work_nonce"
                (Fixed.bytes Alpha_context.Constants.proof_of_work_nonce_size)
                empty_proof_of_work_nonce))
        ~output:(obj1 (req "protocol_data" bytes))
        RPC_path.(path / "protocol_data")
  end

  let register () =
    let open Services_registration in
    register0_noctxt S.operations (fun () (shell, proto) ->
        return
          (Data_encoding.Binary.to_bytes_exn
             Operation.unsigned_encoding
             (shell, proto))) ;
    register0_noctxt
      S.protocol_data
      (fun () (priority, seed_nonce_hash, proof_of_work_nonce) ->
        return
          (Data_encoding.Binary.to_bytes_exn
             Block_header.contents_encoding
             {priority; seed_nonce_hash; proof_of_work_nonce}))

  module Manager = struct
    let operations ctxt block ~branch ~source ?sourcePubKey ~counter ~fee
        ~gas_limit ~storage_limit operations =
      Contract_services.manager_key ctxt block source
      >>= function
      | Error _ as e ->
          Lwt.return e
      | Ok revealed ->
          let ops =
            List.map
              (fun (Manager operation) ->
                Contents
                  (Manager_operation
                     {
                       source;
                       counter;
                       operation;
                       fee;
                       gas_limit;
                       storage_limit;
                     }))
              operations
          in
          let ops =
            match (sourcePubKey, revealed) with
            | (None, _) | (_, Some _) ->
                ops
            | (Some pk, None) ->
                let operation = Reveal pk in
                Contents
                  (Manager_operation
                     {
                       source;
                       counter;
                       operation;
                       fee;
                       gas_limit;
                       storage_limit;
                     })
                :: ops
          in
          RPC_context.make_call0
            S.operations
            ctxt
            block
            ()
            ({branch}, Operation.of_list ops)

    let reveal ctxt block ~branch ~source ~sourcePubKey ~counter ~fee () =
      operations
        ctxt
        block
        ~branch
        ~source
        ~sourcePubKey
        ~counter
        ~fee
        ~gas_limit:Gas.Arith.zero
        ~storage_limit:Z.zero
        []

    let transaction ctxt block ~branch ~source ?sourcePubKey ~counter ~amount
        ~destination ?(entrypoint = "default") ?parameters ~gas_limit
        ~storage_limit ~fee () =
      let parameters =
        Option.fold
          ~some:Script.lazy_expr
          ~none:Script.unit_parameter
          parameters
      in
      operations
        ctxt
        block
        ~branch
        ~source
        ?sourcePubKey
        ~counter
        ~fee
        ~gas_limit
        ~storage_limit
        [Manager (Transaction {amount; parameters; destination; entrypoint})]

    let origination ctxt block ~branch ~source ?sourcePubKey ~counter ~balance
        ?delegatePubKey ~script ~gas_limit ~storage_limit ~fee () =
      operations
        ctxt
        block
        ~branch
        ~source
        ?sourcePubKey
        ~counter
        ~fee
        ~gas_limit
        ~storage_limit
        [ Manager
            (Origination
               {
                 delegate = delegatePubKey;
                 script;
                 credit = balance;
                 preorigination = None;
               }) ]

    let delegation ctxt block ~branch ~source ?sourcePubKey ~counter ~fee
        delegate =
      operations
        ctxt
        block
        ~branch
        ~source
        ?sourcePubKey
        ~counter
        ~fee
        ~gas_limit:Gas.Arith.zero
        ~storage_limit:Z.zero
        [Manager (Delegation delegate)]
  end

  let operation ctxt block ~branch operation =
    RPC_context.make_call0
      S.operations
      ctxt
      block
      ()
      ({branch}, Contents_list (Single operation))

  let endorsement ctxt b ~branch ~level () =
    operation ctxt b ~branch (Endorsement {level})

  let proposals ctxt b ~branch ~source ~period ~proposals () =
    operation ctxt b ~branch (Proposals {source; period; proposals})

  let ballot ctxt b ~branch ~source ~period ~proposal ~ballot () =
    operation ctxt b ~branch (Ballot {source; period; proposal; ballot})

  let seed_nonce_revelation ctxt block ~branch ~level ~nonce () =
    operation ctxt block ~branch (Seed_nonce_revelation {level; nonce})

  let double_baking_evidence ctxt block ~branch ~bh1 ~bh2 () =
    operation ctxt block ~branch (Double_baking_evidence {bh1; bh2})

  let double_endorsement_evidence ctxt block ~branch ~op1 ~op2 () =
    operation ctxt block ~branch (Double_endorsement_evidence {op1; op2})

  let empty_proof_of_work_nonce =
    Bytes.make Constants_repr.proof_of_work_nonce_size '\000'

  let protocol_data ctxt block ~priority ?seed_nonce_hash
      ?(proof_of_work_nonce = empty_proof_of_work_nonce) () =
    RPC_context.make_call0
      S.protocol_data
      ctxt
      block
      ()
      (priority, seed_nonce_hash, proof_of_work_nonce)
end

module Parse = struct
  module S = struct
    open Data_encoding

    let path = RPC_path.(path / "parse")

    let operations =
      RPC_service.post_service
        ~description:"Parse operations"
        ~query:RPC_query.empty
        ~input:
          (obj2
             (req "operations" (list (dynamic_size Operation.raw_encoding)))
             (opt "check_signature" bool))
        ~output:(list (dynamic_size Operation.encoding))
        RPC_path.(path / "operations")

    let block =
      RPC_service.post_service
        ~description:"Parse a block"
        ~query:RPC_query.empty
        ~input:Block_header.raw_encoding
        ~output:Block_header.protocol_data_encoding
        RPC_path.(path / "block")
  end

  let parse_protocol_data protocol_data =
    match
      Data_encoding.Binary.of_bytes
        Block_header.protocol_data_encoding
        protocol_data
    with
    | None ->
        failwith "Cant_parse_protocol_data"
    | Some protocol_data ->
        protocol_data

  let register () =
    let open Services_registration in
    register0 S.operations (fun _ctxt () (operations, check) ->
        map_s
          (fun raw ->
            parse_operation raw
            >>?= fun op ->
            ( match check with
            | Some true ->
                return_unit (* FIXME *)
            (* I.check_signature ctxt *)
            (* op.protocol_data.signature op.shell op.protocol_data.contents *)
            | Some false | None ->
                return_unit )
            >|=? fun () -> op)
          operations) ;
    register0_noctxt S.block (fun () raw_block ->
        return @@ parse_protocol_data raw_block.protocol_data)

  let operations ctxt block ?check operations =
    RPC_context.make_call0 S.operations ctxt block () (operations, check)

  let block ctxt block shell protocol_data =
    RPC_context.make_call0
      S.block
      ctxt
      block
      ()
      ({shell; protocol_data} : Block_header.raw)
end

module S = struct
  open Data_encoding

  type level_query = {offset : int32}

  let level_query : level_query RPC_query.t =
    let open RPC_query in
    query (fun offset -> {offset})
    |+ field "offset" RPC_arg.int32 0l (fun t -> t.offset)
    |> seal

  let current_level =
    RPC_service.get_service
      ~description:
        "Returns the level of the interrogated block, or the one of a block \
         located `offset` blocks after in the chain (or before when \
         negative). For instance, the next block if `offset` is 1."
      ~query:level_query
      ~output:Level.compat_encoding
      RPC_path.(path / "current_level")

  let levels_in_current_cycle =
    RPC_service.get_service
      ~description:"Levels of a cycle"
      ~query:level_query
      ~output:
        (obj2 (req "first" Raw_level.encoding) (req "last" Raw_level.encoding))
      RPC_path.(path / "levels_in_current_cycle")
end

let register () =
  Scripts.register () ;
  Forge.register () ;
  Parse.register () ;
  let open Services_registration in
  register0 S.current_level (fun ctxt q () ->
      let level =
        Level.from_raw ctxt ~offset:q.offset (Level.current ctxt).level
      in
      Alpha_context.Voting_period.get_rpc_fixed_current_info ctxt
      >|=? fun {voting_period; remaining; _} ->
      let blocks_per_voting_period = Constants.blocks_per_voting_period ctxt in
      let div_rem = Int32.(rem q.offset blocks_per_voting_period) in
      let index_offset =
        Int32.(
          add
            (div q.offset blocks_per_voting_period)
            (if Compare.Int32.(div_rem > remaining) then 1l else 0l))
      in
      let voting_period_index = Int32.add voting_period.index index_offset in
      let start_position =
        Int32.(
          add
            voting_period.start_position
            (mul index_offset blocks_per_voting_period))
      in
      let voting_period_position =
        Int32.(sub level.level_position start_position)
      in
      Level.to_deprecated_type
        level
        ~voting_period_index
        ~voting_period_position) ;
  register0 S.levels_in_current_cycle (fun ctxt q () ->
      let levels = Level.levels_in_current_cycle ctxt ~offset:q.offset () in
      match levels with
      | [] ->
          raise Not_found
      | _ ->
          let first = List.hd (List.rev levels) in
          let last = List.hd levels in
          return (first.level, last.level))

let current_level ctxt ?(offset = 0l) block =
  RPC_context.make_call0 S.current_level ctxt block {offset} ()

let levels_in_current_cycle ctxt ?(offset = 0l) block =
  RPC_context.make_call0 S.levels_in_current_cycle ctxt block {offset} ()
