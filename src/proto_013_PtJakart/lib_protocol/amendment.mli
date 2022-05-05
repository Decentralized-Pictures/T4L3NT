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

(**
   Amendments and proposals.

   Only delegates with at least one roll take part in the amendment
   procedure.  It works as follows:

   - Proposal period: delegates can submit protocol amendment
   proposals using the proposal operation. At the end of a proposal
   period, the proposal with most supporters is selected and we move
   to an exploration period. If there are no proposals, or a tie
   between proposals, a new proposal period starts.

   - Exploration period: delegates can cast votes to test or not the
   winning proposal using the ballot operation.  At the end of an
   exploration period if participation reaches the quorum and the
   proposal has a supermajority in favor, we proceed to a cooldown
   period. Otherwise we go back to a proposal period.  In any case, if
   there is enough participation the quorum is updated.

   - Cooldown period: business as usual for the main chain. This
   period is only a time gap between exploration and promotion
   periods intended to provide the community with extra time to
   continue testing the new protocol proposal, and start adapting
   their infrastructure in advance.  At the end of the Cooldown
   period we move to the Promotion period.

   - Promotion period: delegates can cast votes to promote or not the
   proposal using the ballot operation.  At the end of a promotion
   period if participation reaches the quorum and the proposal has a
   supermajority in favor, we move to an adoption period. Otherwise we
   go back to a proposal period.  In any case, if there is enough
   participation the quorum is updated.

   - Adoption period: At the end of an adoption period, the proposal
   is activated as the new protocol.

   The current protocol parameters are documented in
   src/proto_alpha/lib_parameters/default_parameters.ml

   In practice, the real constants used are defined in the
   migration code. In src/proto_alpha/lib_protocol/init_storage.ml,
   function [prepare_first_block] introduces new constants and
   redefines the existing ones.
*)

open Alpha_context

(** If at the end of a voting period, moves to the next one following
    the state machine of the amendment procedure. *)
val may_start_new_voting_period : context -> context tzresult Lwt.t

(** Records a list of proposals for a delegate.
    @raise Unexpected_proposal if [ctxt] is not in a proposal period.
    @raise Unauthorized_proposal if [delegate] is not in the listing. *)
val record_proposals :
  context -> public_key_hash -> Protocol_hash.t list -> context tzresult Lwt.t

type error +=
  | Invalid_proposal
  | Unexpected_ballot
  | Unauthorized_ballot
  | Duplicate_ballot

(** Records a vote for a delegate if the current voting period is
    Exploration or Promotion.
    @raise Invalid_proposal if [proposal] ≠ [current_proposal].
    @raise Duplicate_ballot if delegate already voted.
    @raise Unauthorized_ballot if delegate is not listed to vote,
    or if current period differs from Exploration or Promotion.
*)
val record_ballot :
  context ->
  public_key_hash ->
  Protocol_hash.t ->
  Vote.ballot ->
  context tzresult Lwt.t
