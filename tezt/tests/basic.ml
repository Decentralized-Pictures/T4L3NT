(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(* This example is included in the documentation (docs/developers/tezt.rst).
   It is part of the tests to ensure we keep it up-to-date. *)

let check_node_initialization history_mode =
  Test.register
    ~__FILE__
    ~title:
      (sf "node initialization (%s mode)" (Node.show_history_mode history_mode))
    ~tags:["basic"; "node"; Node.show_history_mode history_mode]
  @@ fun () ->
  let* node = Node.init [History_mode history_mode] in
  let* client = Client.init ~node () in
  let* () = Client.activate_protocol client in
  Log.info "Activated protocol." ;
  let* () = repeat 10 (fun () -> Client.bake_for client) in
  Log.info "Baked 10 blocks." ;
  let* level = Node.wait_for_level node 11 in
  Log.info "Level is now %d." level ;
  let* identity = Node.wait_for_identity node in
  if identity = "" then Test.fail "identity is empty" ;
  Log.info "Identity is not empty." ;
  return ()

let register () =
  check_node_initialization Archive ;
  check_node_initialization Full ;
  check_node_initialization Rolling
