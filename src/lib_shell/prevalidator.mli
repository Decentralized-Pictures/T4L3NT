(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018-2021 Nomadic Labs, <contact@nomadic-labs.com>          *)
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

(** Tezos Shell - Prevalidation of pending operations (a.k.a Mempool) *)

(** The prevalidator is in charge of the "mempool" (a.k.a. the
    set of known not-invalid-for-sure operations that are not yet
    included in the blockchain).

    The prevalidator also maintains a sorted subset of the mempool that
    might correspond to a valid block on top of the current head. The
    "in-progress" context produced by the application of those
    operations is called the (pre)validation context.

    Before including an operation into the mempool, the prevalidation
    worker tries to append the operation the prevalidation context. If
    the operation is (strongly) refused, it will not be added into the
    mempool and then it will be ignored by the node and never
    broadcast. If the operation is only "branch_refused" or
    "branch_delayed", the operation won't be appended in the
    prevalidation context, but still broadcast.

*)

(** An (abstract) prevalidator context. Separate prevalidator contexts should be
 * used for separate chains (e.g., mainchain vs testchain). *)
type t

(** This record contains the differents limits and settings that can be updated
    from a node configuration for a prevalidator *)
type limits = {
  max_refused_operations : int;
      (** The maximum number of operations tracked by the mempool for each of
          the [refused], [branch delayed], [branch refused] and [outdated]
          operation classifications. Default is [1000] *)
  operation_timeout : Time.System.Span.t;
      (** The maximum time allowed to fetch the contents of an operation
          advertised by a remote peer. Default is [10] seconds *)
  operations_batch_size : int;
      (** Maximum number of pending operations processed (or classified) at the
          end of each request to the prevalidator worker. Default is [50] *)
  disable_precheck : bool;
      (** If [disable_precheck] is [true] (default is [false]) operations are
          executed by the protocol before being propagated. This flag is
          intended to be used for testing and debugging. *)
}

(** Sane default values for {!limits} *)
val default_limits : limits

(** Creates/tear-down a new prevalidator context. *)
val create :
  limits ->
  (module Prevalidator_filters.FILTER) ->
  Distributed_db.chain_db ->
  t tzresult Lwt.t

val shutdown : t -> unit Lwt.t

(** Notify the prevalidator that the identified peer has sent a bunch of
 * operations relevant to the specified context. *)
val notify_operations : t -> P2p_peer.Id.t -> Mempool.t -> unit Lwt.t

(** [inject_operation t ~force op] notifies the prevalidator worker of a new
    injected operation. If [force] is set to [true] the operation is injected
    without any check. [force] should be used for test purpose only. *)
val inject_operation : t -> force:bool -> Operation.t -> unit tzresult Lwt.t

(** Notify the prevalidator that a new head has been selected.
    [update] is used as an optimisation to know which operations
    previously classified require to be prevalidated again. *)
val flush :
  t ->
  Chain_validator_worker_state.Event.update ->
  Block_hash.t ->
  Block_hash.Set.t ->
  Operation_hash.Set.t ->
  unit tzresult Lwt.t

(** Returns the list of prevalidation contexts running and their associated chain *)
val running_workers : unit -> (Chain_id.t * Protocol_hash.t * t) list

(** Worker status and events *)

(* None indicates the there are no workers for the current protocol. *)
val status : t -> Worker_types.worker_status

val pending_requests :
  t -> (Time.System.t * Prevalidator_worker_state.Request.view) list

val current_request :
  t ->
  (Time.System.t * Time.System.t * Prevalidator_worker_state.Request.view)
  option

val information : t -> Worker_types.worker_information

val pipeline_length : t -> int

val rpc_directory : t option RPC_directory.t
