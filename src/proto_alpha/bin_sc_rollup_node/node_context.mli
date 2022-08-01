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
  l1_ctxt : Layer1.t;
      (** Layer 1 context to fetch blocks and monitor heads, etc.*)
  rollup_address : Sc_rollup.t;
      (** Smart contract rollup tracked by the rollup node. *)
  operator : Signature.Public_key_hash.t;
      (** Address of the rollup node operator. *)
  genesis_info : Sc_rollup.Commitment.genesis_info;
      (** Origination information of the smart contract rollup. *)
  block_finality_time : int;
      (** Deterministic block finality time for the layer 1 protocol. *)
  kind : Sc_rollup.Kind.t;  (** Kind of the smart contract rollup. *)
  fee_parameter : Injection.fee_parameter;
      (** Fee parameter to use when injecting operations in layer 1. *)
  protocol_constants : Constants.t;
      (** Protocol constants retrieved from the Tezos node. *)
  loser_mode : Loser_mode.t;
      (** If different from [Loser_mode.no_failures], the rollup node
          issues wrong commitments (for tests). *)
}

(** [get_operator_keys cctxt] returns a triple [(pkh, pk, sk)] corresponding
    to the address, public key, and secret key URI of the rollup node operator.
*)
val get_operator_keys :
  t ->
  (Signature.Public_key_hash.t * Signature.Public_key.t * Client_keys.sk_uri)
  tzresult
  Lwt.t

(** [init cctxt l1_ctxt sc_rollup operator_pkh] initialises the rollup
    representation.  The rollup origination level and kind are fetched via an
    RPC call to the layer1 node that [cctxt] uses for RPC requests.
*)
val init :
  Protocol_client_context.full ->
  Layer1.t ->
  Sc_rollup.t ->
  Protocol.Alpha_context.Sc_rollup.Commitment.genesis_info ->
  Protocol.Alpha_context.Sc_rollup.Kind.t ->
  Signature.Public_key_hash.t ->
  Injection.fee_parameter ->
  loser_mode:Loser_mode.t ->
  t tzresult Lwt.t
