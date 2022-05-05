(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
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

(** Testing
    -------
    Component:    Protocol Library
    Invocation:   dune exec \
                  src/proto_alpha/lib_protocol/test/pbt/test_sc_rollup_tick_repr.exe
    Subject:      Operations in Tick_repr
*)

open Protocol.Alpha_context.Sc_rollup
open QCheck

(** A generator for ticks *)
let tick : Tick.t QCheck.arbitrary =
  QCheck.(
    Gen.(make (Option.value ~default:Tick.initial <$> map Tick.of_int nat)))

(** For all x, x = initial \/ x > initial. *)
let test_initial_is_bottom =
  QCheck.Test.make ~name:"x = initial \\/ x > initial" tick @@ fun x ->
  Tick.(x = initial || x > initial)

(** For all x, next x > x. *)
let test_next_is_monotonic =
  QCheck.Test.make ~name:"next x > x" tick @@ fun x -> Tick.(next x > x)

(** distance is indeed a distance. *)
let test_distance_identity_of_indiscernibles =
  QCheck.Test.make ~name:"distance is a distance (identity)" (pair tick tick)
  @@ fun (x, y) ->
  (Z.(equal (Tick.distance x y) zero) && Tick.(x = y))
  || Z.(not (equal (Tick.distance x y) zero))

let test_distance_symmetry =
  QCheck.Test.make ~name:"distance is a distance (symmetry)" (pair tick tick)
  @@ fun (x, y) -> Z.(equal (Tick.distance x y) (Tick.distance y x))

let test_distance_triangle_inequality =
  QCheck.Test.make
    ~name:"distance is a distance (triangle inequality)"
    (triple tick tick tick)
  @@ fun (x, y, z) ->
  Tick.(Z.(geq (distance x y + distance y z) (distance x z)))

(** [of_int x = Some t] iff [x >= 0] *)
let test_of_int =
  QCheck.Test.make ~name:"of_int only accepts natural numbers" int @@ fun x ->
  match Tick.of_int x with None -> x < 0 | Some _ -> x >= 0

(** [of_int (to_int x) = Some x]. *)
let test_of_int_to_int =
  QCheck.Test.make ~name:"to_int o of_int = identity" tick @@ fun x ->
  Tick.(
    match to_int x with
    | None -> (* by the tick generator definition. *) assert false
    | Some i -> ( match of_int i with Some y -> y = x | None -> false))

let tests =
  [
    test_next_is_monotonic;
    test_initial_is_bottom;
    test_distance_identity_of_indiscernibles;
    test_distance_symmetry;
    test_distance_triangle_inequality;
    test_of_int;
    test_of_int_to_int;
  ]

let () =
  Alcotest.run
    "Tick_repr"
    [("Tick_repr", Lib_test.Qcheck_helpers.qcheck_wrap tests)]
