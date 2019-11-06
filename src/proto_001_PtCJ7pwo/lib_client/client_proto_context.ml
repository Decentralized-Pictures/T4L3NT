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

open Protocol
open Alpha_context
open Client_proto_contracts
open Client_keys

let get_balance (rpc : #Alpha_client_context.rpc_context) ~chain ~block
    contract =
  Alpha_services.Contract.balance rpc (chain, block) contract

let get_storage (rpc : #Alpha_client_context.rpc_context) ~chain ~block
    contract =
  Alpha_services.Contract.storage_opt rpc (chain, block) contract

let get_script (rpc : #Alpha_client_context.rpc_context) ~chain ~block contract
    =
  Alpha_services.Contract.script_opt rpc (chain, block) contract

let list_contract_labels (cctxt : #Alpha_client_context.full) ~chain ~block =
  Alpha_services.Contract.list cctxt (chain, block)
  >>=? fun contracts ->
  map_s
    (fun h ->
      ( match Contract.is_implicit h with
      | Some m -> (
          Public_key_hash.rev_find cctxt m
          >>=? function
          | None ->
              return ""
          | Some nm -> (
              RawContractAlias.find_opt cctxt nm
              >>=? function
              | None ->
                  return (" (known as " ^ nm ^ ")")
              | Some _ ->
                  return (" (known as key:" ^ nm ^ ")") ) )
      | None -> (
          RawContractAlias.rev_find cctxt h
          >>=? function
          | None -> return "" | Some nm -> return (" (known as " ^ nm ^ ")") )
      )
      >>=? fun nm ->
      let kind =
        match Contract.is_implicit h with
        | Some _ ->
            " (implicit)"
        | None ->
            ""
      in
      let h_b58 = Contract.to_b58check h in
      return (nm, h_b58, kind))
    contracts

let message_added_contract (cctxt : #Alpha_client_context.full) name =
  cctxt#message "Contract memorized as %s." name

let get_manager (cctxt : #Alpha_client_context.full) ~chain ~block source =
  Client_proto_contracts.get_manager cctxt ~chain ~block source
  >>=? fun src_pkh ->
  Client_keys.get_key cctxt src_pkh
  >>=? fun (src_name, src_pk, src_sk) ->
  return (src_name, src_pkh, src_pk, src_sk)

let get_operation_from_block (cctxt : #Client_context.full) ~chain predecessors
    operation_hash =
  Client_confirmations.lookup_operation_in_previous_blocks
    cctxt
    ~chain
    ~predecessors
    operation_hash
  >>=? function
  | None ->
      return_none
  | Some (block, i, j) ->
      cctxt#message
        "Operation found in block: %a (pass: %d, offset: %d)"
        Block_hash.pp
        block
        i
        j
      >>= fun () ->
      Alpha_client_context.Alpha_block_services.Operations.operation
        cctxt
        ~chain
        ~block:(`Hash (block, 0))
        i
        j
      >>=? fun op' -> return_some op'
