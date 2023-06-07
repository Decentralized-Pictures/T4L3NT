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

(** The rollup node maintains an inbox of incoming messages.

   The incoming messages for a rollup are published on the layer 1. To
   maintain the state of its inbox, a rollup node retrieves these
   messages each time the tezos blockchain is updated.

   The inbox state is persistent.

*)

open Protocol.Alpha_context
open Sc_rollup

(** [process_head node_ctxt ~predecessor head operations] changes the state of
    the inbox to react to [head] (where [predecessor] is the predecessor of
    [head] in the L1 chain). In particular, this process filters the provided
    [operations] of the [head] block. *)
val process_head :
  Node_context.rw ->
  predecessor:Layer1.header ->
  Layer1.header ->
  (Sc_rollup.Inbox.Hash.t
  * Sc_rollup.Inbox.t
  * Sc_rollup.Inbox_merkelized_payload_hashes.Hash.t
  * Sc_rollup.Inbox_message.t list)
  tzresult
  Lwt.t

(** [start ()] initializes the inbox to track the messages being published. *)
val start : unit -> unit Lwt.t

(** [add_messages ~predecessor_timestamp ~predecessor inbox messages] adds
    [messages] to the [inbox] using {!Inbox.add_all_messages}. *)
val add_messages :
  predecessor_timestamp:Timestamp.time ->
  predecessor:Block_hash.t ->
  Inbox.t ->
  Inbox_message.t list ->
  (Inbox_merkelized_payload_hashes.History.t
  * Inbox_merkelized_payload_hashes.Hash.t
  * Inbox.t
  * Inbox_message.t list)
  tzresult
  Lwt.t

(** [payloads_history_of_messages ~predecessor ~predecessor_timestamp messages]
    builds the payloads history for the list of [messages]. This allows to not
    store payloads histories (which contain merkelized skip lists) but simply
    messages. *)
val payloads_history_of_messages :
  predecessor:Block_hash.t ->
  predecessor_timestamp:Timestamp.time ->
  Sc_rollup.Inbox_message.t list ->
  Sc_rollup.Inbox_merkelized_payload_hashes.History.t tzresult

(**/**)

module Internal_for_tests : sig
  val process_messages :
    Node_context.rw ->
    predecessor:Layer1.header ->
    level:int32 ->
    Sc_rollup.Inbox_message.t list ->
    (Sc_rollup.Inbox.Hash.t
    * Sc_rollup.Inbox.t
    * Sc_rollup.Inbox_merkelized_payload_hashes.Hash.t
    * Sc_rollup.Inbox_message.t list)
    tzresult
    Lwt.t
end
