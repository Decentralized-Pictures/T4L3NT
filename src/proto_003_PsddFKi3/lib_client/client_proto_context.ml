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
open Alpha_client_context
open Client_proto_contracts
open Client_keys

let get_balance (rpc : #Alpha_client_context.rpc_context) ~chain ~block
    contract =
  Alpha_services.Contract.balance rpc (chain, block) contract

let get_storage (rpc : #Alpha_client_context.rpc_context) ~chain ~block
    contract =
  Alpha_services.Contract.storage_opt rpc (chain, block) contract

let get_big_map_value (rpc : #Alpha_client_context.rpc_context) ~chain ~block
    contract key =
  Alpha_services.Contract.big_map_get_opt rpc (chain, block) contract key

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

let get_manager (cctxt : #Alpha_client_context.full) ~chain ~block source =
  Client_proto_contracts.get_manager cctxt ~chain ~block source
  >>=? fun src_pkh ->
  Client_keys.get_key cctxt src_pkh
  >>=? fun (src_name, src_pk, src_sk) ->
  return (src_name, src_pkh, src_pk, src_sk)

type period_info = {
  current_period_kind : Voting_period.kind;
  position : Int32.t;
  remaining : Int32.t;
  current_proposal : Protocol_hash.t option;
}

type ballots_info = {
  current_quorum : Int32.t;
  participation : Int32.t;
  supermajority : Int32.t;
  ballots : Vote.ballots;
}

let get_ballots_info (cctxt : #Alpha_client_context.full) ~chain ~block =
  (* Get the next level, not the current *)
  let cb = (chain, block) in
  Alpha_services.Voting.ballots cctxt cb
  >>=? fun ballots ->
  Alpha_services.Voting.current_quorum cctxt cb
  >>=? fun current_quorum ->
  Alpha_services.Voting.listings cctxt cb
  >>=? fun listings ->
  let max_participation =
    List.fold_left (fun acc (_, w) -> Int32.add w acc) 0l listings
  in
  let all_votes = Int32.(add (add ballots.yay ballots.nay) ballots.pass) in
  let participation = Int32.(div (mul all_votes 100_00l) max_participation) in
  let supermajority = Int32.(div (mul 8l (add ballots.yay ballots.nay)) 10l) in
  return {current_quorum; participation; supermajority; ballots}

let get_period_info (cctxt : #Alpha_client_context.full) ~chain ~block =
  (* Get the next level, not the current *)
  let cb = (chain, block) in
  Alpha_services.Helpers.current_level cctxt ~offset:1l cb
  >>=? fun level ->
  Alpha_services.Constants.all cctxt cb
  >>=? fun constants ->
  Alpha_services.Voting.current_proposal cctxt cb
  >>=? fun current_proposal ->
  let position = level.voting_period_position in
  let remaining =
    Int32.(sub constants.parametric.blocks_per_voting_period position)
  in
  Alpha_services.Voting.current_period_kind cctxt cb
  >>=? fun current_period_kind ->
  return {current_period_kind; position; remaining; current_proposal}

let get_proposals (cctxt : #Alpha_client_context.full) ~chain ~block =
  let cb = (chain, block) in
  Alpha_services.Voting.proposals cctxt cb

let pp_operation formatter (a : Alpha_block_services.operation) =
  match (a.receipt, a.protocol_data) with
  | (Some (Apply_results.Operation_metadata omd), Operation_data od) -> (
    match Apply_results.kind_equal_list od.contents omd.contents with
    | Some Apply_results.Eq ->
        Operation_result.pp_operation_result
          formatter
          (od.contents, omd.contents)
    | None ->
        Stdlib.failwith "Unexpected result." )
  | (None, _) ->
      Stdlib.failwith
        "Pruned metadata: the operation receipt was removed accordingly to \
         the node's history mode."
  | _ ->
      Stdlib.failwith "Unexpected result."

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

let display_receipt_for_operation (cctxt : #Alpha_client_context.full) ~chain
    ?(predecessors = 10) operation_hash =
  get_operation_from_block cctxt ~chain predecessors operation_hash
  >>=? function
  | None ->
      failwith "Couldn't find operation"
  | Some op ->
      cctxt#message "%a" pp_operation op >>= fun () -> return_unit
