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

type kind = Proposal | Testing_vote | Testing | Promotion_vote | Adoption

let string_of_kind = function
  | Proposal ->
      "proposal"
  | Testing_vote ->
      "testing_vote"
  | Testing ->
      "testing"
  | Promotion_vote ->
      "promotion_vote"
  | Adoption ->
      "adoption"

let pp_kind ppf kind = Format.fprintf ppf "%s" @@ string_of_kind kind

let kind_encoding =
  let open Data_encoding in
  union
    ~tag_size:`Uint8
    [ case
        (Tag 0)
        ~title:"Proposal"
        (constant "proposal")
        (function Proposal -> Some () | _ -> None)
        (fun () -> Proposal);
      case
        (Tag 1)
        ~title:"Testing_vote"
        (constant "testing_vote")
        (function Testing_vote -> Some () | _ -> None)
        (fun () -> Testing_vote);
      case
        (Tag 2)
        ~title:"Testing"
        (constant "testing")
        (function Testing -> Some () | _ -> None)
        (fun () -> Testing);
      case
        (Tag 3)
        ~title:"Promotion_vote"
        (constant "promotion_vote")
        (function Promotion_vote -> Some () | _ -> None)
        (fun () -> Promotion_vote);
      case
        (Tag 4)
        ~title:"Adoption"
        (constant "adoption")
        (function Adoption -> Some () | _ -> None)
        (fun () -> Adoption) ]

let succ_kind = function
  | Proposal ->
      Testing_vote
  | Testing_vote ->
      Testing
  | Testing ->
      Promotion_vote
  | Promotion_vote ->
      Adoption
  | Adoption ->
      Proposal

type voting_period = {index : int32; kind : kind; start_position : int32}

type t = voting_period

type info = {voting_period : t; position : int32; remaining : int32}

let root ~start_position = {index = 0l; kind = Proposal; start_position}

let pp ppf {index; kind; start_position} =
  Format.fprintf
    ppf
    "@[<hv 2>index: %ld@ ,kind:%a@, start_position: %ld@]"
    index
    pp_kind
    kind
    start_position

let pp_info ppf {voting_period; position; remaining} =
  Format.fprintf
    ppf
    "@[<hv 2>voting_period: %a@ ,position:%ld@, remaining: %ld@]"
    pp
    voting_period
    position
    remaining

let encoding =
  let open Data_encoding in
  conv
    (fun {index; kind; start_position} -> (index, kind, start_position))
    (fun (index, kind, start_position) -> {index; kind; start_position})
    (obj3
       (req
          "index"
          ~description:
            "The voting period's index. Starts at 0 with the first block of \
             protocol alpha."
          int32)
       (req "kind" kind_encoding)
       (req "start_position" int32))

let info_encoding =
  let open Data_encoding in
  conv
    (fun {voting_period; position; remaining} ->
      (voting_period, position, remaining))
    (fun (voting_period, position, remaining) ->
      {voting_period; position; remaining})
    (obj3
       (req "voting_period" encoding)
       (req "position" int32)
       (req "remaining" int32))

include Compare.Make (struct
  type nonrec t = t

  let compare p p' = Compare.Int32.compare p.index p'.index
end)

let reset period ~start_position =
  let index = Int32.succ period.index in
  let kind = Proposal in
  {index; kind; start_position}

let succ period ~start_position =
  let index = Int32.succ period.index in
  let kind = succ_kind period.kind in
  {index; kind; start_position}

let position_since (level : Level_repr.t) (voting_period : t) =
  Int32.(sub level.level_position voting_period.start_position)

let remaining_blocks (level : Level_repr.t) (voting_period : t)
    ~blocks_per_voting_period =
  let position = position_since level voting_period in
  Int32.(sub blocks_per_voting_period (succ position))
