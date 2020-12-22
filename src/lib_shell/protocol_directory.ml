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

let build_rpc_directory block_validator state =
  let dir : unit RPC_directory.t ref = ref RPC_directory.empty in
  let gen_register0 s f =
    dir := RPC_directory.gen_register !dir s (fun () p q -> f p q)
  in
  let register1 s f =
    dir := RPC_directory.register !dir s (fun ((), a) p q -> f a p q)
  in
  gen_register0 Protocol_services.S.list (fun () () ->
      State.Protocol.list state
      >>= fun set ->
      let protocols =
        Protocol_hash.Set.add_seq (Registered_protocol.seq_embedded ()) set
      in
      RPC_answer.return (Protocol_hash.Set.elements protocols)) ;
  register1 Protocol_services.S.contents (fun hash () () ->
      match Registered_protocol.get_embedded_sources hash with
      | Some p ->
          return p
      | None ->
          State.Protocol.read state hash) ;
  register1 Protocol_services.S.environment (fun hash () () ->
      match Registered_protocol.get_embedded_sources hash with
      | Some p ->
          return p.expected_env
      | None ->
          State.Protocol.read state hash >>=? fun p -> return p.expected_env) ;
  register1 Protocol_services.S.fetch (fun hash () () ->
      Block_validator.fetch_and_compile_protocol block_validator hash
      >>=? fun _proto -> return_unit) ;
  !dir
