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

(* TODO: https://gitlab.com/tezos/tezos/-/issues/3471
   Use indexed file for append-only instead of Irmin. *)

(* TODO: https://gitlab.com/tezos/tezos/-/issues/3739
   Refactor the store file to have functors in their own
   separate module, and return errors within the Error monad. *)

open Protocol
open Alpha_context

type +'a store

include Store_sigs.Store with type 'a t = 'a store

(** Type of store. The parameter indicates if the store can be written or only
    read. *)
type 'a t = ([< `Read | `Write > `Read] as 'a) store

(** Read/write store {!t}. *)
type rw = Store_sigs.rw t

(** Read only store {!t}. *)
type ro = Store_sigs.ro t

(** [close store] closes the store. *)
val close : _ t -> unit Lwt.t

(** [load mode directory] loads a store from the data persisted in [directory].*)
val load : 'a Store_sigs.mode -> string -> 'a store Lwt.t

(** [readonly store] returns a read-only version of [store]. *)
val readonly : _ t -> ro

module L2_blocks :
  Store_sigs.Append_only_map
    with type key := Block_hash.t
     and type value := Sc_rollup_block.t
     and type 'a store := 'a store

(** Storage for persisting messages downloaded from the L1 node. *)
module Messages : sig
  type info = {
    predecessor : Block_hash.t;
    predecessor_timestamp : Timestamp.t;
    messages : Sc_rollup.Inbox_message.t list;
  }

  include
    Store_sigs.Append_only_map
      with type key := Sc_rollup.Inbox_merkelized_payload_hashes.Hash.t
       and type value := info
       and type 'a store := 'a store
end

(** Aggregated collection of messages from the L1 inbox *)
module Inboxes :
  Store_sigs.Append_only_map
    with type key := Sc_rollup.Inbox.Hash.t
     and type value := Sc_rollup.Inbox.t
     and type 'a store := 'a store

(** Storage containing commitments and corresponding commitment hashes that the
    rollup node has knowledge of. *)
module Commitments :
  Store_sigs.Append_only_map
    with type key := Sc_rollup.Commitment.Hash.t
     and type value := Sc_rollup.Commitment.t
     and type 'a store := 'a store

(** Storage containing the inbox level of the last commitment produced by the
    rollup node. *)
module Last_stored_commitment_level :
  Store_sigs.Mutable_value
    with type value := Raw_level.t
     and type 'a store := 'a store

(** Storage mapping commitment hashes to the level when they were published by
    the rollup node. It only contains hashes of commitments published by this
    rollup node. *)
module Commitments_published_at_level : sig
  type element = {
    first_published_at_level : Raw_level.t;
        (** The level at which this commitment was first published. *)
    published_at_level : Raw_level.t option;
        (** The level at which we published this commitment. If
            [first_published_at_level <> published_at_level] it means that the
            commitment is republished. *)
  }

  include
    Store_sigs.Map
      with type key := Sc_rollup.Commitment.Hash.t
       and type value := element
       and type 'a store := 'a store
end

module L2_head :
  Store_sigs.Mutable_value
    with type value := Sc_rollup_block.t
     and type 'a store := 'a store

module Last_finalized_head :
  Store_sigs.Mutable_value
    with type value := Sc_rollup_block.t
     and type 'a store := 'a store

module Levels_to_hashes :
  Store_sigs.Map
    with type key := int32
     and type value := Block_hash.t
     and type 'a store := 'a store

(** Published slot headers per block hash,
    stored as a list of bindings from [Dal_slot_index.t]
    to [Dal.Slot.t]. The encoding function converts this
    list into a [Dal.Slot_index.t]-indexed map. *)
module Dal_slots_headers :
  Store_sigs.Nested_map
    with type primary_key := Block_hash.t
     and type secondary_key := Dal.Slot_index.t
     and type value := Dal.Slot.Header.t
     and type 'a store := 'a store

module Dal_confirmed_slots_history :
  Store_sigs.Append_only_map
    with type key := Block_hash.t
     and type value := Dal.Slots_history.t
     and type 'a store := 'a store

(** Confirmed DAL slots histories cache. See documentation of
    {Dal_slot_repr.Slots_history} for more details. *)
module Dal_confirmed_slots_histories :
  Store_sigs.Append_only_map
    with type key := Block_hash.t
     and type value := Dal.Slots_history.History_cache.t
     and type 'a store := 'a store

(** [Dal_slot_pages] is a [Store_utils.Nested_map] used to store the contents
    of dal slots fetched by the rollup node, as a list of pages. The values of
    this storage module have type `string list`. A value of the form
    [page_contents] refers to a page of a slot that has been confirmed, and
    whose contents are [page_contents].
*)
module Dal_slot_pages :
  Store_sigs.Nested_map
    with type primary_key := Block_hash.t
     and type secondary_key := Dal.Slot_index.t * Dal.Page.Index.t
     and type value := Dal.Page.content
     and type 'a store := 'a store

(** [Dal_processed_slots] is a [Store_utils.Nested_map] used to store the processing
    status of dal slots content fetched by the rollup node. The values of
    this storage module have type `[`Confirmed | `Unconfirmed]`, depending on
    whether the content of the slot has been confirmed or not. If an entry is
    not present for a [(block_hash, slot_index)], this either means that it's
    not processed yet.
*)
module Dal_processed_slots :
  Store_sigs.Nested_map
    with type primary_key := Block_hash.t
     and type secondary_key := Dal.Slot_index.t
     and type value := [`Confirmed | `Unconfirmed]
     and type 'a store := 'a store
