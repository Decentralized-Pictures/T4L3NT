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

(** The rollup node stores and publishes commitments for the PVM
    every `Commitment.sc_rollup_commitment_period` levels.

    Every time a finalized block is processed  by the rollup node,
    the latter determines whether the last commitment that the node
    has produced referred to `Commitment.sc_rollup_commitment_period` blocks
    earlier. In this case, it computes and stores a new commitment in a
    level-indexed map.

    Stored commitments are signed by the rollup node operator
    and published on the layer1 chain. To ensure that commitments
    produced by the rollup node are eventually published,
    storing and publishing commitments are decoupled. Every time
    a new head is processed, the node tries to publish the oldest
    commitment that was not published already.
*)
module type S = sig
  module PVM : Pvm.S

  (** [process_head node_ctxt head] checks whether a new commitment needs to be
      computed and stored, by looking at the level of [head] and checking
      whether it is a multiple of `Commitment.sc_rollup_commitment_period`
      levels away from [node_ctxt.initial_level]. It uses the functionalities of
      [PVM] to compute the hash of to be included in the commitment.  *)
  val process_head : Node_context.t -> Layer1.head -> unit tzresult Lwt.t

  (** [sync_last_cemented_commitment_hash_with_level node_ctxt] fetches and
      stores information about the last cemeneted commitment in the layer1
      chain.  *)
  val sync_last_cemented_commitment_hash_with_level :
    Node_context.t -> unit tzresult Lwt.t

  (** [publish_commitment node_ctxt] publishes the earliest commitment
      stored in [store] that has not been published yet, unless its inbox level
      is below or equal to the inbox level of the last cemented commitment in
      the layer1 chain. In this case, the rollup node checks whether it has
      computed a commitment whose inbox level is
      [sc_rollup_commitment_period] levels after the inbox level of the last
      cemented commitment:
      {ul
      {li if the commitment is found and its predecessor hash coincides with
       the hash of the LCC, the rollup node will try to publish that commitment
      instead; }
      {li if the commitment is found but its predecessor hash differs from the
        hash of the LCC, the rollup node will stop its execution;}
      {li if no commitment is found, no action is taken by the rollup node;
        in particular, no commitment is published.}
    }
  *)
  val publish_commitment : Node_context.t -> unit tzresult Lwt.t

  (** [cement_commitment_if_possible node_ctxt head] checks whether the next
      commitment to be cemented (i.e. whose inbox level is
      [sc_rollup_commitment_period] levels after
      [Store.Last_cemented_commitment_level store]) can be cemented. In
      particular, the request to cement the commitment happens only if the
      commitment is stored in [Store.Commitments store], and if
      [sc_rollup_challenge_period] levels have passed since when the commitment
      was originally published.  *)
  val cement_commitment_if_possible :
    Node_context.t -> Layer1.head -> unit tzresult Lwt.t

  (** [start ()] only emits the event that the commitment manager
      for the rollup node has started. *)
  val start : unit -> unit Lwt.t
end
