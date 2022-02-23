(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020-2021 Nomadic Labs, <contact@nomadic-labs.com>          *)
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

(* Invariant: a maximum of [max_predecessors] predecessors at all
   time: if a block has fewer than 12 predecessors then it is padded
   so its size remain constant. *)
module Block_info = struct
  type t = {offset : int; predecessors : Block_hash.t list}

  let max_predecessors = 12

  let encoded_list_size =
    let r = max_predecessors * Block_hash.size (* uint16 *) in
    assert (r < 1 lsl 16) ;
    r

  let encoded_size = 8 + 1 + encoded_list_size

  (* Format:
     <file_offset>(8) + <list_size>(1) + <list>(list_size * Block_hash.size) *)

  let t =
    let open Repr in
    map
      (pair int (list ~len:`Int16 Block_key.t))
      (fun (offset, predecessors) -> {offset; predecessors})
      (fun {offset; predecessors} -> (offset, predecessors))

  let encode v =
    let bytes = Bytes.create encoded_size in
    Bytes.set_int64_be bytes 0 (Int64.of_int v.offset) ;
    let len = List.length v.predecessors in
    (* Start reading after the <file_offset>(8) *)
    Bytes.set_int8 bytes 8 len ;
    List.iteri
      (fun i h ->
        (* Start reading after the <file_offset>(8) + <list_lize>(1) *)
        Bytes.blit
          (Block_hash.to_bytes h)
          0
          bytes
          (8 + 1 + (i * Block_hash.size))
          Block_hash.size)
      v.predecessors ;
    Bytes.unsafe_to_string bytes

  let decode str i =
    let current_offset = ref i in
    (* The Int64.to_int conversion is not likely to fail as it was
       written based on Int64.of_int and the encoded offset won't
       reach the int64 max value. *)
    let offset =
      TzEndian.get_int64_string str !current_offset |> Int64.to_int
    in
    (* Setting current_offset right after the <file_offset>(8)*)
    current_offset := !current_offset + 8 ;
    let list_size = TzEndian.get_int8_string str !current_offset in
    current_offset := !current_offset + 1 ;
    let predecessors = ref [] in
    let limit = !current_offset in
    current_offset := limit + ((list_size - 1) * Block_hash.size) ;
    while !current_offset >= limit do
      predecessors :=
        (String.sub str !current_offset Block_hash.size
        |> Block_hash.of_string_exn)
        :: !predecessors ;
      current_offset := !current_offset - Block_hash.size
    done ;
    {offset; predecessors = !predecessors}

  let pp fmt v =
    let open Format in
    fprintf
      fmt
      "@[offset: %d, predecessors : [ @[<hov>%a @]]@]"
      v.offset
      (pp_print_list ~pp_sep:(fun fmt () -> fprintf fmt " ;@,") Block_hash.pp)
      v.predecessors
end

(* Hashmap from block's hashes to location *)
include Index_unix.Make (Block_key) (Block_info) (Index.Cache.Unbounded)
