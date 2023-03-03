(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
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

open Protocol

(* Conveniences to construct RPC directory
   against a subcontext of the Node_context *)

module type PARAM = sig
  include Sc_rollup_services.PREFIX

  type context

  val context_of_prefix : Node_context.rw -> prefix -> context tzresult Lwt.t
end

module Make_directory (S : PARAM) = struct
  open S

  let directory : context tzresult Tezos_rpc.Directory.t ref =
    ref Tezos_rpc.Directory.empty

  let register service f =
    directory := Tezos_rpc.Directory.register !directory service f

  let register0 service f =
    let open Lwt_result_syntax in
    register (Tezos_rpc.Service.subst0 service) @@ fun ctxt query input ->
    let*? ctxt = ctxt in
    f ctxt query input

  let register1 service f =
    let open Lwt_result_syntax in
    register (Tezos_rpc.Service.subst1 service)
    @@ fun (ctxt, arg) query input ->
    let*? ctxt = ctxt in
    f ctxt arg query input

  let build_directory node_ctxt =
    !directory
    |> Tezos_rpc.Directory.map (fun prefix ->
           context_of_prefix node_ctxt prefix)
    |> Tezos_rpc.Directory.prefix prefix
end

module Block_directory_helpers = struct
  let get_head store =
    let open Lwt_result_syntax in
    let* head = Node_context.last_processed_head_opt store in
    match head with
    | None -> failwith "No head"
    | Some {header = {block_hash; _}; _} -> return block_hash

  let get_finalized node_ctxt =
    let open Lwt_result_syntax in
    let* head = Node_context.get_finalized_head_opt node_ctxt in
    match head with
    | None -> failwith "No finalized head"
    | Some {header = {block_hash; _}; _} -> return block_hash

  let get_last_cemented (node_ctxt : _ Node_context.t) =
    let open Lwt_result_syntax in
    protect @@ fun () ->
    let* lcc_hash =
      Node_context.hash_of_level
        node_ctxt
        (Alpha_context.Raw_level.to_int32 node_ctxt.lcc.level)
    in
    return lcc_hash

  let block_of_prefix node_ctxt block =
    match block with
    | `Head -> get_head node_ctxt
    | `Hash b -> return b
    | `Level l -> Node_context.hash_of_level node_ctxt l
    | `Finalized -> get_finalized node_ctxt
    | `Cemented -> get_last_cemented node_ctxt
end
