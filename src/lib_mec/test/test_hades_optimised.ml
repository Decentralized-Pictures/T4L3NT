(*****************************************************************************)
(*                                                                           *)
(* Copyright (c) 2021 Danny Willems <be.danny.willems@gmail.com>             *)
(* Copyright (c) 2023 Nomadic Labs, <contact@nomadic-labs.com>               *)
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
    Component:    lib_mec
    Invocation:   dune exec src/lib_mec/test/main.exe \
                  -- --file test_hades_optimised.ml
    Subject:      Test lib mec
*)

let rec repeat n f () =
  if n > 0 then (
    f () ;
    repeat (n - 1) f ())

module BaseParameters = struct
  let width = 3

  let full_rounds = 8

  let partial_rounds = 56

  let round_constants = Ark_poseidon128.v

  let partial_round_idx_to_permute = 2

  let linear_transformation = Mds_poseidon128.v

  (* This is the first alpha such that pgc(alpha, p - 1) = 1 *)
  let alpha = Z.of_string "5"
end

module Scalar = Ff.MakeFp (struct
  let prime_order =
    Z.of_string
      "52435875175126190479447740508185965837690552500527637822603658699938581184513"
end)

let test_consistency_between_optimised_and_naive_with_a_fixed_batch_size () =
  let module Parameters : Mec.Permutation.HadesLinearOptimisation.PARAMETERS =
  struct
    include BaseParameters

    let batch_size = 4
  end in
  let module PermutationOptimised =
    Mec.Permutation.HadesLinearOptimisation.Make (Parameters) (Scalar)
  in
  let module PermutationNaive = Mec.Permutation.Hades.Make (Parameters) (Scalar)
  in
  let state = Array.init Parameters.width (fun _ -> Scalar.random ()) in
  let ctxt_naive = PermutationNaive.init state in
  let ctxt_optimised = PermutationOptimised.init state in
  PermutationNaive.apply ctxt_naive ;
  PermutationOptimised.apply ctxt_optimised ;
  let res_naive = PermutationNaive.get ctxt_naive in
  let res_optimised = PermutationOptimised.get ctxt_optimised in
  assert (Array.for_all2 Scalar.eq res_naive res_optimised)

let test_consistency_between_optimised_and_naive_with_a_random_batch_size () =
  let module Parameters : Mec.Permutation.HadesLinearOptimisation.PARAMETERS =
  struct
    include BaseParameters

    let batch_size = 1 + Random.int partial_rounds
  end in
  let module PermutationOptimised =
    Mec.Permutation.HadesLinearOptimisation.Make (Parameters) (Scalar)
  in
  let module PermutationNaive = Mec.Permutation.Hades.Make (Parameters) (Scalar)
  in
  let state = Array.init Parameters.width (fun _ -> Scalar.random ()) in
  let ctxt_naive = PermutationNaive.init state in
  let ctxt_optimised = PermutationOptimised.init state in
  PermutationNaive.apply ctxt_naive ;
  PermutationOptimised.apply ctxt_optimised ;
  let res_naive = PermutationNaive.get ctxt_naive in
  let res_optimised = PermutationOptimised.get ctxt_optimised in
  assert (Array.for_all2 Scalar.eq res_naive res_optimised)

let () =
  let open Alcotest in
  run
    "HADES Strategy Optimised with linear trick"
    [
      ( "Test consistency between naive and optimised implementation",
        [
          Alcotest.test_case
            "On random values with a fixed batch size"
            `Quick
            (repeat
               100
               test_consistency_between_optimised_and_naive_with_a_fixed_batch_size);
          Alcotest.test_case
            "On random values with a random batch size"
            `Quick
            (repeat
               100
               test_consistency_between_optimised_and_naive_with_a_random_batch_size);
        ] );
    ]
