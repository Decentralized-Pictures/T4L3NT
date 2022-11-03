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

(** Slot header representation for the data-availability layer.

    {1 Overview}

    For the data-availability layer, the L1 provides a list of slots
   at every level. A slot is a blob of data that can be interpreted by
   the users of the data-availability layer (such as SCORU).

    The purpose of the data-availability layer is to increase the
   bandwidth of the layer 1 thanks to the distribution of "slots". A
   slot is never posted directly onto the layer 1 blocks but on the
   data-availability layer. The producer of a slot sill has to post a
   slot header onto the layer 1. A slot header is an abstract datatype
   certifying that the corresponding slot has some maximum size
   (provided by the layer 1). In other words, the whole data contained
   into the slot cannot exceed some fixed size. This is to avoid
   attacks where a slot header would be posted onto the layer 1 block,
   declared available by the protocol, but actually the slot size
   would be too large to be refuted a posteriori.

   The slot header can also be used to prove that a blob of data is a
   portion of the initial slot. *)

module Commitment : sig
  (** A slot commitment is provided via the environment. *)
  type t = Dal.commitment

  val encoding : t Data_encoding.t

  (** A dummy value for a commitment. This commitment does not
     correspond to any valid pre-image. *)
  val zero : t
end

(** An `Index.t` is a possible value for a slot index. We assume this value
    to be a positive 8-bit integer. Note that this is a hard constraint,
    which is independent of protocol constants. If a choice is ever made to
    increase the size of available slots in the protocol, we also need
    to change this module to accommodate for higher values.
*)
module Index : sig
  type t

  val encoding : t Data_encoding.t

  val pp : Format.formatter -> t -> unit

  val zero : t

  val max_value : t

  (** [of_int n] constructs a`Slot_index.t` *)
  val of_int : int -> t option

  val to_int : t -> int

  val compare : t -> t -> int

  val equal : t -> t -> bool
end

module Header : sig
  (** For Layer-1, a slot is described by the level at which it is published,
    the slot's index (in the list of slots), and the slot's header
    (KATE commitment hash). *)
  type id = {published_level : Raw_level_repr.t; index : Index.t}

  type t = {id : id; commitment : Commitment.t}

  (** The encoding ensures the slot is always a non-negative number. *)
  val encoding : t Data_encoding.t

  val pp : Format.formatter -> t -> unit

  val equal : t -> t -> bool
end

(** A DAL slot is decomposed to a successive list of pages with fixed content
   size. The size is chosen so that it's possible to inject a page in a Tezos
   L1 operation if needed during the proof phase of a refutation game.
*)
module Page : sig
  type content = Bytes.t

  type slot_index = Index.t

  module Index : sig
    type t = int

    val zero : int

    val encoding : int Data_encoding.t

    val pp : Format.formatter -> int -> unit

    val compare : int -> int -> int

    val equal : int -> int -> bool
  end

  (** Encoding for page contents. *)
  val content_encoding : content Data_encoding.t

  (** A page is identified by its slot id and by its own index in the list
     of pages of the slot. *)
  type t = {slot_id : Header.id; page_index : Index.t}

  type proof = Dal.page_proof

  val equal : t -> t -> bool

  val encoding : t Data_encoding.t

  val proof_encoding : proof Data_encoding.t

  val pp : Format.formatter -> t -> unit
end

(** Only one slot header is accepted per slot index. If two slots
   headers are included into a block, the second one will fail.

   Consequently, we rely on the order of operations which is done
   thanks to the fee market.

  This is encapsulated in the following module.  *)
module Slot_market : sig
  (** Represent the fee market for a list of slots. *)
  type t

  (** [init ~length] encodes a list of [length] slots without
     candidates. *)
  val init : length:int -> t

  (** [length t] returns the [length] provided at initialisation time
     (see {!val:init}). *)
  val length : t -> int

  (** [register t index fees] updates the candidate associated to
     index [index]. Returns [Some (_, true)] if the candidate is
     registered. Returns [Some (_, false)] otherwise. Returns [None]
     if the [index] is not in the interval [0;length] where [length]
     is the value provided to the [init] function. *)
  val register : t -> Header.t -> (t * bool) option

  (** [candidates t] returns a list of slot header candidates. *)
  val candidates : t -> Header.t list
end

(** This module provides an abstract data structure (type {!t}) that represents a
    skip list used to store successive DAL slots confirmed on L1. There is one
    slot per cell in the skip list. The slots are sorted in increasing order by
    level, and by slot index, for the slots of the same level.

    This module also defines a bounded history cache (type {History_cache.t})
    that allows to remember recent values of a skip list of type {!t}
    (indexed by the skip lists' hashes). This structure is meant to be
    maintained and used by the rollup node to produce refutation proofs
    involving DAL slot inputs.
*)
module History : sig
  (** Abstract representation of a skip list specialized for
       confirmed slot headers. *)
  type t

  (** Encoding of the datatype. *)
  val encoding : t Data_encoding.t

  (** First cell of this skip list. *)
  val genesis : t

  (** The [History_cache.t] structure is basically a bounded lookup table of
      {!t} skip lists. (See {!Bounded_history_repr.S}). In the L1 layer, the
      capacity (bound) is set to zero (nothing is remembered). By contrast,
      the rollup node uses a history cache with a (sufficiently) large capacity
      to participate in all potential refutation games occurring during the
      challenge period. Indeed, the successive recent skip-lists stored in
      the cache are needed to produce proofs involving slots' pages. *)
  module History_cache : Bounded_history_repr.S

  (** [add_confirmed_slots hist cache slot_headers] updates the given structure
      [hist] with the list of [slot_headers]. The given [cache] is also updated to
      add successive values of [cell] to it. *)
  val add_confirmed_slot_headers :
    t -> History_cache.t -> Header.t list -> (t * History_cache.t) tzresult

  (** [add_confirmed_slot_headers_no_cache cell slot_headers] same as
     {!add_confirmed_slot_headers}, but no cache is updated. *)
  val add_confirmed_slot_headers_no_cache : t -> Header.t list -> t tzresult

  (** [equal a b] returns true iff a is equal to b. *)
  val equal : t -> t -> bool

  (** {1 Dal slots/pages proofs} *)

  (** When a SCORU kernel's inputs come from the DAL, they are provided as
      pages' content for confirmed slots, or None in case the slot doesn't
      exist or is not confirmed.

      In a refutation game involving an import tick of a Dal page input, a
      honest user should be able to provide:

      - When the PVM is requesting a page of a confirmed slot: a proof that the
      slot is confirmed, in addition to needed information to check that the
      page (whose id and content are given) is part of the slot;

      - When the opponent pretends that the PVM is requesting a page of some
      unconfirmed slot, but that slot is not published or not confirmed on L1:
      a proof that the slot (whose id is given via the page's id) cannot be
      confirmed on L1.

      See the documentation in the ml file for more technical details. *)
  type proof

  (** Encoding for {!proof}. *)
  val proof_encoding : proof Data_encoding.t

  (** Pretty-printer for {!proof}. *)
  val pp_proof : Format.formatter -> proof -> unit

  (** To verify the proof of a page membership in its associated slot, the
     Cryptobox module needs the following Dal parameters. These are part of the
     protocol's parameters. See {!Default_parameters.default_dal}. *)
  type dal_parameters = Dal.parameters = {
    redundancy_factor : int;
    page_size : int;
    slot_size : int;
    number_of_shards : int;
  }

  (** An encoding for values of type {!dal_parameters}. *)
  val dal_parameters_encoding : dal_parameters Data_encoding.t

  (** [produce_proof dal_parameters page_id page_info slots_hist hist_cache]
      produces a proof that either:
      - there exists a confirmed slot in the skip list that contains
        the page identified by [page_id] whose data and slot inclusion proof
        are given by [page_info], or
      - there cannot exist a confirmed slot in the skip list (whose head is
        given by [slots_hist]) containing the page identified by [page_id].

      In the first case above, [page_info] should contain the page's content
      and the proof that the page is part of the (confirmed) slot whose
      id is given in [page_id]. In the second case, no page content or proof
      should be provided, as they are not needed to construct a non-confirmation
      proof.

      [dal_parameters] is used when verifying that/if the page is part of
      the candidate slot (if any).
  *)
  val produce_proof :
    dal_parameters ->
    Page.t ->
    page_info:(Page.content * Page.proof) option ->
    t ->
    History_cache.t ->
    (proof * Page.content option) tzresult Lwt.t

  (** [verify_proof dal_params page_id snapshot proof] verifies that the given
      [proof] is a valid proof to show that either:
      - the page identified by [page_id] belongs to a confirmed slot stored in
      the skip list whose head is [snapshot], or
      - there is not confirmed slot in the skip list (whose head is) [snapshot]
      that could contain the page identified by [page_id].

      [dal_parameters] is used when verifying that/if the page is part of
      the candidate slot (if any).
  *)
  val verify_proof :
    dal_parameters -> Page.t -> t -> proof -> Page.content option tzresult Lwt.t

  type error += Add_element_in_slots_skip_list_violates_ordering

  type error += Dal_proof_error of string

  module Internal_for_tests : sig
    val content : t -> Header.t

    val proof_statement_is : proof -> [`Confirmed | `Unconfirmed] -> bool
  end
end
