(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022 Trili Tech, <contact@trili.tech>                       *)
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

(** The smart contract rollup refutation game types are defined here, as
    well as the basic pure logic for:

    - how to create a new game from a pair of commits in the commit tree;

    - how to update a game or complete a game when a move is played.

    This game logic is used by the protocol when two commitments are in
    conflict to determine which one of the commitments is wrong.

    Game state and moves
    ====================

    The first step consists of dissecting the commitment's number of ticks.
    The game stores a list [dissection] of state hashes and tick counts.
    These are the claims about the PVM history made by the player who has
    just moved.

    The next player to move will specify a tick count which appears in
    the [dissection]; this is the last of the state hashes which she
    agrees with. She will then either:

    - provide a new [dissection] by giving a list of state hashes and
    tick counts that starts at the chosen tick count and ends at the
    next tick count in the previous [dissection]. It must agree at the
    start but disagree with the final state.

    - if the tick difference between this state and the next is one,
    there is no 'room' for a new [dissection]. In this case she must
    provide a Merkle proof that shows the step in the current
    [dissection] is invalid.

    If a player failed to prove that the current [dissection] is valid.
    We reach the final move of the game. The other player will have
    a chance to prove that the [dissection] is valid.
    If both player fails to invalidate each other, the game ends in a draw.

    Initializing a game
    ===================

    In order to trigger the start of a game, one player must publish a
    first move.

    The [initial] function is called at this point. It converts a
    parent-child pair of commitments (belonging to the other player) into
    an initial [dissection]. The first move is immediately applied to
    this to give the first state of the game.

    Note: it is quite possible for the game to end immediately after
    this first move, either if the commitment has a tick count of one or
    more probably if the refutation proves that the commitment was
    'premature' (the state is not blocked---there are further
    computation steps to do or more inbox messages to read).

    Expected properties
    ===================

    P1 - If [dissection] is honest, the next move must be dishonest:

      There is only one honest state hash for a given tick count. The
      next player must provide a different hash to the honest hash in
      the [dissection].

    P2 - If [dissection] is dishonest, there is a strategy for a player
    equipped with a perfect PVM to play an honest next move:

      The player with a perfect PVM can calculate honest hashes until
      one disagrees with the [dissection], and challenges the dissection
      at that point, publishing either an honest [dissection] or an
      honest [Proof].

    Each [dissection] has a maximum tick count step shorter than the
    last, so by induction using P1 and P2 we have

    P1' - If [dissection] is honest, the last player has a winning
    strategy.

    P2' - If [dissection] is dishonest, the next player has a winning
    strategy.

    This allows us to see the following. (We use [refuter] to mean the
    first player to move, and [defender] to mean the other player.)

    Honest refuter wins:
      An honest refuter will be refuting a dishonest commitment, because
      there is only one honest state possible per level. Therefore the
      initial [dissection] will be dishonest. By P2' the refuter has a
      winning strategy.

    Honest defender wins:
      An honest defender will have made an honest commitment which will
      be translated into an honest initial [dissection]. By P1' the
      defender has a winning strategy.

*)

open Sc_rollup_repr

type error +=
  | Dissection_choice_not_found of Sc_rollup_tick_repr.t
        (** The given choice in a refutation is not a starting tick of any of
          the sections in the current dissection. *)
  | Dissection_number_of_sections_mismatch of {expected : Z.t; given : Z.t}
        (** There are more or less than the expected number of sections in the
          given dissection. *)
  | Dissection_invalid_number_of_sections of Z.t
        (** There are less than two sections in the given dissection, which is
          not valid. *)
  | Dissection_start_hash_mismatch of {
      expected : Sc_rollup_repr.State_hash.t option;
      given : Sc_rollup_repr.State_hash.t option;
    }
        (** The given start hash in a dissection is [None] or doesn't match the
          expected one.*)
  | Dissection_stop_hash_mismatch of Sc_rollup_repr.State_hash.t option
        (** The given stop state hash in a dissection should not match the last
          hash of the section being refuted. *)
  | Dissection_edge_ticks_mismatch of {
      dissection_start_tick : Sc_rollup_tick_repr.t;
      dissection_stop_tick : Sc_rollup_tick_repr.t;
      chunk_start_tick : Sc_rollup_tick_repr.t;
      chunk_stop_tick : Sc_rollup_tick_repr.t;
    }
        (** The given dissection's edge ticks don't match the edge ticks of the
          section being refuted. *)
  | Dissection_ticks_not_increasing
        (** Invalid provided dissection because ticks are not increasing between
          two successive sections. *)
  | Dissection_invalid_distribution
        (** Invalid provided dissection because ticks split is not well balanced
          across sections *)
  | Dissection_invalid_successive_states_shape
        (** A dissection cannot have a section with no state hash after another
          section with some state hash. *)
  | Proof_unexpected_section_size of Z.t
        (** Invalid proof step because there is more than one tick. *)
  | Proof_start_state_hash_mismatch of {
      start_state_hash : Sc_rollup_repr.State_hash.t option;
      start_proof : Sc_rollup_repr.State_hash.t;
    }
        (** The given proof's starting state doesn't match the expected one. *)
  | Proof_stop_state_hash_failed_to_refute of {
      stop_state_hash : Sc_rollup_repr.State_hash.t option;
      stop_proof : Sc_rollup_repr.State_hash.t option;
    }
        (** The given proof's ending state should not match the state being
          refuted. *)
  | Proof_stop_state_hash_failed_to_validate of {
      stop_state_hash : Sc_rollup_repr.State_hash.t option;
      stop_proof : Sc_rollup_repr.State_hash.t option;
    }
        (** The given proof's ending state should match the state being
          refuted. *)
  | Dissecting_during_final_move
        (** The step move is a dissecting where the final move has started
            already. *)

(** The two stakers index the game in the storage as a pair of public
    key hashes which is in lexical order. We use [Alice] and [Bob] to
    represent the first and second player in the pair respectively. *)
type player = Alice | Bob

module V1 : sig
  (** A dissection chunk is made of a state hash (that could be [None], see
    invariants below), and a tick count. *)
  type dissection_chunk = {
    state_hash : State_hash.t option;
    tick : Sc_rollup_tick_repr.t;
  }

  val pp_dissection_chunk : Format.formatter -> dissection_chunk -> unit

  val dissection_chunk_encoding : dissection_chunk Data_encoding.t

  (** Describes the current state of a game. *)
  type game_state =
    | Dissecting of {
        dissection : dissection_chunk list;
            (** [dissection], a list of states with tick counts. The current
                player will specify, in the next move, a tick count that
                indicates the last of these states that she agrees with. *)
        default_number_of_sections : int;
            (** [default_number_of_sections] is the number of sections a
                disection should contain in the more general case where we still
                have a high enough number of disputed ticks. *)
      }
        (** When the state is [Dissecting], both player are still dissecting
            the commitment to find the tick to refute. *)
    | Final_move of {
        agreed_start_chunk : dissection_chunk;
        refuted_stop_chunk : dissection_chunk;
      }
        (** When the state is [Final_move], either [Alice] or [Bob] already
            played an invalid proof.

            The other player will have a chance to prove that the
            [refuted_stop_state] is valid.
            If both players fail to either validate or refute the stop state,
            the current game state describes a draw situation.
            In the same way, the draw can be described by the situation where
            the two players manage to validate or refute the stop state. *)

  val game_state_encoding : game_state Data_encoding.t

  val game_state_equal : game_state -> game_state -> bool

  (** A game is characterized by:

    - [turn], the player that must provide the next move.

    - [inbox_snapshot], a snapshot of the inbox state at the moment the
      game is created. This is only used when checking [Input_step] and
      [Blocked_step] proofs; it makes the proofs easier to create---
      otherwise they would have a 'moving target' because the actual
      inbox may be updated continuously.

    - [level], the inbox level of the commitment the game is refuting.
      This is only used when checking [Blocked_step] proofs---the proof
      will show that the next message available in [inbox_snapshot] is
      at [level], so shouldn't be included in this commitment.

    - [pvm_name] identifies the PVM used in this rollup. It is useful to
      have here so we can check that the proof provided in a refutation
      is of the correct kind.

    - [game_state], the current state of the game, see {!game_state}
      for more information.

    Invariants:
    -----------
    - [dissection] must contain at least 2 values (normally it will be 32
    values, but smaller if there isn't enough space for a dissection
    that size. The initial game dissection will be 3 values except in
    the case of a zero-tick commit when it will have 2 values.)
    - the first state hash value in [dissection] must not be [None]
    - [inbox_snapshot] never changes once the game is created
  *)
  type t = {
    turn : player;
    inbox_snapshot : Sc_rollup_inbox_repr.history_proof;
    start_level : Raw_level_repr.t;
    inbox_level : Raw_level_repr.t;
    pvm_name : string;
    game_state : game_state;
  }

  (** [equal g1 g2] returns [true] iff [g1] is equal to [g2]. *)
  val equal : t -> t -> bool

  (** Return the other player *)
  val opponent : player -> player

  val encoding : t Data_encoding.t

  val pp_dissection : Format.formatter -> dissection_chunk list -> unit

  val player_equal : player -> player -> bool

  val player_encoding : player Data_encoding.t

  val pp : Format.formatter -> t -> unit
end

(** Versioning, see {!Sc_rollup_data_version_sig.S} for more information. *)
include Sc_rollup_data_version_sig.S with type t = V1.t

include
  module type of V1
    with type dissection_chunk = V1.dissection_chunk
     and type game_state = V1.game_state
     and type t = V1.t

module Index : sig
  type t = private {alice : Staker.t; bob : Staker.t}

  (** [to_path i p] returns a new path with the path to the game indexed
      by [i] added as a prefix to path [p]. See [Path_encoding] module. *)
  val to_path : t -> string list -> string list

  val of_path : string list -> t option

  val path_length : int

  val rpc_arg : t RPC_arg.t

  val encoding : t Data_encoding.t

  val compare : t -> t -> int

  val make : Staker.t -> Staker.t -> t

  (** Given an index in normal form, resolve a given [player] ([Alice]
      or [Bob]) to the actual staker they represent. *)
  val staker : t -> player -> Staker.t
end

(** To begin a game, first the conflict point in the commit tree is
    found, and then this function is applied.

    [initial inbox ~start_level ~pvm_name ~parent ~child ~refuter ~defender
    ~default_number_of_sections] will construct an initial game where [refuter]
    is next to play. The game has [dissection] with three states:

      - firstly, the state (with tick zero) of [parent], the commitment
      that both stakers agree on.

      - secondly, the state and tick count of [child], the commitment
      that [defender] has staked on.

      - thirdly, a [None] state which is a single tick after the [child]
      commitment. This represents the claim, implicit in the commitment,
      that the state given is blocked.

    This gives [refuter] a binary choice: she can refute the commit
    itself by providing a new dissection between the two committed
    states, or she can refute the claim that the [child] commit is a
    blocked state by immediately providing a proof of a single tick
    increment from that state to its successor. *)
val initial :
  Sc_rollup_inbox_repr.history_proof ->
  start_level:Raw_level_repr.t ->
  pvm_name:string ->
  parent:Sc_rollup_commitment_repr.t ->
  child:Sc_rollup_commitment_repr.t ->
  refuter:Staker.t ->
  defender:Staker.t ->
  default_number_of_sections:int ->
  t

(** A [step] in the game is either a new dissection (if there are
    intermediate ticks remaining to put in it) or a proof. *)
type step =
  | Dissection of dissection_chunk list
  | Proof of Sc_rollup_proof_repr.t

(** A [refutation] is a move in the game. [choice] is the final tick
    in the current dissection at which the two players agree. *)
type refutation = {choice : Sc_rollup_tick_repr.t; step : step}

val pp_refutation : Format.formatter -> refutation -> unit

val refutation_encoding : refutation Data_encoding.t

(** A game ends for one of two reasons: the conflict has been
resolved via a proof or a player has been timed out. *)
type reason = Conflict_resolved | Timeout

val pp_reason : Format.formatter -> reason -> unit

val reason_encoding : reason Data_encoding.t

(** The game result. *)
type game_result =
  | Loser of {reason : reason; loser : Staker.t}  (** One player lost. *)
  | Draw  (** The game ended in a draw *)

val pp_game_result : Format.formatter -> game_result -> unit

val game_result_encoding : game_result Data_encoding.t

(** A type that represents the current game status in a way that is
    useful to the outside world (using actual [Staker.t] values
    instead of the internal [player] type).

    The [Staker.t] in the [Ended] case is the loser of the game: the
    staker who will have their stake slashed.

    Used in operation result types. *)
type status = Ongoing | Ended of game_result

val pp_status : Format.formatter -> status -> unit

val status_encoding : status Data_encoding.t

(** Decide the loser of the game, if it exists. *)
val loser_of_results : alice_result:bool -> bob_result:bool -> player option

(** Applies the move [refutation] to the game. Returns the game {!status}
    after applying the move.

    In the case of the game continuing, this swaps the current
    player and returns a [Ongoing] status. Otherwise, it returns a
    [Ended <game_result>] status.
*)
val play :
  stakers:Index.t ->
  Sc_rollup_metadata_repr.t ->
  t ->
  refutation ->
  (game_result, t) Either.t tzresult Lwt.t

(** A type that represents the number of blocks left for players to play. Each
    player has her timeout value. `timeout` is expressed in the number of
    blocks.

    Timeout logic is similar to a chess clock. Each player starts with the same
    timeout. Each game move updates the timeout of the current player by
    decreasing it by the amount of time she took to play, i.e. number of blocks
    since the opponent last move. See {!Sc_rollup_refutation_storage.game_move}
    to see the implementation.
*)
type timeout = {
  alice : int;  (** Timeout of [Alice]. *)
  bob : int;  (** Timeout of [Bob]. *)
  last_turn_level : Raw_level_repr.t;  (** Block level of the last turn move. *)
}

val timeout_encoding : timeout Data_encoding.t

module Internal_for_tests : sig
  (** Checks that the tick count chosen by the current move is one of
    the ones in the current dissection. Returns a tuple containing
    the current dissection interval (including the two states) between
    this tick and the next. *)
  val find_choice :
    dissection_chunk list ->
    Sc_rollup_tick_repr.t ->
    (dissection_chunk * dissection_chunk) tzresult

  (** We check firstly that [dissection] is the correct length. It must be
    [default_number_of_sections] values long, unless the distance between
    [start_tick] and [stop_tick] is too small to make this possible, in which
    case it should be as long as possible. (If the distance is one we fail
    immediately as there is no possible legal dissection).

    Then we check that [dissection] starts at the correct tick and state,
    and that it ends at the correct tick and with a different state to
    the current dissection.

    Finally, we check that [dissection] is well formed: it has correctly
    ordered the ticks, and it begins with a real hash of the form [Some
    s] not a [None] state. Note that we have to allow the possibility of
    multiple [None] states because the restrictions on dissection shape
    (which are necessary to prevent a 'linear-time game' attack) will
    mean that sometimes the honest play is a dissection with multiple
    [None] states. *)
  val check_dissection :
    default_number_of_sections:int ->
    start_chunk:dissection_chunk ->
    stop_chunk:dissection_chunk ->
    dissection_chunk list ->
    unit tzresult
end
