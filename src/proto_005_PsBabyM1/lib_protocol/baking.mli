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


open Alpha_context
open Misc

type error += Invalid_fitness_gap of int64 * int64 (* `Permanent *)
type error += Timestamp_too_early of Timestamp.t * Timestamp.t (* `Permanent *)
type error += Invalid_block_signature of Block_hash.t * Signature.Public_key_hash.t (* `Permanent *)
type error += Unexpected_endorsement
type error += Invalid_signature  (* `Permanent *)
type error += Invalid_stamp  (* `Permanent *)

(** [minimal_time ctxt priority pred_block_time] returns the minimal
    time, given the predecessor block timestamp [pred_block_time],
    after which a baker with priority [priority] is allowed to
    bake. Fail with [Invalid_time_between_blocks_constant] if the minimal
    time cannot be computed. *)
val minimal_time: context -> int -> Time.t -> Time.t tzresult Lwt.t

(** [check_baking_rights ctxt block pred_timestamp] verifies that:
    * the contract that owned the roll at cycle start has the block signer as delegate.
    * the timestamp is coherent with the announced slot.
*)
val check_baking_rights:
  context -> Block_header.contents -> Time.t ->
  (public_key * Period.t) tzresult Lwt.t

(** For a given level computes who has the right to
    include an endorsement in the next block.
    The result can be stored in Alpha_context.allowed_endorsements *)
val endorsement_rights:
  context ->
  Level.t ->
  (public_key * int list * bool) Signature.Public_key_hash.Map.t tzresult Lwt.t

(** Check that the operation was signed by a delegate allowed
    to endorse at the level specified by the endorsement. *)
val check_endorsement_rights:
  context -> Chain_id.t -> Kind.endorsement Operation.t ->
  (public_key_hash * int list * bool) tzresult Lwt.t

(** Returns the baking reward calculated w.r.t a given priority [p] and a
    number [e] of included endorsements as follows:
      (block_reward / (p+1)) * (0.8 + 0.2 * e / endorsers_per_block)
*)
val baking_reward: context ->
  block_priority:int -> included_endorsements:int -> Tez.t tzresult Lwt.t

(** Returns the endorsing reward calculated w.r.t a given priority.  *)
val endorsing_reward: context -> block_priority:int -> int -> Tez.t tzresult Lwt.t

(** [baking_priorities ctxt level] is the lazy list of contract's
    public key hashes that are allowed to bake for [level]. *)
val baking_priorities:
  context -> Level.t -> public_key lazy_list

(** [first_baking_priorities ctxt ?max_priority contract_hash level]
    is a list of priorities of max [?max_priority] elements, where the
    delegate of [contract_hash] is allowed to bake for [level]. If
    [?max_priority] is [None], a sensible number of priorities is
    returned. *)
val first_baking_priorities:
  context ->
  ?max_priority:int ->
  public_key_hash ->
  Level.t ->
  int list tzresult Lwt.t

(** [check_signature ctxt chain_id block id] check if the block is
    signed with the given key, and belongs to the given [chain_id] *)
val check_signature: Block_header.t -> Chain_id.t -> public_key -> unit tzresult Lwt.t

(** Checks if the header that would be built from the given components
    is valid for the given diffculty. The signature is not passed as it
    is does not impact the proof-of-work stamp. The stamp is checked on
    the hash of a block header whose signature has been zeroed-out. *)
val check_header_proof_of_work_stamp:
  Block_header.shell_header -> Block_header.contents -> int64 -> bool

(** verify if the proof of work stamp is valid *)
val check_proof_of_work_stamp:
  context -> Block_header.t -> unit tzresult Lwt.t

(** check if the gap between the fitness of the current context
    and the given block is within the protocol parameters *)
val check_fitness_gap:
  context -> Block_header.t -> unit tzresult Lwt.t

val dawn_of_a_new_cycle: context -> Cycle.t option tzresult Lwt.t

val earlier_predecessor_timestamp: context -> Level.t -> Timestamp.t tzresult Lwt.t

(** Since Emmy+

    A block is valid only if its timestamp has a minimal delay with
    respect to the previous block's timestamp, and this minimal delay
    depends not only on the block's priority but also on the number of
    endorsement operations included in the block.

    In Emmy+, blocks' fitness increases by one unit with each level.

    In this way, Emmy+ simplifies the optimal baking strategy: The
    bakers used to have to choose whether to wait for more endorsements
    to include in their block, or to publish the block immediately,
    without waiting. The incentive for including more endorsements was
    to increase the fitness and win against unknown blocks. However,
    when a block was produced too late in the priority period, there
    was the risk that the block did not reach endorsers before the
    block of next priority. In Emmy+, the baker does not need to take
    such a decision, because the baker cannot publish a block too
    early. *)

(** Given a delay of a block's timestamp with respect to the minimum
    time to bake at the block's priority (as returned by
    `minimum_time`), it returns the minimum number of endorsements that
    the block has to contain *)
val minimum_allowed_endorsements: context -> block_delay:Period.t -> int

(** This is the somehow the dual of the previous function. Given a
    block priority and a number of endorsement slots (given by the
    `endorsing_power` argument), it returns the minimum time at which
    the next block can be baked. *)
val minimal_valid_time:
  context ->
  priority:int ->
  endorsing_power: int ->
  Time.t tzresult Lwt.t
