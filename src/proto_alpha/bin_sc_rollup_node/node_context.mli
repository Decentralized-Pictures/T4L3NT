(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

(** This module describes the execution context of the node. *)

open Protocol
open Alpha_context

type t = {
  cctxt : Protocol_client_context.full;
      (** Client context used by the rollup node. *)
  dal_cctxt : Dal_node_client.cctxt;
      (** Client context to query the dal node. *)
  data_dir : string;  (** Node data dir. *)
  l1_ctxt : Layer1.t;
      (** Layer 1 context to fetch blocks and monitor heads, etc.*)
  rollup_address : Sc_rollup.t;
      (** Smart contract rollup tracked by the rollup node. *)
  operators : Configuration.operators;
      (** Addresses of the rollup node operators by purposes. *)
  genesis_info : Sc_rollup.Commitment.genesis_info;
      (** Origination information of the smart contract rollup. *)
  block_finality_time : int;
      (** Deterministic block finality time for the layer 1 protocol. *)
  kind : Sc_rollup.Kind.t;  (** Kind of the smart contract rollup. *)
  fee_parameters : Configuration.fee_parameters;
      (** Fee parameters to use when injecting operations in layer 1. *)
  protocol_constants : Constants.t;
      (** Protocol constants retrieved from the Tezos node. *)
  loser_mode : Loser_mode.t;
      (** If different from [Loser_mode.no_failures], the rollup node
          issues wrong commitments (for tests). *)
  store : Store.t;  (** The store for the persistent storage. *)
  context : Context.index;  (** The persistent context for the rollup node. *)
}

(** [get_operator cctxt purpose] returns the public key hash for the operator
    who has purpose [purpose], if any.
*)
val get_operator :
  t -> Configuration.purpose -> Signature.Public_key_hash.t option

(** [is_operator cctxt pkh] returns [true] if the public key hash [pkh] is an
    operator for the node (for any purpose). *)
val is_operator : t -> Signature.Public_key_hash.t -> bool

(** [get_fee_parameter cctxt purpose] returns the fee parameter to inject an
    operation for a given [purpose]. If no specific fee parameters were
    configured for this purpose, returns the default fee parameter for this
    purpose.
*)
val get_fee_parameter : t -> Configuration.purpose -> Injection.fee_parameter

(** [init cctxt dal_cctxt ~data_dir l1_ctxt sc_rollup genesis_info kind operators fees
    ~loser_mode store context] initialises the rollup representation. The rollup
    origination level and kind are fetched via an RPC call to the layer1 node
    that [cctxt] uses for RPC requests.
*)
val init :
  Protocol_client_context.full ->
  Dal_node_client.cctxt ->
  data_dir:string ->
  Layer1.t ->
  Sc_rollup.t ->
  Protocol.Alpha_context.Sc_rollup.Kind.t ->
  Configuration.operators ->
  Configuration.fee_parameters ->
  loser_mode:Loser_mode.t ->
  Store.t ->
  Context.index ->
  t tzresult Lwt.t

(** [checkout_context node_ctxt block_hash] returns the context at block
    [block_hash]. *)
val checkout_context : t -> Block_hash.t -> Context.t tzresult Lwt.t
