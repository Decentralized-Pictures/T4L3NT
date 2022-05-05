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

open Error_monad

type t = {active_sinks : Uri.t list}

let default =
  {active_sinks = [Uri.make ~scheme:Internal_event.Lwt_log_sink.uri_scheme ()]}

let encoding =
  let open Data_encoding in
  let object_1 key_name =
    obj1
      (dft
         key_name
         ~description:"List of URIs to activate/configure sinks."
         (list string)
         [])
  in
  union
    [
      case
        ~title:"Active-Sinks"
        ~description:"List of sinks to make sure are activated."
        (Tag 0)
        (object_1 "active_sinks")
        (fun {active_sinks} -> Some (List.map Uri.to_string active_sinks))
        (fun active_sinks ->
          {active_sinks = List.map Uri.of_string active_sinks});
      case
        ~title:"Active-Sinks-Deprecated"
        ~description:
          "List of sinks to make sure are activated, deprecated \
           backwards-compatibility encoding."
        (Tag 1)
        (object_1 "activate")
        (fun {active_sinks = _} -> None)
        (* (fun {active_sinks} -> Some (List.map Uri.to_string active_sinks)) *)
          (fun active_sinks ->
          {active_sinks = List.map Uri.of_string active_sinks});
    ]

let apply {active_sinks} =
  List.iter_es Internal_event.All_sinks.activate active_sinks

let reapply config =
  let open Lwt_result_syntax in
  let except u = Uri.scheme u = Some "lwt-log" in
  let* () = Internal_event.All_sinks.close ~except () in
  apply config
