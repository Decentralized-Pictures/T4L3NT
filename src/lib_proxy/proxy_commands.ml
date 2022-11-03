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

open Tezos_clic

let group : Clic.group =
  {
    Clic.name = "proxy";
    title = "Commands querying proxy and light mode support";
  }

let list_proxy_command_handler _ _ =
  List.iter (fun (module Proxy : Registration.Proxy_sig) ->
      Format.printf "%a@." Protocol_hash.pp Proxy.protocol_hash)
  @@ Registration.get_all_registered () ;
  Lwt_result_syntax.return_unit

let list_env_command (flag : string) : _ Clic.command =
  let open Clic in
  command
    ~group
    ~desc:(Printf.sprintf "List protocols supported by %s mode" flag)
    no_options
    (prefixes ["list"; flag; "protocols"] @@ stop)
    list_proxy_command_handler

let commands () = List.map list_env_command ["proxy"; "light"]
