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

type t

type config = {
  genesis : Genesis.t;
  chain_name : Distributed_db_version.Name.t;
  sandboxed_chain_name : Distributed_db_version.Name.t;
  user_activated_upgrades : User_activated.upgrades;
  user_activated_protocol_overrides : User_activated.protocol_overrides;
  data_dir : string;
  store_root : string;
  context_root : string;
  protocol_root : string;
  patch_context : (Context.t -> Context.t tzresult Lwt.t) option;
  p2p : (P2p.config * P2p.limits) option;
  checkpoint : Block_header.t option;
  disable_mempool : bool;
      (** If [true], all non-empty mempools will be ignored. *)
  enable_testchain : bool;
      (** If [false], testchain related messages will be ignored. *)
}

val default_peer_validator_limits : Peer_validator.limits

val default_prevalidator_limits : Prevalidator.limits

val default_block_validator_limits : Block_validator.limits

val default_chain_validator_limits : Chain_validator.limits

val create :
  ?sandboxed:bool ->
  ?sandbox_parameters:Data_encoding.json ->
  singleprocess:bool ->
  config ->
  Peer_validator.limits ->
  Block_validator.limits ->
  Prevalidator.limits ->
  Chain_validator.limits ->
  History_mode.t option ->
  t tzresult Lwt.t

val shutdown : t -> unit Lwt.t

val build_rpc_directory : t -> unit RPC_directory.t
