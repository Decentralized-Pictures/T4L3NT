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

module Commitment = struct
  (* DAL/FIXME https://gitlab.com/tezos/tezos/-/issues/3389

     It is not clear whether the size of the slot associated to the
     commitment should be given here. *)
  type t = Dal.commitment

  let equal = Dal.Commitment.equal

  let encoding = Dal.Commitment.encoding

  let pp ppf commitment =
    Format.fprintf ppf "%s" (Dal.Commitment.to_b58check commitment)

  let zero = Dal.Commitment.zero
end

module Index = struct
  type t = int

  let max_value = 255

  let encoding = Data_encoding.uint8

  let pp = Format.pp_print_int

  let zero = 0

  let of_int slot_index =
    if Compare.Int.(slot_index <= max_value && slot_index >= zero) then
      Some slot_index
    else None

  let to_int slot_index = slot_index [@@ocaml.inline always]

  let compare = Compare.Int.compare

  let equal = Compare.Int.equal
end

module Header = struct
  type id = {published_level : Raw_level_repr.t; index : Index.t}

  type t = {id : id; commitment : Commitment.t}

  let slot_id_equal ({published_level; index} : id) s2 =
    Raw_level_repr.equal published_level s2.published_level
    && Index.equal index s2.index

  let equal {id; commitment} s2 =
    slot_id_equal id s2.id && Commitment.equal commitment s2.commitment

  let compare_slot_id {published_level; index} s2 =
    let c = Raw_level_repr.compare published_level s2.published_level in
    if Compare.Int.(c <> 0) then c else Index.compare index s2.index

  let zero_id =
    {
      (* We don't expect to have any published slot at level
         Raw_level_repr.root. *)
      published_level = Raw_level_repr.root;
      index = Index.zero;
    }

  let zero = {id = zero_id; commitment = Commitment.zero}

  let encoding =
    let open Data_encoding in
    conv
      (fun {id = {published_level; index}; commitment} ->
        (published_level, index, commitment))
      (fun (published_level, index, commitment) ->
        {id = {published_level; index}; commitment})
      (obj3
         (req "level" Raw_level_repr.encoding)
         (req "index" Data_encoding.uint8)
         (req "commitment" Commitment.encoding))

  let pp fmt {id = {published_level; index}; commitment} =
    Format.fprintf
      fmt
      "published_level: %a index: %a commitment: %a"
      Raw_level_repr.pp
      published_level
      Format.pp_print_int
      index
      Commitment.pp
      commitment
end

module Slot_index = Index

module Page = struct
  type content = Bytes.t

  type slot_index = Index.t

  module Index = struct
    type t = int

    let zero = 0

    let encoding = Data_encoding.int16

    let pp = Format.pp_print_int

    let compare = Compare.Int.compare

    let equal = Compare.Int.equal
  end

  type t = {slot_id : Header.id; page_index : Index.t}

  type proof = Dal.page_proof

  let encoding =
    let open Data_encoding in
    conv
      (fun {slot_id = {published_level; index}; page_index} ->
        (published_level, index, page_index))
      (fun (published_level, index, page_index) ->
        {slot_id = {published_level; index}; page_index})
      (obj3
         (req "published_level" Raw_level_repr.encoding)
         (req "slot_index" Slot_index.encoding)
         (req "page_index" Index.encoding))

  let equal {slot_id; page_index} p =
    Header.slot_id_equal slot_id p.slot_id
    && Index.equal page_index p.page_index

  let proof_encoding = Dal.page_proof_encoding

  let content_encoding = Data_encoding.bytes

  let pp fmt {slot_id = {published_level; index}; page_index} =
    Format.fprintf
      fmt
      "(published_level: %a, slot_index: %a, page_index: %a)"
      Raw_level_repr.pp
      published_level
      Slot_index.pp
      index
      Index.pp
      page_index

  let pp_proof fmt proof =
    Data_encoding.Json.pp
      fmt
      (Data_encoding.Json.construct proof_encoding proof)
end

module Slot_market = struct
  (* DAL/FIXME https://gitlab.com/tezos/tezos/-/issues/3108

     Think harder about this data structure and whether it can be
     optimized. *)

  module Slot_index_map = Map.Make (Index)

  type t = {length : int; slot_headers : Header.t Slot_index_map.t}

  let init ~length =
    if Compare.Int.(length < 0) then
      invalid_arg "Dal_slot_repr.Slot_market.init: length cannot be negative" ;
    let slot_headers = Slot_index_map.empty in
    {length; slot_headers}

  let length {length; _} = length

  let register t new_slot_header =
    let open Header in
    if
      not
        Compare.Int.(
          0 <= new_slot_header.id.index && new_slot_header.id.index < t.length)
    then None
    else
      let has_changed = ref false in
      let update = function
        | None ->
            has_changed := true ;
            Some new_slot_header
        | Some x -> Some x
      in
      let slot_headers =
        Slot_index_map.update new_slot_header.id.index update t.slot_headers
      in
      let t = {t with slot_headers} in
      Some (t, !has_changed)

  let candidates t =
    t.slot_headers |> Slot_index_map.to_seq |> Seq.map snd |> List.of_seq
end

module History = struct
  (* History is represented via a skip list. The content of the cell
     is the hash of a merkle proof. *)

  (* A leaf of the merkle tree is a slot. *)
  module Leaf = struct
    type t = Header.t

    let to_bytes = Data_encoding.Binary.to_bytes_exn Header.encoding
  end

  module Content_prefix = struct
    let _prefix = "dash1"

    (* 32 *)
    let b58check_prefix = "\002\224\072\094\219" (* dash1(55) *)

    let size = Some 32

    let name = "dal_skip_list_content"

    let title = "A hash to represent the content of a cell in the skip list"
  end

  module Content_hash = Blake2B.Make (Base58) (Content_prefix)
  module Merkle_list = Merkle_list.Make (Leaf) (Content_hash)

  (* Pointers of the skip lists are used to encode the content and the
     backpointers. *)
  module Pointer_prefix = struct
    let _prefix = "dask1"

    (* 32 *)
    let b58check_prefix = "\002\224\072\115\035" (* dask1(55) *)

    let size = Some 32

    let name = "dal_skip_list_pointer"

    let title = "A hash that represents the skip list pointers"
  end

  module Pointer_hash = Blake2B.Make (Base58) (Pointer_prefix)

  module Skip_list_parameters = struct
    let basis = 2
  end

  type error += Add_element_in_slots_skip_list_violates_ordering

  let () =
    register_error_kind
      `Temporary
      ~id:"Dal_slot_repr.add_element_in_slots_skip_list_violates_ordering"
      ~title:"Add an element in slots skip list that violates ordering"
      ~description:
        "Attempting to add an element on top of the Dal confirmed slots skip \
         list that violates the ordering."
      Data_encoding.unit
      (function
        | Add_element_in_slots_skip_list_violates_ordering -> Some ()
        | _ -> None)
      (fun () -> Add_element_in_slots_skip_list_violates_ordering)

  module Skip_list = struct
    include Skip_list_repr.Make (Skip_list_parameters)

    (** All confirmed DAL slots will be stored in a skip list, where only the
        last cell is remembered in the L1 context. The skip list is used in
        the proof phase of a refutation game to verify whether a given slot
        exists (i.e., confirmed) or not in the skip list. The skip list is
        supposed to be sorted, as its 'search' function explicitly uses a given
        `compare` function during the list traversal to quickly (in log(size))
        reach the target if any.

        In our case, we will store one slot per cell in the skip list and
        maintain that the list is well sorted (and without redundancy) w.r.t.
        the [compare_slot_id] function.

        Below, we redefine the [next] function (that allows adding elements
        on top of the list) to enforce that the constructed skip list is
        well-sorted. We also define a wrapper around the search function to
        guarantee that it can only be called with the adequate compare function.
    *)

    let compare = Header.compare_slot_id

    let compare_lwt a b = Lwt.return @@ compare a b

    let next ~prev_cell ~prev_cell_ptr elt =
      let open Tzresult_syntax in
      let* () =
        error_when
          (Compare.Int.( <= )
             (compare elt.Header.id (content prev_cell).Header.id)
             0)
          Add_element_in_slots_skip_list_violates_ordering
      in
      return @@ next ~prev_cell ~prev_cell_ptr elt

    let search ~deref ~cell ~target_id =
      search ~deref ~cell ~compare:(fun slot ->
          compare_lwt slot.Header.id target_id)
  end

  module V1 = struct
    (* The content of a cell is the hash of all the slot commitments
       represented as a merkle list. *)
    (* TODO/DAL: https://gitlab.com/tezos/tezos/-/issues/3765
       Decide how to store attested slots in the skip list's content. *)
    type content = Header.t

    (* A pointer to a cell is the hash of its content and all the back
       pointers. *)
    type ptr = Pointer_hash.t

    type history = (content, ptr) Skip_list.cell

    type t = history

    let history_encoding =
      Skip_list.encoding Pointer_hash.encoding Header.encoding

    let equal_history : history -> history -> bool =
      Skip_list.equal Pointer_hash.equal Header.equal

    let encoding = history_encoding

    let equal : t -> t -> bool = equal_history

    let genesis : t = Skip_list.genesis Header.zero

    let hash_skip_list_cell cell =
      let current_slot = Skip_list.content cell in
      let back_pointers_hashes = Skip_list.back_pointers cell in
      Data_encoding.Binary.to_bytes_exn Header.encoding current_slot
      :: List.map Pointer_hash.to_bytes back_pointers_hashes
      |> Pointer_hash.hash_bytes

    let pp_history fmt (history : history) =
      let history_hash = hash_skip_list_cell history in
      Format.fprintf
        fmt
        "@[hash : %a@;%a@]"
        Pointer_hash.pp
        history_hash
        (Skip_list.pp ~pp_content:Header.pp ~pp_ptr:Pointer_hash.pp)
        history

    module History_cache =
      Bounded_history_repr.Make
        (struct
          let name = "dal_slots_cache"
        end)
        (Pointer_hash)
        (struct
          type t = history

          let encoding = history_encoding

          let pp = pp_history

          let equal = equal_history
        end)

    let add_confirmed_slot_header (t, cache) slot_header =
      let open Tzresult_syntax in
      let prev_cell_ptr = hash_skip_list_cell t in
      let* cache = History_cache.remember prev_cell_ptr t cache in
      let* new_cell = Skip_list.next ~prev_cell:t ~prev_cell_ptr slot_header in
      return (new_cell, cache)

    let add_confirmed_slot_headers (t : t) cache slot_headers =
      List.fold_left_e add_confirmed_slot_header (t, cache) slot_headers

    let add_confirmed_slot_headers_no_cache =
      let no_cache = History_cache.empty ~capacity:0L in
      fun t slots ->
        List.fold_left_e add_confirmed_slot_header (t, no_cache) slots >|? fst

    (* Dal proofs section *)

    (** An inclusion proof, for a page ID, is a list of the slots' history
        skip list's cells that encodes a minimal path:
        - from a starting cell, which serves as a reference. It is usually called
        'snapshot' below,
        - to a final cell, that is either the exact target cell in case the slot
         of the page is confirmed, or a cell whose slot ID is the smallest
         that directly follows the page's slot id, in case the target slot
         is not confirmed.

         Using the starting cell as a trustable starting point (i.e. maintained
         and provided by L1), and combined with the extra information stored in
         the {!proof} type below, one can verify if a slot (and then a page of
         that slot) is confirmed on L1 or not. *)
    type inclusion_proof = history list

    (** (See the documentation in the mli file to understand what we want to
        prove in game refutation involving Dal and why.)

        A Dal proof is an algebraic datatype with two cases, where we basically
        prove that a Dal page is confirmed on L1 or not. Being 'not confirmed'
        here includes the case where the slot's header is not published and the
        case where the slot's header is published, but the endorsers didn't
        confirm the availability of its data.

        To produce a proof for a page (see function {!produce_proof} below), we
        assume given:

        - [page_id], identifies the page;

        - [slots_history], a current/recent cell of the slots history skip list.
          Typically, it should be the skip list cell snapshotted when starting the
          refutation game;

       - [history_cache], a sufficiently large slots history cache, to navigate
          back through the successive cells of the skip list. Typically,
          the cache should at least contain the cell whose slot ID is [page_id.slot_id]
          in case the page is confirmed, or the cell whose slot ID is immediately
          after [page_id.slot_id] in case of an unconfirmed page. Indeed,
          inclusion proofs encode paths through skip lists' cells where the head
          is the reference/snapshot cell and the last element is the target slot
          in or the nearest upper slot (w.r.t [page_id]'s slot id and to
          skip list elements ordering) ;

        - [page_info], that provides the page's information (the content and
          the slot membership proof) for page_id. In case the page is supposed
          to be confirmed, this argument should contain the page's content and
          the proof that the page is part of the (confirmed) slot whose ID is
          given in [page_id]. In case we want to show that the page is not confirmed,
          the value [page_info] should be [None].

      [dal_parameters] is used when verifying that/if the page is part of
      the candidate slot (if any).


*)
    type proof =
      | Page_confirmed of {
          target_cell : history;
              (** [target_cell] is a cell whose content contains the slot to
                  which the page belongs to. *)
          inc_proof : inclusion_proof;
              (** [inc_proof] is a (minimal) path in the skip list that proves
                  cells inclusion. The head of the list is the [slots_history]
                  provided to produce the proof. The last cell's content is
                  the slot containing the page identified by [page_id],
                  that is: [target_cell]. *)
          page_data : Page.content;
              (** [page_data] is the content of the page. *)
          page_proof : Page.proof;
              (** [page_proof] is the proof that the page whose content is
                  [page_data] is actually the [page_id.page_index]th page of
                  the slot stored in [target_cell] and identified by
                  page_id.slot_id. *)
        }  (** The case where the slot's page is confirmed/attested on L1. *)
      | Page_unconfirmed of {
          prev_cell : history;
              (** [prev_cell] is the cell of the skip list containing a
                  (confirmed) slot, and whose ID is the biggest (w.r.t. to skip
                  list elements ordering), but smaller than [page_id.slot_id]. *)
          next_cell_opt : history option;
              (** [next_cell_opt] is the cell that immediately follows [prev_cell]
                  in the skip list, if [prev_cell] is not the latest element in
                  the list. Otherwise, it's set to [None]. *)
          next_inc_proof : inclusion_proof;
              (** [inc_proof] is a (minimal) path in the skip list that proves
                  cells inclusion. In case, [next_cell_opt] contains some cell
                  'next_cell', the head of the list is the [slots_history]
                  provided to produce the proof, and the last cell is
                  'next_cell'. In case [next_cell_opt] is [None], the list is
                  empty.

                  We maintain the following invariant in case the inclusion
                  proof is not empty:
                  ```
                   (content next_cell).id > page_id.slot_id > (content prev_cell).id AND
                   hash prev_cell = back_pointer next_cell 0 AND
                   Some next_cell = next_cell_opt AND
                   head next_inc_proof = slots_history
                  ```

                  Said differently, `next_cell` and `prev_cell` are two consecutive
                  cells of the skip list whose contents' IDs surround the page's
                  slot ID. Moreover, the head of the list should be equal to
                  the initial (snapshotted) slots_history skip list.

                  The case of an empty inclusion proof happens when the inputs
                  are such that: `page_id.slot_id > (content slots_history).id`.
                  The returned proof statement implies the following property in this case:

                  ```
                  next_cell_opt = None AND prev_cell = slots_history
                  ```
              *)
        }
          (** The case where the slot's page doesn't exist or is not
              confirmed on L1. *)

    let proof_encoding =
      let open Data_encoding in
      let case_page_confirmed =
        case
          ~title:"confirmed dal page proof"
          (Tag 0)
          (obj5
             (req "kind" (constant "confirmed"))
             (req "target_cell" history_encoding)
             (req "inc_proof" (list history_encoding))
             (req "page_data" bytes)
             (req "page_proof" Page.proof_encoding))
          (function
            | Page_confirmed {target_cell; inc_proof; page_data; page_proof} ->
                Some ((), target_cell, inc_proof, page_data, page_proof)
            | _ -> None)
          (fun ((), target_cell, inc_proof, page_data, page_proof) ->
            Page_confirmed {target_cell; inc_proof; page_data; page_proof})
      and case_page_unconfirmed =
        case
          ~title:"unconfirmed dal page proof"
          (Tag 1)
          (obj4
             (req "kind" (constant "unconfirmed"))
             (req "prev_cell" history_encoding)
             (req "next_cell_opt" (option history_encoding))
             (req "next_inc_proof" (list history_encoding)))
          (function
            | Page_unconfirmed {prev_cell; next_cell_opt; next_inc_proof} ->
                Some ((), prev_cell, next_cell_opt, next_inc_proof)
            | _ -> None)
          (fun ((), prev_cell, next_cell_opt, next_inc_proof) ->
            Page_unconfirmed {prev_cell; next_cell_opt; next_inc_proof})
      in

      union [case_page_confirmed; case_page_unconfirmed]

    let pp_inclusion_proof = Format.pp_print_list pp_history

    let pp_history_opt = Format.pp_print_option pp_history

    let pp_proof fmt p =
      match p with
      | Page_confirmed {target_cell; inc_proof; page_data; page_proof} ->
          Format.fprintf
            fmt
            "Page_confirmed (target_cell=%a, data=%s,@ inc_proof:[size=%d |@ \
             path=%a]@ page_proof:%a)"
            pp_history
            target_cell
            (Bytes.to_string page_data)
            (List.length inc_proof)
            pp_inclusion_proof
            inc_proof
            Page.pp_proof
            page_proof
      | Page_unconfirmed {prev_cell; next_cell_opt; next_inc_proof} ->
          Format.fprintf
            fmt
            "Page_unconfirmed (prev_cell = %a | next_cell = %a | \
             prev_inc_proof:[size=%d@ | path=%a])"
            pp_history
            prev_cell
            pp_history_opt
            next_cell_opt
            (List.length next_inc_proof)
            pp_inclusion_proof
            next_inc_proof

    type dal_parameters = Dal.parameters = {
      redundancy_factor : int;
      page_size : int;
      slot_size : int;
      number_of_shards : int;
    }

    let dal_parameters_encoding = Dal.parameters_encoding

    type error += Dal_proof_error of string

    let () =
      let open Data_encoding in
      register_error_kind
        `Permanent
        ~id:"dal_slot_repr.slots_history.dal_proof_error"
        ~title:"Dal proof error"
        ~description:"Error occurred during Dal proof production or validation"
        ~pp:(fun ppf e -> Format.fprintf ppf "Dal proof error: %s" e)
        (obj1 (req "error" string))
        (function Dal_proof_error e -> Some e | _ -> None)
        (fun e -> Dal_proof_error e)

    let dal_proof_error reason = Dal_proof_error reason

    let proof_error reason = fail @@ dal_proof_error reason

    let check_page_proof dal_params proof data pid commitment =
      let open Lwt_tzresult_syntax in
      let* dal =
        match Dal.make dal_params with
        | Ok dal -> return dal
        | Error (`Fail s) -> proof_error s
      in
      let page = {Dal.content = data; index = pid.Page.page_index} in
      let fail_with_error_msg what =
        Format.kasprintf
          proof_error
          "%s (page data=%s, page id=%a, commitment=%a)."
          what
          (Bytes.to_string data)
          Page.pp
          pid
          Commitment.pp
          commitment
      in
      match Dal.verify_page dal commitment page proof with
      | Ok true -> return ()
      | Ok false ->
          fail_with_error_msg
            "Wrong page content for the given page index and slot commitment"
      | Error `Segment_index_out_of_range ->
          fail_with_error_msg "Segment_index_out_of_range"
      | Error (`Degree_exceeds_srs_length s) ->
          fail_with_error_msg
          @@ Format.sprintf "Degree_exceeds_srs_length: %s" s

    let produce_proof dal_params page_id ~page_info slots_hist hist_cache =
      let open Lwt_tzresult_syntax in
      let Page.{slot_id; page_index = _} = page_id in
      let deref ptr = History_cache.find ptr hist_cache in
      (* We search for a slot whose ID is equal to target_id. *)
      let*! search_result =
        Skip_list.search ~deref ~target_id:slot_id ~cell:slots_hist
      in
      match (page_info, search_result.Skip_list.last_cell) with
      | _, Deref_returned_none ->
          proof_error
            "Skip_list.search returned 'Deref_returned_none': Slots history \
             cache is ill-formed or has too few entries."
      | _, No_exact_or_lower_ptr ->
          proof_error
            "Skip_list.search returned 'No_exact_or_lower_ptr', while it is \
             initialized with a min elt (slot zero)."
      | Some (page_data, page_proof), Found target_cell ->
          (* The slot to which the page is supposed to belong is found. *)
          let Header.{id; commitment} = Skip_list.content target_cell in
          (* We check that the slot is not the dummy slot. *)
          let* () =
            fail_when
              Compare.Int.(Header.compare_slot_id id Header.zero.id = 0)
              (dal_proof_error
                 "Skip_list.search returned 'Found <zero_slot>': No existence \
                  proof should be constructed with the slot zero.")
          in
          let* () =
            check_page_proof dal_params page_proof page_data page_id commitment
          in
          let inc_proof = List.rev search_result.Skip_list.rev_path in
          let* () =
            fail_when
              (List.is_empty inc_proof)
              (dal_proof_error "The inclusion proof cannot be empty")
          in
          (* All checks succeeded. We return a `Page_confirmed` proof. *)
          let status =
            Page_confirmed {inc_proof; target_cell; page_data; page_proof}
          in
          return (status, Some page_data)
      | None, Nearest {lower = prev_cell; upper = next_cell_opt} ->
          (* There is no previously confirmed slot in the skip list whose ID
             corresponds to the {published_level; slot_index} information
             given in [page_id]. But, `search` returned a skip list [prev_cell]
             (and possibly [next_cell_opt]) such that:
             - the ID of [prev_cell]'s slot is the biggest immediately smaller than
               the page's information {published_level; slot_index}
             - if not equal to [None], the ID of [next_cell_opt]'s slot is the smallest
               immediately bigger than the page's slot id `slot_id`.
             - if [next_cell_opt] is [None] then, [prev_cell] should be equal to
               the given history_proof cell. *)
          let* next_inc_proof =
            match search_result.Skip_list.rev_path with
            | [] -> assert false (* Not reachable *)
            | prev :: rev_next_inc_proof ->
                let* () =
                  fail_unless
                    (equal_history prev prev_cell)
                    (dal_proof_error
                       "Internal error: search's Nearest result is \
                        inconsistent.")
                in
                return @@ List.rev rev_next_inc_proof
          in
          return
            (Page_unconfirmed {prev_cell; next_cell_opt; next_inc_proof}, None)
      | None, Found _ ->
          proof_error
            "The page ID's slot is confirmed, but no page content and proof \
             are provided."
      | Some _, Nearest _ ->
          proof_error
            "The page ID's slot is not confirmed, but page content and proof \
             are provided."

    (* Given a starting cell [snapshot] and a (final) [target], this function
       checks that the provided [inc_proof] encodes a minimal path from
       [snapshot] to [target]. *)
    let verify_inclusion_proof inc_proof ~src:snapshot ~dest:target =
      let assoc = List.map (fun c -> (hash_skip_list_cell c, c)) inc_proof in
      let path = List.split assoc |> fst in
      let deref =
        let open Map.Make (Pointer_hash) in
        let map = of_seq (List.to_seq assoc) in
        fun ptr -> find_opt ptr map
      in
      let snapshot_ptr = hash_skip_list_cell snapshot in
      let target_ptr = hash_skip_list_cell target in
      fail_unless
        (Skip_list.valid_back_path
           ~equal_ptr:Pointer_hash.equal
           ~deref
           ~cell_ptr:snapshot_ptr
           ~target_ptr
           path)
        (dal_proof_error "verify_proof: invalid inclusion Dal proof.")

    let verify_proof dal_params page_id snapshot proof =
      let open Lwt_tzresult_syntax in
      let Page.{slot_id; page_index = _} = page_id in
      match proof with
      | Page_confirmed {target_cell; page_data; page_proof; inc_proof} ->
          (* If the page is supposed to be confirmed, the last cell in
             [inc_proof] should store the slot of the page. *)
          let Header.{id; commitment} = Skip_list.content target_cell in
          let* () =
            fail_when
              Compare.Int.(Header.compare_slot_id id Header.zero.id = 0)
              (dal_proof_error
                 "verify_proof: cannot construct a confirmation page proof \
                  with 'zero' as target slot.")
          in
          let* () =
            verify_inclusion_proof inc_proof ~src:snapshot ~dest:target_cell
          in
          (* We check that the page indeed belongs to the target slot at the
             given page index. *)
          let* () =
            check_page_proof dal_params page_proof page_data page_id commitment
          in
          (* If all checks succeed, we return the data/content of the page. *)
          return_some page_data
      | Page_unconfirmed {prev_cell; next_cell_opt; next_inc_proof} ->
          (* The page's slot is supposed to be unconfirmed. *)
          let ( < ) a b = Compare.Int.(Header.compare_slot_id a b < 0) in
          (* We retrieve the last cell of the inclusion proof to be able to
             call {!verify_inclusion_proof}. We also do some well-formedness on
             the shape of the inclusion proof (see the case [Page_unconfirmed]
             of type {!proof}). *)
          let* () =
            match next_cell_opt with
            | None ->
                let* () =
                  fail_unless
                    (List.is_empty next_inc_proof)
                    (dal_proof_error "verify_proof: invalid next_inc_proof")
                in
                (* In case the inclusion proof has no elements, we check that:
                   - the prev_cell slot's id is smaller than the unconfirmed slot's ID
                   - the snapshot is equal to the [prev_cell] skip list.

                   This way, and since the skip list is sorted wrt.
                   {!compare_slot_id}, we are sure that the skip list whose head
                   is [snapshot] = [prev_cell] cannot contain a slot whose ID is
                   [slot_id]. *)
                fail_unless
                  ((Skip_list.content prev_cell).id < slot_id
                  && equal_history snapshot prev_cell)
                  (dal_proof_error "verify_proof: invalid next_inc_proof")
            | Some next_cell ->
                (* In case the inclusion proof has at least one element,
                   we check that:
                   - the [prev_cell] slot's id is smaller than [slot_id]
                   - the [next_cell] slot's id is greater than [slot_id]
                   - the [next_cell] cell is a direct successor of the
                     [prev_cell] cell.
                   - the [next_cell] cell is a predecessor of [snapshot]

                   Since the skip list is sorted wrt. {!compare_slot_id}, and
                   if the call to {!verify_inclusion_proof} succeeds, we are
                   sure that the skip list whose head is [snapshot] cannot
                   contain a slot whose ID is [slot_id]. *)
                let* () =
                  fail_unless
                    ((Skip_list.content prev_cell).id < slot_id
                    && slot_id < (Skip_list.content next_cell).id
                    &&
                    let prev_cell_pointer =
                      Skip_list.back_pointer next_cell 0
                    in
                    match prev_cell_pointer with
                    | None -> false
                    | Some prev_ptr ->
                        Pointer_hash.equal
                          prev_ptr
                          (hash_skip_list_cell prev_cell))
                    (dal_proof_error "verify_proof: invalid next_inc_proof")
                in
                verify_inclusion_proof
                  next_inc_proof
                  ~src:snapshot
                  ~dest:next_cell
          in
          return_none

    module Internal_for_tests = struct
      let content = Skip_list.content

      let proof_statement_is proof expected =
        match (expected, proof) with
        | `Confirmed, Page_confirmed _ | `Unconfirmed, Page_unconfirmed _ ->
            true
        | _ -> false
    end
  end

  include V1
end
