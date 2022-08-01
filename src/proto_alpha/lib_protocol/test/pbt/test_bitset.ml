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
    Component:    Protocol Library
    Invocation:   dune exec src/proto_alpha/lib_protocol/test/pbt/test_bitset.exe
    Subject:      Bitset structure
*)

open Lib_test.Qcheck2_helpers
open Protocol.Bitset

let gen_ofs = QCheck2.Gen.int_bound (64 * 10)

let gen_storage =
  let open QCheck2.Gen in
  let* bool_vector = list bool in
  match
    List.fold_left_i_e
      (fun i storage v -> if v then add storage i else ok storage)
      empty
      bool_vector
  with
  | Ok v -> return v
  | Error e ->
      Alcotest.failf
        "An unxpected error %a occurred when generating Bitset.t"
        Environment.Error_monad.pp_trace
        e

let test_get_set (c, ofs) =
  List.for_all
    (fun ofs' ->
      let res =
        let open Result_syntax in
        let* c' = add c ofs in
        let* v = mem c ofs' in
        let* v' = mem c' ofs' in
        return (if ofs = ofs' then v' = true else v = v')
      in
      match res with
      | Error e ->
          Alcotest.failf
            "Unexpected error: %a"
            Environment.Error_monad.pp_trace
            e
      | Ok res -> res)
    (0 -- 63)

let () =
  Alcotest.run
    "bits"
    [
      ( "quantity",
        qcheck_wrap
          [
            QCheck2.Test.make
              ~count:10000
              ~name:"get set"
              QCheck2.Gen.(pair gen_storage gen_ofs)
              test_get_set;
          ] );
    ]
