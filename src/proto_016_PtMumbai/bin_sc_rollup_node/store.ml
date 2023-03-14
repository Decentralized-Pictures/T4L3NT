(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs, <contact@nomadic-labs.com>               *)
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
include Store_sigs
include Store_utils

(** Aggregated collection of messages from the L1 inbox *)
open Alpha_context

module Irmin_store = struct
  module IStore = Irmin_store.Make (struct
    let name = "Tezos smart rollup node"
  end)

  include IStore
  include Store_utils.Make (IStore)
end

module Empty_header = struct
  type t = unit

  let name = "empty"

  let encoding = Data_encoding.unit

  let fixed_size = 0
end

module Add_empty_header = struct
  module Header = Empty_header

  let header _ = ()
end

module Make_hash_index_key (H : Environment.S.HASH) =
Indexed_store.Make_index_key (struct
  include Indexed_store.Make_fixed_encodable (H)

  let equal = H.equal
end)

(** L2 blocks *)
module L2_blocks =
  Indexed_store.Make_indexed_file
    (struct
      let name = "l2_blocks"
    end)
    (Tezos_store_shared.Block_key)
    (struct
      type t = (unit, unit) Sc_rollup_block.block

      let name = "sc_rollup_block_info"

      let encoding =
        Sc_rollup_block.block_encoding Data_encoding.unit Data_encoding.unit

      module Header = struct
        type t = Sc_rollup_block.header

        let name = "sc_rollup_block_header"

        let encoding = Sc_rollup_block.header_encoding

        let fixed_size = Sc_rollup_block.header_size
      end
    end)

(** Unaggregated messages per block *)
module Messages =
  Indexed_store.Make_indexed_file
    (struct
      let name = "messages"
    end)
    (Make_hash_index_key (Sc_rollup.Inbox_merkelized_payload_hashes.Hash))
    (struct
      type t = Sc_rollup.Inbox_message.t list

      let name = "messages_list"

      let encoding =
        Data_encoding.(list @@ dynamic_size Sc_rollup.Inbox_message.encoding)

      module Header = struct
        type t = Block_hash.t * Timestamp.t * int

        let name = "messages_inbox_info"

        let encoding =
          let open Data_encoding in
          obj3
            (req "predecessor" Block_hash.encoding)
            (req "predecessor_timestamp" Timestamp.encoding)
            (req "num_messages" int31)

        let fixed_size =
          WithExceptions.Option.get ~loc:__LOC__
          @@ Data_encoding.Binary.fixed_length encoding
      end
    end)

(** Inbox state for each block *)
module Inboxes =
  Indexed_store.Make_simple_indexed_file
    (struct
      let name = "inboxes"
    end)
    (Make_hash_index_key (Sc_rollup.Inbox.Hash))
    (struct
      type t = Sc_rollup.Inbox.t

      let name = "inbox"

      let encoding = Sc_rollup.Inbox.encoding

      include Add_empty_header
    end)

module Commitments =
  Indexed_store.Make_indexable
    (struct
      let name = "commitments"
    end)
    (Make_hash_index_key (Sc_rollup.Commitment.Hash))
    (Indexed_store.Make_index_value (Indexed_store.Make_fixed_encodable (struct
      include Sc_rollup.Commitment

      let name = "commitment"
    end)))

module Commitments_published_at_level = struct
  type element = {
    first_published_at_level : Raw_level.t;
    published_at_level : Raw_level.t option;
  }

  let element_encoding =
    let open Data_encoding in
    let opt_level_encoding =
      conv
        (function None -> -1l | Some l -> Raw_level.to_int32 l)
        (fun l -> if l = -1l then None else Some (Raw_level.of_int32_exn l))
        Data_encoding.int32
    in
    conv
      (fun {first_published_at_level; published_at_level} ->
        (first_published_at_level, published_at_level))
      (fun (first_published_at_level, published_at_level) ->
        {first_published_at_level; published_at_level})
    @@ obj2
         (req "first_published_at_level" Raw_level.encoding)
         (req "published_at_level" opt_level_encoding)

  include
    Indexed_store.Make_indexable
      (struct
        let name = "commitments"
      end)
      (Make_hash_index_key (Sc_rollup.Commitment.Hash))
      (Indexed_store.Make_index_value (Indexed_store.Make_fixed_encodable (struct
        type t = element

        let name = "published_levels"

        let encoding = element_encoding
      end)))
end

module L2_head = Indexed_store.Make_singleton (struct
  type t = Sc_rollup_block.t

  let name = "l2_head"

  let encoding = Sc_rollup_block.encoding
end)

module Last_finalized_head = Indexed_store.Make_singleton (struct
  type t = Sc_rollup_block.t

  let name = "finalized_head"

  let encoding = Sc_rollup_block.encoding
end)

(** Table from L1 levels to blocks hashes. *)
module Levels_to_hashes =
  Indexed_store.Make_indexable
    (struct
      let name = "tezos_levels"
    end)
    (Indexed_store.Make_index_key (struct
      type t = int32

      let encoding = Data_encoding.int32

      let name = "level"

      let fixed_size = 4

      let equal = Int32.equal
    end))
    (Tezos_store_shared.Block_key)

(* Published slot headers per block hash,
   stored as a list of bindings from `Dal_slot_index.t`
   to `Dal.Slot.t`. The encoding function converts this
   list into a `Dal.Slot_index.t`-indexed map. *)
module Dal_slot_pages =
  Irmin_store.Make_nested_map
    (struct
      let path = ["dal"; "slot_pages"]
    end)
    (struct
      type key = Block_hash.t

      let to_path_representation = Block_hash.to_b58check
    end)
    (struct
      type key = Dal.Slot_index.t * Dal.Page.Index.t

      let encoding =
        Data_encoding.(tup2 Dal.Slot_index.encoding Dal.Page.Index.encoding)

      let compare (i1, p1) (i2, p2) =
        Compare.or_else (Dal.Slot_index.compare i1 i2) (fun () ->
            Dal.Page.Index.compare p1 p2)

      let name = "slot_index"
    end)
    (struct
      type value = Dal.Page.content

      let encoding = Dal.Page.content_encoding

      let name = "slot_pages"
    end)

(** stores slots whose data have been considered and pages stored to disk (if
    they are confirmed). *)
module Dal_processed_slots =
  Irmin_store.Make_nested_map
    (struct
      let path = ["dal"; "processed_slots"]
    end)
    (struct
      type key = Block_hash.t

      let to_path_representation = Block_hash.to_b58check
    end)
    (struct
      type key = Dal.Slot_index.t

      let encoding = Dal.Slot_index.encoding

      let compare = Dal.Slot_index.compare

      let name = "slot_index"
    end)
    (struct
      type value = [`Confirmed | `Unconfirmed]

      let name = "slot_processing_status"

      let encoding =
        let open Data_encoding in
        let mk_case constr ~tag ~title =
          case
            ~title
            (Tag tag)
            (obj1 (req "kind" (constant title)))
            (fun x -> if x = constr then Some () else None)
            (fun () -> constr)
        in
        union
          ~tag_size:`Uint8
          [
            mk_case `Confirmed ~tag:0 ~title:"Confirmed";
            mk_case `Unconfirmed ~tag:1 ~title:"Unconfirmed";
          ]
    end)

module Dal_slots_headers =
  Irmin_store.Make_nested_map
    (struct
      let path = ["dal"; "slot_headers"]
    end)
    (struct
      type key = Block_hash.t

      let to_path_representation = Block_hash.to_b58check
    end)
    (struct
      type key = Dal.Slot_index.t

      let encoding = Dal.Slot_index.encoding

      let compare = Dal.Slot_index.compare

      let name = "slot_index"
    end)
    (struct
      type value = Dal.Slot.Header.t

      let name = "slot_header"

      let encoding = Dal.Slot.Header.encoding
    end)

(* Published slot headers per block hash, stored as a list of bindings from
   `Dal_slot_index.t` to `Dal.Slot.t`. The encoding function converts this
   list into a `Dal.Slot_index.t`-indexed map. Note that the block_hash
   refers to the block where slots headers have been confirmed, not
   the block where they have been published.
*)

(** Confirmed DAL slots history. See documentation of
    {Dal_slot_repr.Slots_history} for more details. *)
module Dal_confirmed_slots_history =
  Irmin_store.Make_append_only_map
    (struct
      let path = ["dal"; "confirmed_slots_history"]
    end)
    (struct
      type key = Block_hash.t

      let to_path_representation = Block_hash.to_b58check
    end)
    (struct
      type value = Dal.Slots_history.t

      let name = "dal_slot_histories"

      let encoding = Dal.Slots_history.encoding
    end)

(** Confirmed DAL slots histories cache. See documentation of
    {Dal_slot_repr.Slots_history} for more details. *)
module Dal_confirmed_slots_histories =
  (* TODO: https://gitlab.com/tezos/tezos/-/issues/4390
     Store single history points in map instead of whole history. *)
    Irmin_store.Make_append_only_map
      (struct
        let path = ["dal"; "confirmed_slots_histories_cache"]
      end)
      (struct
        type key = Block_hash.t

        let to_path_representation = Block_hash.to_b58check
      end)
    (struct
      type value = Dal.Slots_history.History_cache.t

      let name = "dal_slot_history_cache"

      let encoding = Dal.Slots_history.History_cache.encoding
    end)

type 'a store = {
  l2_blocks : 'a L2_blocks.t;
  messages : 'a Messages.t;
  inboxes : 'a Inboxes.t;
  commitments : 'a Commitments.t;
  commitments_published_at_level : 'a Commitments_published_at_level.t;
  l2_head : 'a L2_head.t;
  last_finalized_head : 'a Last_finalized_head.t;
  levels_to_hashes : 'a Levels_to_hashes.t;
  irmin_store : 'a Irmin_store.t;
}

type 'a t = ([< `Read | `Write > `Read] as 'a) store

type rw = Store_sigs.rw t

type ro = Store_sigs.ro t

let readonly
    ({
       l2_blocks;
       messages;
       inboxes;
       commitments;
       commitments_published_at_level;
       l2_head;
       last_finalized_head;
       levels_to_hashes;
       irmin_store;
     } :
      _ t) : ro =
  {
    l2_blocks = L2_blocks.readonly l2_blocks;
    messages = Messages.readonly messages;
    inboxes = Inboxes.readonly inboxes;
    commitments = Commitments.readonly commitments;
    commitments_published_at_level =
      Commitments_published_at_level.readonly commitments_published_at_level;
    l2_head = L2_head.readonly l2_head;
    last_finalized_head = Last_finalized_head.readonly last_finalized_head;
    levels_to_hashes = Levels_to_hashes.readonly levels_to_hashes;
    irmin_store = Irmin_store.readonly irmin_store;
  }

let close
    ({
       l2_blocks;
       messages;
       inboxes;
       commitments;
       commitments_published_at_level;
       l2_head = _;
       last_finalized_head = _;
       levels_to_hashes;
       irmin_store;
     } :
      _ t) =
  let open Lwt_result_syntax in
  let+ () = L2_blocks.close l2_blocks
  and+ () = Messages.close messages
  and+ () = Inboxes.close inboxes
  and+ () = Commitments.close commitments
  and+ () = Commitments_published_at_level.close commitments_published_at_level
  and+ () = Levels_to_hashes.close levels_to_hashes
  and+ () = Irmin_store.close irmin_store |> Lwt_result.ok in
  ()

let load (type a) (mode : a mode) ~l2_blocks_cache_size data_dir :
    a store tzresult Lwt.t =
  let open Lwt_result_syntax in
  let path name = Filename.concat data_dir name in
  let cache_size = l2_blocks_cache_size in
  let* l2_blocks = L2_blocks.load mode ~path:(path "l2_blocks") ~cache_size in
  let* messages = Messages.load mode ~path:(path "messages") ~cache_size in
  let* inboxes = Inboxes.load mode ~path:(path "inboxes") ~cache_size in
  let* commitments = Commitments.load mode ~path:(path "commitments") in
  let* commitments_published_at_level =
    Commitments_published_at_level.load
      mode
      ~path:(path "commitments_published_at_level")
  in
  let* l2_head = L2_head.load mode ~path:(path "l2_head") in
  let* last_finalized_head =
    Last_finalized_head.load mode ~path:(path "last_finalized_head")
  in
  let* levels_to_hashes =
    Levels_to_hashes.load mode ~path:(path "levels_to_hashes")
  in
  let+ irmin_store =
    Irmin_store.load mode (path "irmin_store") |> Lwt_result.ok
  in
  {
    l2_blocks;
    messages;
    inboxes;
    commitments;
    commitments_published_at_level;
    l2_head;
    last_finalized_head;
    levels_to_hashes;
    irmin_store;
  }
