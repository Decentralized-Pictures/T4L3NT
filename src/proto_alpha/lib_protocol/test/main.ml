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
    Component:    Protocol
    Invocation:   dune build @src/proto_alpha/lib_protocol/runtest
    Subject:      Entrypoint
*)

let () =
  Alcotest_lwt.run
    "protocol_alpha"
    [ ("transfer", Test_transfer.tests);
      ("origination", Test_origination.tests);
      ("activation", Test_activation.tests);
      ("revelation", Test_reveal.tests);
      ("endorsement", Test_endorsement.tests);
      ("double endorsement", Test_double_endorsement.tests);
      ("double baking", Test_double_baking.tests);
      ("seed", Test_seed.tests);
      ("baking", Test_baking.tests);
      ("delegation", Test_delegation.tests);
      ("rolls", Test_rolls.tests);
      ("combined", Test_combined_operations.tests);
      ("qty", Test_qty.tests);
      ("voting", Test_voting.tests);
      ("interpretation", Test_interpretation.tests);
      ("typechecking", Test_typechecking.tests);
      ("gas properties", Test_gas_properties.tests);
      ("fixed point computation", Test_fixed_point.tests);
      ("gas levels", Test_gas_levels.tests);
      ("saturation arithmetic", Test_saturation.tests);
      ("gas cost functions", Test_gas_costs.tests);
      ("lazy storage diff", Test_lazy_storage_diff.tests);
      ("sapling", Test_sapling.tests);
      ("helpers rpcs", Test_helpers_rpcs.tests);
      ("script deserialize gas", Test_script_gas.tests);
      ("failing_noop operation", Test_failing_noop.tests);
      ("storage description", Test_storage.tests) ]
  |> Lwt_main.run
