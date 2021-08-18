(** Testing
    -------
    Component:    Protocol (interpretation)
    Dependencies: src/proto_010_PtGRANAD/lib_protocol/script_interpreter.ml
    Invocation:   dune exec src/proto_010_PtGRANAD/lib_protocol/test/main.exe -- test "^interpretation$"
    Subject:      Interpretation of Michelson scripts
*)

open Protocol
open Alpha_context
open Script_interpreter

let ( >>=?? ) x y =
  x >>= function
  | Ok s -> y s
  | Error err -> Lwt.return @@ Error (Environment.wrap_tztrace err)

let test_context () =
  Context.init 3 >>=? fun (b, _cs) ->
  Incremental.begin_construction b >>=? fun v ->
  return (Incremental.alpha_ctxt v)

let default_source = Contract.implicit_contract Signature.Public_key_hash.zero

let default_step_constants =
  {
    source = default_source;
    payer = default_source;
    self = default_source;
    amount = Tez.zero;
    chain_id = Chain_id.zero;
  }

(** Helper function that parses and types a script, its initial storage and
   parameters from strings. It then executes the typed script with the storage
   and parameter and returns the result. *)
let run_script ctx ?(step_constants = default_step_constants) contract
    ?(entrypoint = "default") ~storage ~parameter () =
  let contract_expr = Expr.from_string contract in
  let storage_expr = Expr.from_string storage in
  let parameter_expr = Expr.from_string parameter in
  let script =
    Script.{code = lazy_expr contract_expr; storage = lazy_expr storage_expr}
  in
  Script_interpreter.execute
    ctx
    Readable
    step_constants
    ~script
    ~entrypoint
    ~parameter:parameter_expr
    ~internal:false
  >>=?? fun res -> return res

let logger =
  Script_typed_ir.
    {
      log_interp = (fun _ _ _ _ _ -> ());
      log_entry = (fun _ _ _ _ _ -> ());
      log_exit = (fun _ _ _ _ _ -> ());
      log_control = (fun _ -> ());
      get_log = (fun () -> Lwt.return (Ok None));
    }

let run_step ctxt code accu stack =
  let open Script_interpreter in
  step None ctxt default_step_constants code accu stack
  >>=? fun ((_, _, ctxt') as r) ->
  step (Some logger) ctxt default_step_constants code accu stack
  >>=? fun (_, _, ctxt'') ->
  if Gas.(remaining_operation_gas ctxt' <> remaining_operation_gas ctxt'') then
    Alcotest.failf "Logging should not have an impact on gas consumption." ;
  return r

(** Runs a script with an ill-typed parameter and verifies that a
    Bad_contract_parameter error is returned. *)
let test_bad_contract_parameter () =
  test_context () >>=? fun ctx ->
  (* Run script with a parameter of wrong type *)
  run_script
    ctx
    "{parameter unit; storage unit; code { CAR; NIL operation; PAIR }}"
    ~storage:"Unit"
    ~parameter:"0"
    ()
  >>= function
  | Ok _ -> Alcotest.fail "expected an error"
  | Error (Environment.Ecoproto_error (Bad_contract_parameter source') :: _) ->
      Test_services.(check Testable.contract)
        "incorrect field in Bad_contract_parameter"
        default_source
        source' ;
      return_unit
  | Error errs ->
      Alcotest.failf "Unexpected error: %a" Error_monad.pp_print_error errs

let test_multiplication_close_to_overflow_passes () =
  test_context () >>=? fun ctx ->
  (* Get sure that multiplication deals with numbers between 2^62 and
     2^63 without overflowing *)
  run_script
    ctx
    "{parameter unit;storage unit;code {DROP; PUSH mutez 2944023901536524477; \
     PUSH nat 2; MUL; DROP; UNIT; NIL operation; PAIR}}"
    ~storage:"Unit"
    ~parameter:"Unit"
    ()
  >>= function
  | Ok _ -> return_unit
  | Error errs ->
      Alcotest.failf "Unexpected error: %a" Error_monad.pp_print_error errs

let read_file filename =
  let ch = open_in filename in
  let s = really_input_string ch (in_channel_length ch) in
  close_in ch ;
  s

(* Confront the Michelson interpreter to deep recursions. *)
let test_stack_overflow () =
  let open Script_typed_ir in
  test_context () >>=? fun ctxt ->
  let stack = Bot_t in
  let descr kinstr = {kloc = 0; kbef = stack; kaft = stack; kinstr} in
  let kinfo = {iloc = -1; kstack_ty = stack} in
  let kinfo' = {iloc = -1; kstack_ty = Item_t (Bool_t None, stack, None)} in
  let enorme_et_seq n =
    let rec aux n acc =
      if n = 0 then acc
      else aux (n - 1) (IConst (kinfo, true, IDrop (kinfo', acc)))
    in
    aux n (IHalt kinfo)
  in
  run_step ctxt (descr (enorme_et_seq 1_000_000)) EmptyCell EmptyCell
  >>= function
  | Ok _ -> return_unit
  | Error trace ->
      let trace_string =
        Format.asprintf "%a" Environment.Error_monad.pp_trace trace
      in
      Alcotest.failf "Unexpected error (%s) at %s" trace_string __LOC__

let test_stack_overflow_in_lwt () =
  let open Script_typed_ir in
  test_context () >>=? fun ctxt ->
  let stack = Bot_t in
  let item ty s = Item_t (ty, s, None) in
  let unit_t = Unit_t None in
  let unit_k = Unit_key None in
  let bool_t = Bool_t None in
  let big_map_t = Big_map_t (unit_k, unit_t, None) in
  let descr kinstr = {kloc = 0; kbef = stack; kaft = stack; kinstr} in
  let kinfo s = {iloc = -1; kstack_ty = s} in
  let stack1 = item big_map_t Bot_t in
  let stack2 = item big_map_t (item big_map_t Bot_t) in
  let stack3 = item unit_t stack2 in
  let stack4 = item bool_t stack1 in
  let push_empty_big_map k =
    IEmpty_big_map (kinfo stack, Unit_key None, Unit_t None, k)
  in
  let large_mem_seq n =
    let rec aux n acc =
      if n = 0 then acc
      else
        aux
          (n - 1)
          (IDup
             ( kinfo stack1,
               IConst
                 ( kinfo stack2,
                   (),
                   IBig_map_mem (kinfo stack3, IDrop (kinfo stack4, acc)) ) ))
    in
    aux n (IDrop (kinfo stack1, IHalt (kinfo stack)))
  in
  let script = push_empty_big_map (large_mem_seq 1_000_000) in
  run_step ctxt (descr script) EmptyCell EmptyCell >>= function
  | Ok _ -> return_unit
  | Error trace ->
      let trace_string =
        Format.asprintf "%a" Environment.Error_monad.pp_trace trace
      in
      Alcotest.failf "Unexpected error (%s) at %s" trace_string __LOC__

(** Test the encoding/decoding of script_interpreter.ml specific errors *)
let test_json_roundtrip name testable enc v =
  let v' =
    Data_encoding.Json.destruct enc (Data_encoding.Json.construct enc v)
  in
  Alcotest.check
    testable
    (Format.asprintf "round trip should not change value of %s" name)
    v
    v' ;
  return_unit

(** Encoding/decoding of script_interpreter.ml specific errors. *)
let test_json_roundtrip_err name e () =
  test_json_roundtrip
    name
    Testable.protocol_error
    Environment.Error_monad.error_encoding
    e

let error_encoding_tests =
  let contract_zero =
    Contract.implicit_contract Signature.Public_key_hash.zero
  in
  let script_expr_int = Micheline.strip_locations (Micheline.Int (0, Z.zero)) in
  List.map
    (fun (name, e) ->
      Test_services.tztest
        (Format.asprintf "test error encoding: %s" name)
        `Quick
        (test_json_roundtrip_err name e))
    [
      ("Reject", Reject (0, script_expr_int, None));
      ("Overflow", Overflow (0, None));
      ( "Runtime_contract_error",
        Runtime_contract_error (contract_zero, script_expr_int) );
      ("Bad_contract_parameter", Bad_contract_parameter contract_zero);
      ("Cannot_serialize_failure", Cannot_serialize_failure);
      ("Cannot_serialize_storage", Cannot_serialize_storage);
    ]

let tests =
  [
    Test_services.tztest
      "test bad contract error"
      `Quick
      test_bad_contract_parameter;
    Test_services.tztest
      "check robustness overflow error"
      `Slow
      test_stack_overflow;
    Test_services.tztest
      "check robustness overflow error in lwt"
      `Slow
      test_stack_overflow_in_lwt;
    Test_services.tztest
      "test multiplication no illegitimate overflow"
      `Quick
      test_multiplication_close_to_overflow_passes;
    Test_services.tztest "test stack overflow error" `Slow test_stack_overflow;
  ]
  @ error_encoding_tests
