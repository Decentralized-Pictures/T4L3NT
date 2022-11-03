(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(** This module defines functions that emit the events used by the smart
    contract rollup node daemon (see {!Daemon}). *)

(** [head_processing hash level finalized seen_before] emits the event that the
    block of the given [hash] and at the given [level] is being processed, and
    whether it is [finalized] and has been [seen_before]. *)
val head_processing : Block_hash.t -> int32 -> bool -> bool -> unit Lwt.t

(** [not_finalized_head hash level] emits the event that the block of the given
    [hash] and at the given [level] is being processed but has not been
    finalized yet by the layer 1 consensus algorithm. *)
val not_finalized_head : Block_hash.t -> int32 -> unit Lwt.t

(** [processing_heads_iteration old_heads new_heads] emits the event that a new
    iteration of processing the heads has been triggered, from the level of the
    oldest head to the level of the most recent head between the [old_heads] and
    the [new_heads]. *)
val processing_heads_iteration :
  Layer1.head list -> Layer1.head list -> unit Lwt.t

(** [included_operation ~finalized op result] emits an event that an operation
    for the rollup was included in a block (or finalized). *)
val included_operation :
  finalized:bool ->
  'kind Protocol.Alpha_context.manager_operation ->
  'kind Protocol.Apply_results.manager_operation_result ->
  unit Lwt.t

(** [wrong_initial_pvm_state_hash actual_hash expected_hash] emits the event
    that the initial state hash of the PVM [actual_hash] does not agree with
    [expected_hash]. *)
val wrong_initial_pvm_state_hash :
  Sc_rollup.State_hash.t -> Sc_rollup.State_hash.t -> unit Lwt.t
