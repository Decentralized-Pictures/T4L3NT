(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(* Testing
   -------
   Component:    Michelson
   Invocation:   dune exec tezt/tests/main.exe -- --file views.ml
   Subject:      Call smart contract views to catch performance regressions.
*)

(* This contract registers all SOURCE addresses that ever call it. It has views
   that return registered callers count and the last caller address respectively. *)

let contract_path protocol kind contract =
  sf
    "file:tests_python/contracts_%s/%s/%s"
    (match protocol with
    | Protocol.Alpha -> "alpha"
    | _ -> sf "%03d" @@ Protocol.number protocol)
    kind
    contract

let register_callers_src =
  {|
parameter unit;
storage (list address);
code {
       CDR ;
       SOURCE ;
       CONS ;
       NIL operation ;
       PAIR ;
     };
view "calls_count" unit nat { CDR ; SIZE };
view "last_caller" unit (option address) { CDR ; IF_CONS { DIP { DROP } ; SOME } { NONE address } };
|}

(* This script calls views on register_callers contract and verifies whether
   its responses are consistent, i.e. if the view calls_count returned 0, then
   last caller is None, otherwise – it's Some address. *)
let check_caller_src =
  {|
parameter address ;
storage (option address) ;
code {
       CAR ;
       DUP ;
       UNIT ;
       VIEW "calls_count" nat ;
       IF_NONE { UNIT ; FAILWITH } {} ;
       DIP {
              UNIT ;
              VIEW "last_caller" (option address) ;
           } ;
       PUSH nat 0 ;
       /* Check if the caller address is consistent with given calls count. */
       IFCMPEQ {
                 IF_NONE { UNIT ; FAILWITH } { IF_NONE {} { UNIT ; FAILWITH }} ;
                 NONE address ;
               }
               {
                 IF_NONE { UNIT ; FAILWITH } { IF_NONE { UNIT ; FAILWITH } {}} ;
                 SOME ;
               } ;
       NIL operation ;
       PAIR ;
     }
   |}

let hooks = Tezos_regression.hooks

let test_regression =
  Protocol.register_regression_test
    ~__FILE__
    ~title:"Run views"
    ~tags:["client"; "michelson"]
  @@ fun protocol ->
  let* client = Client.init_mockup ~protocol () in
  let* register_callers =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~alias:"register_calls"
      ~amount:Tez.zero
      ~src:"bootstrap1"
      ~prg:register_callers_src
      ~init:"{}"
      client
  in
  let arg = sf "%S" register_callers in
  let* check_caller =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~alias:"check_caller"
      ~amount:Tez.zero
      ~src:"bootstrap1"
      ~prg:check_caller_src
      ~init:"None"
      client
  in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.one
      ~giver:"bootstrap1"
      ~receiver:check_caller
      ~arg
      client
  in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.one
      ~giver:"bootstrap1"
      ~receiver:register_callers
      client
  in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.one
      ~giver:"bootstrap1"
      ~receiver:check_caller
      ~arg
      client
  in
  unit

let deploy_lib_contract ?(amount = Tez.zero) ~protocol client =
  Client.originate_contract
    ~hooks
    ~burn_cap:Tez.one
    ~alias:"lib"
    ~amount
    ~src:Constant.bootstrap1.alias
    ~prg:(contract_path protocol "opcodes" "view_toplevel_lib.tz")
    ~init:"3"
    client

let test_run_view protocol ~contract ~init ~expected =
  let* client = Client.init_mockup ~protocol () in
  let* lib_contract = deploy_lib_contract ~protocol client in
  let prg = contract_path protocol "opcodes" @@ sf "view_%s.tz" contract in
  let* contract =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~alias:"view"
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.alias
      ~prg
      ~init
      client
  in
  let arg = sf "(Pair 10 \"%s\")" lib_contract in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.zero
      ~giver:Constant.bootstrap1.alias
      ~receiver:contract
      ~arg
      client
  in
  let* actual =
    Client.contract_storage ~unparsing_mode:Optimized contract client
  in
  Check.((String.trim actual = expected) string)
    ~error_msg:"expected storage %R, got %L" ;
  unit

let test_all_view_runs protocols =
  [
    ("op_id", "(Pair 0 0)", "Pair 10 3");
    ("op_add", "42", "13");
    ("fib", "0", "55");
    ("mutual_recursion", "0", "20");
    ("op_nonexistent_func", "True", "False");
    ("op_nonexistent_addr", "True", "False");
    ("op_toplevel_inconsistent_input_type", "5", "0");
    ("op_toplevel_inconsistent_output_type", "True", "False");
  ]
  |> List.iter @@ fun (contract, init, expected) ->
     Protocol.register_test
       ~__FILE__
       ~title:(sf "Test view runtimes - %s - %s" contract init)
       ~tags:["client"; "michelson"]
       (fun protocol -> test_run_view ~contract ~init ~expected protocol)
       protocols

let test_create_contract =
  Protocol.register_test
    ~__FILE__
    ~title:"Create contract with view"
    ~tags:["client"; "michelson"]
  @@ fun protocol ->
  let* client = Client.init_mockup ~protocol () in
  let* contract =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.alias
      ~prg:(contract_path protocol "opcodes" "create_contract_with_view.tz")
      ~init:"None"
      ~alias:"view"
      client
  in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.zero
      ~giver:Constant.bootstrap1.alias
      ~receiver:contract
      ~arg:"Unit"
      client
  in
  let* addr =
    Client.contract_storage ~unparsing_mode:Optimized contract client
  in
  let addr = String.sub addr 5 @@ (String.length addr - 5) in
  let* contract =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.alias
      ~prg:(contract_path protocol "opcodes" "view_op_constant.tz")
      ~init:"2"
      ~alias:"contract"
      client
  in
  let expected = "10" in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.zero
      ~giver:Constant.bootstrap1.alias
      ~receiver:contract
      ~arg:(sf "Pair %s %s" expected addr)
      client
  in
  let* actual =
    Client.contract_storage ~unparsing_mode:Optimized contract client
  in
  Check.((String.trim actual = expected) string ~__LOC__)
    ~error_msg:"expected storage %R, got %L" ;
  unit

let test_view_step_constant =
  Protocol.register_test
    ~__FILE__
    ~title:"Step constants in view"
    ~tags:["client"; "michelson"]
  @@ fun protocol ->
  let* client = Client.init_mockup ~protocol () in
  let amount = 999000000 in
  let* lib_contract =
    deploy_lib_contract ~protocol ~amount:(Tez.of_mutez_int amount) client
  in
  let* contract =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.alias
      ~prg:(contract_path protocol "opcodes" "view_op_test_step_contants.tz")
      ~init:"None"
      ~alias:"view"
      client
  in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.zero
      ~giver:Constant.bootstrap1.alias
      ~receiver:contract
      ~arg:(sf "\"%s\"" lib_contract)
      client
  in
  let* actual =
    Client.contract_storage ~unparsing_mode:Readable contract client
  in
  let expected =
    sf
      {|Some (Pair (Pair 0 %d)
           (Pair "%s" "%s")
           "%s")
|}
      amount
      lib_contract
      contract
      Constant.bootstrap1.public_key_hash
  in
  Check.((actual = expected) string ~__LOC__)
    ~error_msg:"expected storage %R, got %L" ;
  unit

let test_consts_after_view ~contract ~expected protocol =
  let* client = Client.init_mockup ~protocol () in
  let* lib_contract = deploy_lib_contract ~protocol client in
  let* contract =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.one
      ~src:Constant.bootstrap1.alias
      ~prg:(contract_path protocol "opcodes" @@ sf "%s.tz" contract)
      ~init:(sf "%S" lib_contract)
      ~alias:"view"
      client
  in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.zero
      ~giver:Constant.bootstrap1.alias
      ~receiver:contract
      ~arg:(sf "%S" lib_contract)
      client
  in
  let expected =
    match expected with
    | `Contract -> sf "%S\n" contract
    | `Sender -> sf "%S\n" Constant.bootstrap1.public_key_hash
  in
  let* actual =
    Client.contract_storage ~unparsing_mode:Readable contract client
  in
  Check.((actual = expected) string ~__LOC__)
    ~error_msg:"expected storage %R, got %L" ;
  unit

let test_self_after_view_suite protocols =
  ["self_after_view"; "self_after_fib_view"; "self_after_nonexistent_view"]
  |> List.iter @@ fun contract ->
     Protocol.register_test
       ~__FILE__
       ~title:(sf "self after view - %s" contract)
       ~tags:["client"; "michelson"]
       (test_consts_after_view ~contract ~expected:`Contract)
       protocols

let test_self_address_after_view_suite protocols =
  [
    "self_address_after_view";
    "self_address_after_fib_view";
    "self_address_after_nonexistent_view";
  ]
  |> List.iter @@ fun contract ->
     Protocol.register_test
       ~__FILE__
       ~title:(sf "self address after view - %s" contract)
       ~tags:["client"; "michelson"]
       (test_consts_after_view ~contract ~expected:`Contract)
       protocols

let test_sender_after_view_suite protocols =
  [
    "sender_after_view"; "sender_after_fib_view"; "sender_after_nonexistent_view";
  ]
  |> List.iter @@ fun contract ->
     Protocol.register_test
       ~__FILE__
       ~title:(sf "sender after view - %s" contract)
       ~tags:["client"; "michelson"]
       (test_consts_after_view ~contract ~expected:`Sender)
       protocols

let test_balance_after_view ~contract protocol =
  let* client = Client.init_mockup ~protocol () in
  let* lib_contract = deploy_lib_contract ~protocol client in
  let contract_amount = Tez.of_int 1000 in
  let transfer_amount = Tez.of_int 10 in
  let* contract =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~amount:contract_amount
      ~src:Constant.bootstrap1.alias
      ~prg:(contract_path protocol "opcodes" @@ sf "%s.tz" contract)
      ~init:"0"
      ~alias:"view"
      client
  in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount:transfer_amount
      ~giver:Constant.bootstrap1.alias
      ~receiver:contract
      ~arg:(sf "\"%s\"" lib_contract)
      client
  in
  let* actual =
    Client.contract_storage ~unparsing_mode:Readable contract client
  in
  let expected =
    Tez.(contract_amount + transfer_amount |> to_mutez) |> sf "%d\n"
  in
  Check.((actual = expected) string ~__LOC__)
    ~error_msg:"expected storage %R, got %L" ;
  unit

let test_balance_after_view_suite protocols =
  [
    "balance_after_view";
    "balance_after_fib_view";
    "balance_after_nonexistent_view";
  ]
  |> List.iter @@ fun contract ->
     Protocol.register_test
       ~__FILE__
       ~title:(sf "balance after view - %s" contract)
       ~tags:["client"; "michelson"]
       (test_balance_after_view ~contract)
       protocols

let test_amount_after_view ~contract protocol =
  let* client = Client.init_mockup ~protocol () in
  let* lib_contract = deploy_lib_contract ~protocol client in
  let* contract =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.(of_int 1000)
      ~src:Constant.bootstrap1.alias
      ~prg:(contract_path protocol "opcodes" @@ sf "%s.tz" contract)
      ~init:"0"
      ~alias:"view"
      client
  in
  let amount = Tez.of_int 3 in
  let* () =
    Client.transfer
      ~hooks
      ~burn_cap:Tez.one
      ~amount
      ~giver:Constant.bootstrap1.alias
      ~receiver:contract
      ~arg:(sf "\"%s\"" lib_contract)
      client
  in
  let* actual =
    Client.contract_storage ~unparsing_mode:Readable contract client
  in
  let expected = amount |> Tez.to_mutez |> sf "%d\n" in
  Check.((actual = expected) string ~__LOC__)
    ~error_msg:"expected storage %R, got %L" ;
  unit

let test_amount_after_view_suite protocols =
  [
    "amount_after_view"; "amount_after_fib_view"; "amount_after_nonexistent_view";
  ]
  |> List.iter @@ fun contract ->
     Protocol.register_test
       ~__FILE__
       ~title:(sf "amount after view - %s" contract)
       ~tags:["client"; "michelson"]
       (test_amount_after_view ~contract)
       protocols

let test_recursive_view =
  Protocol.register_test
    ~__FILE__
    ~title:"Recursive view"
    ~tags:["client"; "michelson"]
  @@ fun protocol ->
  let* client = Client.init_mockup ~protocol () in
  let* contract =
    Client.originate_contract
      ~hooks
      ~burn_cap:Tez.one
      ~amount:Tez.zero
      ~src:Constant.bootstrap1.alias
      ~prg:(contract_path protocol "opcodes" "view_rec.tz")
      ~init:"Unit"
      ~alias:"view"
      client
  in
  Client.spawn_transfer
    ~hooks
    ~gas_limit:5000
    ~amount:Tez.zero
    ~giver:Constant.bootstrap1.alias
    ~receiver:contract
    ~arg:"Unit"
    client
  |> Process.check_error
       ~msg:(rex "Gas limit exceeded during typechecking or execution\\.")

let test_typecheck ~contract ~error protocol =
  let* client = Client.init_mockup ~protocol () in
  Client.spawn_originate_contract
    ~hooks
    ~burn_cap:Tez.one
    ~amount:Tez.zero
    ~src:Constant.bootstrap1.alias
    ~prg:(contract_path protocol "ill_typed" @@ sf "%s.tz" contract)
    ~init:"4"
    ~alias:"view"
    client
  |> Process.check_error ~msg:error

let test_typecheck_suite protocols =
  [
    ( "view_toplevel_bad_type",
      rex "the return of a view block did not match the expected type\\." );
    ( "view_toplevel_bad_return_type",
      rex "the return of a view block did not match the expected type\\." );
    ( "view_toplevel_bad_input_type",
      rex "operator ADD is undefined between string" );
    ("view_toplevel_invalid_arity", rex "primitive view expects 4 arguments");
    ( "view_toplevel_bad_name_too_long",
      rex "exceeds the maximum length of 31 characters" );
    ("view_toplevel_bad_name_invalid_type", rex "only a string can be used here");
    ( "view_toplevel_bad_name_non_printable_char",
      rex "string \\[a-zA-Z0-9_.%@\\]" );
    ( "view_toplevel_duplicated_name",
      rex "the name of view in toplevel should be unique" );
    ("view_toplevel_dupable_type_output", rex "Ticket in unauthorized position");
    ("view_toplevel_dupable_type_input", rex "Ticket in unauthorized position");
    ( "view_toplevel_lazy_storage_input",
      rex "big_map or sapling_state type not expected here" );
    ( "view_toplevel_lazy_storage_output",
      rex "big_map or sapling_state type not expected here" );
    ("view_op_invalid_arity", rex "primitive VIEW expects 2 arguments");
    ("view_op_bad_name_invalid_type", rex "unexpected int, only a string");
    ( "view_op_bad_name_too_long",
      rex "exceeds the maximum length of 31 characters" );
    ("view_op_bad_name_non_printable_char", rex "string \\[a-zA-Z0-9_.%@\\]");
    ("view_op_bad_name_invalid_char_set", rex "string \\[a-zA-Z0-9_.%@\\]");
    ( "view_op_bad_return_type",
      rex "two branches don't end with the same stack type" );
    ("view_op_dupable_type", rex "Ticket in unauthorized position");
    ( "view_op_lazy_storage",
      rex "big_map or sapling_state type not expected here" );
  ]
  |> List.iter @@ fun (contract, error) ->
     Protocol.register_test
       ~__FILE__
       ~title:(sf "Typecheck view - %s" contract)
       ~tags:["client"; "michelson"]
       (test_typecheck ~contract ~error)
       protocols

let register protocols =
  test_regression protocols ;
  test_all_view_runs protocols ;
  test_create_contract protocols ;
  test_view_step_constant protocols ;
  test_self_after_view_suite protocols ;
  test_self_address_after_view_suite protocols ;
  test_sender_after_view_suite protocols ;
  test_balance_after_view_suite protocols ;
  test_amount_after_view_suite protocols ;
  test_recursive_view protocols ;
  test_typecheck_suite protocols
