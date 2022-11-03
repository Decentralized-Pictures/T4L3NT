(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

module Assert = Lib_test.Assert

let () =
  let speed =
    try
      let s = Sys.getenv "SLOW_TEST" in
      match String.(trim (uncapitalize_ascii s)) with
      | "true" | "1" | "yes" -> `Slow
      | _ -> `Quick
    with Not_found -> `Quick
  in
  let open Lwt_syntax in
  Lwt_main.run
    (let* () = Tezos_base_unix.Internal_event_unix.init () in
     Alcotest_lwt.run
       "tezos-store"
       [
         Test_cemented_store.tests;
         Test_block_store.tests;
         Test_store.tests;
         Test_consistency.tests;
         Test_protocol_store.tests;
         Test_testchain.tests;
         Test_snapshots.tests speed;
         Test_reconstruct.tests speed;
         Test_history_mode_switch.tests speed;
       ])
