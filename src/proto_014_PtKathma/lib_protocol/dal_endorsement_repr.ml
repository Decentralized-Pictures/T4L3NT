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

(* DAL/FIXME https://gitlab.com/tezos/tezos/-/issues/3103

   This may be a bit heavy in practice. We could also assume that in
   practice, this bitfield will contain many bits to one. Hence, we
   could consider a better encoding which is smaller in the optimistic
   case. For example:

   1. When all the slots are endorsed, the encoding can be represented
   in one bit.

   2. Otherwise, we can pack slots by [8]. Have a header of [slots/8]
   which is [1] if all the slots in this set are [1], [0]
   otherwise. For all pack with a bit set to [0], we give the explicit
   representation. Hence, if there are [256] slots, and [2] are not
   endorsed, this representation will be of size [32] bits + [16] bits
   = [48] bits which is better than [256] bits. *)
type t = Bitset.t

type available_slots = t

let encoding = Bitset.encoding

let empty = Bitset.empty

let is_available t index =
  let open Dal_slot_repr.Index in
  match Bitset.mem t (to_int index) with
  | Ok b -> b
  | Error _ ->
      (* DAL/FIXME https://gitlab.com/tezos/tezos/-/issues/3104

         Should we do something here? *)
      false

let commit t index =
  let open Dal_slot_repr.Index in
  match Bitset.add t (to_int index) with
  | Ok t -> t
  | Error _ ->
      (* DAL/FIXME https://gitlab.com/tezos/tezos/-/issues/3104

         Should we do something here? *)
      t

let occupied_size_in_bits = Bitset.occupied_size_in_bits

let expected_size_in_bits ~max_index =
  (* We compute an encoding of the data-availability endorsements
     which is a (tight) upper bound of what we expect. *)
  let open Bitset in
  let open Dal_slot_repr.Index in
  match add empty @@ to_int max_index with
  | Error _ -> (* Happens if max_index < 1 *) 0
  | Ok t -> occupied_size_in_bits t

module Accountability = struct
  (* DAL/FIXME https://gitlab.com/tezos/tezos/-/issues/3109

     Think hard about this data structure and whether it needs to be
     optimized.
  *)
  type t = Bitset.t list

  type shard = int

  let init ~length =
    let l =
      List.init
        ~when_negative_length:
          "Dal_endorsement_repr.Accountability.init: length cannot be negative"
        length
        (fun _ -> Bitset.empty)
    in
    match l with Error msg -> invalid_arg msg | Ok l -> l

  let record_slot_shard_availability bitset shards =
    List.fold_left
      (fun bitset shard ->
        Bitset.add bitset shard |> Result.value ~default:bitset)
      bitset
      shards

  let record_shards_availability shard_bitset_per_slot slots shards =
    List.mapi
      (fun slot bitset ->
        match Bitset.mem slots slot with
        | Error _ ->
            (* slot index is above the length provided at initialisation *)
            bitset
        | Ok slot_available ->
            if slot_available then record_slot_shard_availability bitset shards
            else bitset)
      shard_bitset_per_slot

  let is_slot_available shard_bitset_per_slot ~threshold ~number_of_shards index
      =
    match List.nth shard_bitset_per_slot (Dal_slot_repr.Index.to_int index) with
    | None -> false
    | Some bitset ->
        let acc = ref 0 in
        List.iter
          (fun x ->
            match Bitset.mem bitset x with
            | Error _ | Ok false -> ()
            | Ok true -> incr acc)
          Misc.(0 --> (number_of_shards - 1)) ;
        Compare.Int.(!acc >= threshold * number_of_shards / 100)
end
