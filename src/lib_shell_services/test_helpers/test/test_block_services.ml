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

(** Testing
    -------
    Component:    Block services
    Invocation:   dune build @src/lib_shell_services/test_helpers/runtest_block_services
    Subject:      Fuzzing tests of equalities
*)

open Lib_test.Qcheck_helpers

open Tezos_shell_services_test_helpers.Shell_services_test_helpers

open Tezos_shell_services.Block_services

let raw_context_eq_tests =
  qcheck_eq_tests
    ~eq:raw_context_eq
    ~arb:raw_context_arb
    ~eq_name:"raw_context_eq"

let merkle_tree_eq_tests =
  qcheck_eq_tests
    ~eq:merkle_tree_eq
    ~arb:merkle_tree_arb
    ~eq_name:"merkle_tree_eq"

let () =
  Alcotest.run
    "Block_services"
    [
      ("raw_context_eq", qcheck_wrap raw_context_eq_tests);
      ("merkle_tree_eq", qcheck_wrap merkle_tree_eq_tests);
    ]
