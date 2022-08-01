(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

(** Initialize the internal state of the batcher. *)
val init :
  rollup:Tx_rollup.t ->
  signer:Signature.public_key_hash ->
  batch_burn_limit:Tez.t option ->
  Context.index ->
  Constants.t ->
  unit tzresult Lwt.t

(** Returns [true] if the batcher was started for this node. *)
val active : unit -> bool

(** Retrieve an L2 transaction from the queue. *)
val find_transaction : L2_transaction.hash -> L2_transaction.t option tzresult

(** List all queued transactions in the order they appear in the queue, i.e. the
    message that were added first to the queue are at the end of list. *)
val get_queue : unit -> L2_transaction.t list tzresult

(** [register_transaction ?apply state tx] registers a new L2 transaction [tx]
    in the queue of the batcher for future injection on L1. If [apply] is [true]
    (defaults to [true]), the transaction is applied on the batcher's incremental
    context. In this case, when the application fails, the transaction is not
    queued. A batch is injected asynchronously if a full batch can be constructed
    and [eager_batch] is [true]. *)
val register_transaction :
  ?eager_batch:bool ->
  ?apply:bool ->
  L2_transaction.t ->
  L2_transaction.hash tzresult Lwt.t

(** Create L2 batches of operations from the queue and pack them in an L1 batch
    operation. The batch operation is queued in the injector for injection on the
    Tezos node. *)
val batch : unit -> unit tzresult Lwt.t

(** Notifies a new L2 head to the batcher worker. *)
val new_head : L2block.t -> unit tzresult Lwt.t

(** Shutdown the batcher, waiting for the ongoing request to be processed. *)
val shutdown : unit -> unit Lwt.t
