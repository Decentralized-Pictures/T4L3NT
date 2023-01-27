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

type lcc = {commitment : Sc_rollup.Commitment.Hash.t; level : Raw_level.t}

type 'a t = {
  cctxt : Protocol_client_context.full;
      (** Client context used by the rollup node. *)
  dal_cctxt : Dal_node_client.cctxt;
      (** Client context to query the dal node. *)
  data_dir : string;  (** Node data dir. *)
  l1_ctxt : Layer1.t;
      (** Layer 1 context to fetch blocks and monitor heads, etc.*)
  rollup_address : Sc_rollup.t;  (** Smart rollup tracked by the rollup node. *)
  operators : Configuration.operators;
      (** Addresses of the rollup node operators by purposes. *)
  genesis_info : Sc_rollup.Commitment.genesis_info;
      (** Origination information of the smart rollup. *)
  injector_retention_period : int;
      (** Number of blocks the injector will keep information about included
          operations. *)
  block_finality_time : int;
      (** Deterministic block finality time for the layer 1 protocol. *)
  kind : Sc_rollup.Kind.t;  (** Kind of the smart rollup. *)
  fee_parameters : Configuration.fee_parameters;
      (** Fee parameters to use when injecting operations in layer 1. *)
  protocol_constants : Constants.t;
      (** Protocol constants retrieved from the Tezos node. *)
  loser_mode : Loser_mode.t;
      (** If different from [Loser_mode.no_failures], the rollup node
          issues wrong commitments (for tests). *)
  store : 'a Store.t;  (** The store for the persistent storage. *)
  context : 'a Context.index;
      (** The persistent context for the rollup node. *)
  mutable lcc : lcc;  (** Last cemented commitment and its level. *)
  mutable lpc : Sc_rollup.Commitment.t option;
      (** The last published commitment, i.e. commitment that the operator is
          staked on. *)
}

(** Read/write node context {!t}. *)
type rw = [`Read | `Write] t

(** Read only node context {!t}. *)
type ro = [`Read] t

(** [get_operator cctxt purpose] returns the public key hash for the operator
    who has purpose [purpose], if any.
*)
val get_operator :
  _ t -> Configuration.purpose -> Signature.Public_key_hash.t option

(** [is_operator cctxt pkh] returns [true] if the public key hash [pkh] is an
    operator for the node (for any purpose). *)
val is_operator : _ t -> Signature.Public_key_hash.t -> bool

(** [get_fee_parameter cctxt purpose] returns the fee parameter to inject an
    operation for a given [purpose]. If no specific fee parameters were
    configured for this purpose, returns the default fee parameter for this
    purpose.
*)
val get_fee_parameter : _ t -> Configuration.purpose -> Injection.fee_parameter

(** [init cctxt dal_cctxt ~data_dir mode configuration] initializes the rollup
    representation. The rollup origination level and kind are fetched via an RPC
    call to the layer1 node that [cctxt] uses for RPC requests.
*)
val init :
  Protocol_client_context.full ->
  Dal_node_client.cctxt ->
  data_dir:string ->
  'a Store_sigs.mode ->
  Configuration.t ->
  'a t tzresult Lwt.t

(** [checkout_context node_ctxt block_hash] returns the context at block
    [block_hash]. *)
val checkout_context : 'a t -> Block_hash.t -> 'a Context.t tzresult Lwt.t

(** [metadata node_ctxt] creates a {Sc_rollup.Metadata.t} using the information
    stored in [node_ctxt]. *)
val metadata : _ t -> Sc_rollup.Metadata.t

(** Returns [true] if the DAL is enabled for the current protocol. *)
val dal_enabled : _ t -> bool

(** [readonly node_ctxt] returns a read only version of the node context
    [node_ctxt].  *)
val readonly : _ t -> ro

(** Monad for values with delayed write effects in the node context. *)
type 'a delayed_write = ('a, rw) Delayed_write_monad.t

(** {2 Abstraction over store} *)

(** [is_processed store hash] returns [true] if the block with [hash] has
    already been processed by the daemon. *)
val is_processed : _ Store.t -> Block_hash.t -> bool Lwt.t

(** [get_full_l2_block node_ctxt hash] returns the full L2 block for L1 block
    hash [hash]. The result contains the L2 block and its content (inbox,
    messages, commitment). *)
val get_full_l2_block : _ t -> Block_hash.t -> Sc_rollup_block.full Lwt.t

(** [save_level store head] registers the correspondences [head.level |->
    head.hash] in the store. *)
val save_level : Store.rw -> Layer1.head -> unit Lwt.t

(** [mark_processed_head store head] remembers that the [head] is processed. The
    system should not have to come back to it. *)
val save_l2_block : Store.rw -> Sc_rollup_block.t -> unit Lwt.t

(** [last_processed_head_opt store] returns the last processed head if it
    exists. *)
val last_processed_head_opt : _ Store.t -> Sc_rollup_block.t option Lwt.t

(** [mark_finalized_head store head] remembers that the [head] is finalized. By
    construction, every block whose level is smaller than [head]'s is also
    finalized. *)
val mark_finalized_head : Store.rw -> Block_hash.t -> unit Lwt.t

(** [last_finalized_head_opt store] returns the last finalized head if it exists. *)
val get_finalized_head_opt : _ Store.t -> Sc_rollup_block.t option Lwt.t

(** [hash_of_level node_ctxt level] returns the current block hash for a given
    [level]. *)
val hash_of_level : _ t -> int32 -> Block_hash.t tzresult Lwt.t

(** [hash_of_level_opt] is like {!hash_of_level} but returns [None] if the
    [level] is not known. *)
val hash_of_level_opt : _ t -> int32 -> Block_hash.t option Lwt.t

(** [level_of_hash node_ctxt hash] returns the level for Tezos block hash [hash]
    if it is known by the Tezos Layer 1 node. *)
val level_of_hash : _ t -> Block_hash.t -> int32 tzresult Lwt.t

(** [block_before store tick] returns the last layer 2 block whose initial tick
    is before [tick]. *)
val block_before :
  [> `Read] Store.store ->
  Sc_rollup.Tick.t ->
  Sc_rollup_block.t option tzresult Lwt.t
