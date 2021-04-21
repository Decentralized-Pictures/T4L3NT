(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs, <contact@nomadic-labs.com>               *)
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
    Component:    stdlib
    Invocation:   dune build @src/lib_stdlib/test/runtest_fallbackArray
    Subject:      Fallback arrays
 *)

open Alcotest
open FallbackArray

let for_some_idx s f = List.iter f [0; s - 1; s / 2; 1; s / 3; s - 2]

let samples =
  [ (0, "fallback", "foo");
    (100, "fallback", "bar");
    (1024 * 1024, "fallback", "baz") ]

let on_samples f () = List.iter f samples

let check_make_and_fallback (s, d, _) =
  assert (s < Sys.max_array_length) ;
  if not (fallback (make s d) = d) then fail "fallback (make s d) = d"

let check_fresh_accesses (s, d, _) =
  for_some_idx s
  @@ fun i ->
  let a = make s d in
  if not (get a i = d) then
    fail "initially, for all i >= 0 && i < s, get (make s d) i = d"

let check_get_set (s, d, v) =
  for_some_idx s
  @@ fun i ->
  let a = make s d in
  set a i v ;
  if not (i >= s || i < 0 || get a i = v) then
    fail "for all i in bounds, set a i v; get a i = v"

let check_cannot_override_fallback (s, d, v) =
  let a = make s d in
  set a s v ;
  if not (get a s = d) then fail "Fallback value cannot be changed"

let check_out_of_bounds (s, d, _) =
  let a = make s d in
  for i = 0 to s - 1 do
    set a i "tezos"
  done ;
  if not (get a (-1) = d) then fail "get a (-1) = d" ;
  if not (get a (s + 1) = d) then fail "get a (s + 1) = d"

let check_iter (s, _, _) =
  let a = make s 0 in
  for i = 0 to s - 1 do
    set a i 1
  done ;
  let r = ref 0 in
  iter a (fun x -> r := !r + x) ;
  if not (!r = s) then fail "iter a f should iterate over a."

let check_map (s, _, _) =
  let a = make s 0 in
  for i = 0 to s - 1 do
    set a i 1
  done ;
  let b = map a succ in
  let r = ref 0 in
  iter b (fun x -> r := !r + x) ;
  if not (!r = 2 * s) then fail "map a f should apply f over all a."

let check_fold (s, _, _) =
  let a = make s 0 in
  for i = 0 to s - 1 do
    set a i 1
  done ;
  let r' = fold a 0 ( + ) in
  let r = ref 0 in
  iter a (fun x -> r := !r + x) ;
  if not (!r = r') then
    fail
      "fold a init f should accumulate all applications of f over all \
       elements of a."

let tests =
  [ ("make_fallback", `Quick, on_samples check_make_and_fallback);
    ("fresh_accesses", `Quick, on_samples check_fresh_accesses);
    ("get_set", `Quick, on_samples check_get_set);
    ("out_of_bounds", `Quick, on_samples check_out_of_bounds);
    ("immutable_fallback", `Quick, on_samples check_cannot_override_fallback);
    ("iter", `Quick, on_samples check_iter);
    ("map", `Quick, on_samples check_map);
    ("fold", `Quick, on_samples check_fold) ]

let () = Alcotest.run "stdlib" [("FallbackArray", tests)]
