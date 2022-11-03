(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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
    Component:  Protocol (saturated arithmetic)
    Invocation: dune exec src/proto_alpha/lib_protocol/test/unit/main.exe \
                -- test "^\[Unit\] sc rollup arith$"
    Subject:    Basic testing of the arithmetic rollup example
*)

open Protocol
module Context_binary = Tezos_context_memory.Context_binary

(* We first instantiate an arithmetic PVM capable of generating proofs. *)
module Tree :
  Environment.Context.TREE
    with type t = Context_binary.t
     and type tree = Context_binary.tree
     and type key = string list
     and type value = bytes = struct
  type t = Context_binary.t

  type tree = Context_binary.tree

  type key = Context_binary.key

  type value = Context_binary.value

  include Context_binary.Tree
end

module Arith_Context = struct
  module Tree = Tree

  type tree = Tree.tree

  let hash_tree tree =
    Sc_rollup_repr.State_hash.context_hash_to_state_hash (Tree.hash tree)

  type proof = Context_binary.Proof.tree Context_binary.Proof.t

  let proof_encoding =
    Tezos_context_merkle_proof_encoding.Merkle_proof_encoding.V2.Tree2
    .tree_proof_encoding

  let kinded_hash_to_state_hash = function
    | `Value hash | `Node hash ->
        Sc_rollup_repr.State_hash.context_hash_to_state_hash hash

  let proof_before proof =
    kinded_hash_to_state_hash proof.Context_binary.Proof.before

  let proof_after proof =
    kinded_hash_to_state_hash proof.Context_binary.Proof.after

  let produce_proof context tree step =
    let open Lwt_syntax in
    (* FIXME: With on-disk context, we cannot commit the empty
       context. Is it also true in our case? *)
    let* context = Context_binary.add_tree context [] tree in
    let* _hash = Context_binary.commit ~time:Time.Protocol.epoch context in
    let index = Context_binary.index context in
    match Context_binary.Tree.kinded_key tree with
    | Some k ->
        let* p = Context_binary.produce_tree_proof index k step in
        return (Some p)
    | None -> return None

  let verify_proof proof step =
    let open Lwt_syntax in
    let* result = Context_binary.verify_tree_proof proof step in
    match result with
    | Ok v -> return (Some v)
    | Error _ ->
        (* We skip the error analysis here since proof verification is not a
           job for the rollup node. *)
        return None
end

module FullArithPVM = Sc_rollup_arith.Make (Arith_Context)
open FullArithPVM

let setup boot_sector f =
  let open Lwt_syntax in
  let* index = Context_binary.init "/tmp" in
  let ctxt = Context_binary.empty index in
  let* state = initial_state ctxt in
  let* state = install_boot_sector state boot_sector in
  f ctxt state

let pre_boot boot_sector f =
  parse_boot_sector boot_sector |> function
  | None -> failwith "Invalid boot sector"
  | Some boot_sector -> setup boot_sector @@ f

let test_preboot () =
  [""; "1"; "1 2 +"]
  |> List.iter_es (fun boot_sector ->
         pre_boot boot_sector @@ fun _ctxt _state -> return ())

let boot boot_sector f =
  pre_boot boot_sector @@ fun ctxt state -> eval state >>= f ctxt

let test_boot () =
  let open Sc_rollup_PVM_sig in
  boot "" @@ fun _ctxt state ->
  is_input_state state >>= function
  | Initial -> return ()
  | Needs_reveal _ | First_after _ ->
      failwith
        "After booting, the machine should be waiting for the initial input."
  | No_input_required ->
      failwith "After booting, the machine must be waiting for input."

let test_input_message () =
  let open Sc_rollup_PVM_sig in
  boot "" @@ fun _ctxt state ->
  let input = Sc_rollup_helpers.make_input_repr "MESSAGE" in
  set_input input state >>= fun state ->
  eval state >>= fun state ->
  is_input_state state >>= function
  | Initial | Needs_reveal _ | First_after _ ->
      failwith
        "After receiving a message, the rollup must not be waiting for input."
  | No_input_required -> return ()

let go ~max_steps target_status state =
  let rec aux i state =
    pp state >>= fun pp ->
    Format.eprintf "%a" pp () ;
    if i > max_steps then
      failwith "Maximum number of steps reached before target status."
    else
      get_status state >>= fun current_status ->
      if target_status = current_status then return state
      else eval state >>= aux (i + 1)
  in
  aux 0 state

let test_parsing_message ~valid (source, expected_code) =
  boot "" @@ fun _ctxt state ->
  let input = Sc_rollup_helpers.make_input_repr source in
  set_input input state >>= fun state ->
  eval state >>= fun state ->
  go ~max_steps:10000 Evaluating state >>=? fun state ->
  get_parsing_result state >>= fun result ->
  Assert.equal
    ~loc:__LOC__
    (Option.equal Bool.equal)
    "Unexpected parsing result"
    (fun fmt r ->
      Format.fprintf
        fmt
        (match r with
        | None -> "No parsing running"
        | Some true -> "Syntax correct"
        | Some false -> "Syntax error"))
    (Some valid)
    result
  >>=? fun () ->
  if valid then
    get_code state >>= fun code ->
    Assert.equal
      ~loc:__LOC__
      (List.equal equal_instruction)
      "The parsed code is not what we expected: "
      (Format.pp_print_list pp_instruction)
      expected_code
      code
  else return ()

let syntactically_valid_messages =
  List.map
    (fun nums ->
      ( String.concat " " (List.map string_of_int nums),
        List.map (fun x -> IPush x) nums ))
    [[0]; [42]; [373]; [0; 1]; [0; 123; 42; 73; 34; 13; 31]]
  @ [
      ("1 2 +", [IPush 1; IPush 2; IAdd]);
      ( "1 2 3 +    + 3 +",
        [IPush 1; IPush 2; IPush 3; IAdd; IAdd; IPush 3; IAdd] );
      ("1 2+", [IPush 1; IPush 2; IAdd]);
      ("1 2 3++3+", [IPush 1; IPush 2; IPush 3; IAdd; IAdd; IPush 3; IAdd]);
      ("", []);
      ("1 a", [IPush 1; IStore "a"]);
    ]

let syntactically_invalid_messages =
  List.map
    (fun s -> (s, []))
    ["@"; "  @"; "  @  "; "---"; "12 +++ --"; "1a"; "a_"]

let test_parsing_messages () =
  List.iter_es (test_parsing_message ~valid:true) syntactically_valid_messages
  >>=? fun () ->
  List.iter_es
    (test_parsing_message ~valid:false)
    syntactically_invalid_messages

let test_evaluation_message ~valid
    (boot_sector, source, expected_stack, expected_vars) =
  boot boot_sector @@ fun _ctxt state ->
  let input = Sc_rollup_helpers.make_input_repr source in
  set_input input state >>= fun state ->
  eval state >>= fun state ->
  go ~max_steps:10000 Waiting_for_input_message state >>=? fun state ->
  if valid then
    get_stack state >>= fun stack ->
    Assert.equal
      ~loc:__LOC__
      (List.equal Compare.Int.equal)
      "The stack is not what we expected: "
      Format.(pp_print_list (fun fmt -> fprintf fmt "%d;@;"))
      expected_stack
      stack
    >>=? fun () ->
    List.iter_es
      (fun (x, v) ->
        get_var state x >>= function
        | None -> failwith "The variable %s cannot be found." x
        | Some v' ->
            Assert.equal
              ~loc:__LOC__
              Compare.Int.equal
              (Printf.sprintf "The variable %s has not the right value: " x)
              (fun fmt x -> Format.fprintf fmt "%d" x)
              v
              v')
      expected_vars
  else
    get_evaluation_result state >>= function
    | Some true -> failwith "This code should lead to an evaluation error."
    | None -> failwith "We should have reached the evaluation end."
    | Some false -> return ()

let valid_messages =
  [
    ("", "0", [0], []);
    ("", "1 2", [2; 1], []);
    ("", "1 2 +", [3], []);
    ("", "1 2 + 3 +", [6], []);
    ("", "1 2 + 3 + 1 1 + +", [8], []);
    ("0 ", "", [0], []);
    ("1 ", "2", [2; 1], []);
    ("1 2 ", "+", [3], []);
    ("1 2 + ", "3 +", [6], []);
    ("1 2 + ", "3 + 1 1 + +", [8], []);
    ("", "1 a", [1], [("a", 1)]);
    ("", "1 a 2 + b 3 +", [6], [("a", 1); ("b", 3)]);
    ("", "1 a 2 + b 3 + result", [6], [("a", 1); ("b", 3); ("result", 6)]);
    ("1 a ", "2 b", [2; 1], [("a", 1); ("b", 2)]);
    ("1 a ", "2 a", [2; 1], [("a", 2)]);
    ("", "1 a 2 a + a", [3], [("a", 3)]);
    ("", "1 a b", [1], [("a", 1); ("b", 1)]);
    ("1 a", "", [1], [("a", 1)]);
  ]

let invalid_messages =
  List.map
    (fun s -> ("", s, [], []))
    ["+"; "1 +"; "1 1 + +"; "1 1 + 1 1 + + +"; "a"]

let test_evaluation_messages () =
  List.iter_es (test_evaluation_message ~valid:true) valid_messages
  >>=? fun () ->
  List.iter_es (test_evaluation_message ~valid:false) invalid_messages

let test_output_messages_proofs ~valid ~inbox_level (source, expected_outputs) =
  let open Lwt_result_syntax in
  boot "" @@ fun ctxt state ->
  let input =
    Sc_rollup_helpers.make_input_repr
      ~inbox_level:(Raw_level_repr.of_int32_exn (Int32.of_int inbox_level))
      source
  in
  let*! state = set_input input state in
  let*! state = eval state in
  let* state = go ~max_steps:10000 Waiting_for_input_message state in
  let check_output output =
    let*! result = produce_output_proof ctxt state output in
    if valid then
      match result with
      | Ok proof ->
          let*! valid = verify_output_proof proof in
          fail_unless valid (Exn (Failure "An output proof is not valid."))
      | Error _ -> failwith "Error during proof generation"
    else
      match result with
      | Ok proof ->
          let*! proof_is_valid = verify_output_proof proof in
          fail_when
            proof_is_valid
            (Exn
               (Failure
                  (Format.asprintf
                     "A wrong output proof is valid: %s -> %a"
                     source
                     Sc_rollup_PVM_sig.pp_output
                     output)))
      | Error _ -> return ()
  in
  List.iter_es check_output expected_outputs

let make_output ~outbox_level ~message_index n =
  let open Sc_rollup_outbox_message_repr in
  let unparsed_parameters =
    Micheline.(Int (dummy_location, Z.of_int n) |> strip_locations)
  in
  let destination = Contract_hash.zero in
  let entrypoint = Entrypoint_repr.default in
  let transaction = {unparsed_parameters; destination; entrypoint} in
  let transactions = [transaction] in
  let message_index = Z.of_int message_index in
  let outbox_level = Raw_level_repr.of_int32_exn (Int32.of_int outbox_level) in
  let message = Atomic_transaction_batch {transactions} in
  Sc_rollup_PVM_sig.{outbox_level; message_index; message}

let test_valid_output_messages () =
  let test inbox_level =
    let outbox_level = inbox_level in
    [
      ("1", []);
      ("1 out", [make_output ~outbox_level ~message_index:0 1]);
      ( "1 out 2 out",
        [
          make_output ~outbox_level ~message_index:0 1;
          make_output ~outbox_level ~message_index:1 2;
        ] );
      ( "1 out 1 1 + out",
        [
          make_output ~outbox_level ~message_index:0 1;
          make_output ~outbox_level ~message_index:1 2;
        ] );
      ( "1 out 1 1 + out out",
        [
          make_output ~outbox_level ~message_index:0 1;
          make_output ~outbox_level ~message_index:1 2;
          make_output ~outbox_level ~message_index:2 2;
        ] );
    ]
    |> List.iter_es (test_output_messages_proofs ~valid:true ~inbox_level)
  in
  (* Test for different inbox/outbox levels. *)
  List.iter_es test [0; 1; 2345]

let test_invalid_output_messages () =
  let inbox_level = 0 in
  let outbox_level = inbox_level in
  [
    ("1", [make_output ~outbox_level ~message_index:0 1]);
    ("1 out", [make_output ~outbox_level ~message_index:1 1]);
    ( "1 out 1 1 + out",
      [
        make_output ~outbox_level ~message_index:0 0;
        make_output ~outbox_level ~message_index:3 2;
      ] );
    ( "1 out 1 1 + out out",
      [
        make_output ~outbox_level ~message_index:0 42;
        make_output ~outbox_level ~message_index:1 32;
        make_output ~outbox_level ~message_index:2 13;
      ] );
  ]
  |> List.iter_es (test_output_messages_proofs ~valid:false ~inbox_level)

let test_invalid_outbox_level () =
  let inbox_level = 42 in
  let outbox_level = inbox_level - 1 in
  [
    ("1", []);
    ("1 out", [make_output ~outbox_level ~message_index:0 1]);
    ( "1 out 2 out",
      [
        make_output ~outbox_level ~message_index:0 1;
        make_output ~outbox_level ~message_index:1 2;
      ] );
  ]
  |> List.iter_es (test_output_messages_proofs ~valid:false ~inbox_level)

let test_initial_state_hash_arith_pvm () =
  let open Alpha_context in
  let open Lwt_result_syntax in
  let context = Tezos_context_memory.make_empty_context () in
  let*! state = Sc_rollup_helpers.Arith_pvm.initial_state context in
  let*! hash = Sc_rollup_helpers.Arith_pvm.state_hash state in
  let expected = Sc_rollup.ArithPVM.reference_initial_state_hash in
  if Sc_rollup.State_hash.(hash = expected) then return_unit
  else
    failwith
      "incorrect hash, expected %a, got %a"
      Sc_rollup.State_hash.pp
      expected
      Sc_rollup.State_hash.pp
      hash

let tests =
  [
    Tztest.tztest "PreBoot" `Quick test_preboot;
    Tztest.tztest "Boot" `Quick test_boot;
    Tztest.tztest "Input message" `Quick test_input_message;
    Tztest.tztest "Parsing message" `Quick test_parsing_messages;
    Tztest.tztest "Evaluating message" `Quick test_evaluation_messages;
    Tztest.tztest "Valid output messages" `Quick test_valid_output_messages;
    Tztest.tztest "Invalid output messages" `Quick test_invalid_output_messages;
    Tztest.tztest "Invalid outbox level" `Quick test_invalid_outbox_level;
    Tztest.tztest
      "Initial state hash for Arith"
      `Quick
      test_initial_state_hash_arith_pvm;
  ]
