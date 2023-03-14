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

let split delim ?(limit = max_int) str =
  let len = String.length str in
  let take start finish = String.sub str start (finish - start) in
  let rec mark_delims limit acc = function
    | _ when limit <= 0 -> List.rev acc
    | pos when pos >= len -> List.rev acc
    | pos when str.[pos] = delim ->
        mark_delims (limit - 1) (pos :: acc) (pos + 1)
    | pos -> mark_delims limit acc (pos + 1)
  in
  let rec split_by_index prev acc = function
    | [] -> take prev len :: acc |> List.rev
    | i :: is -> split_by_index (i + 1) (take prev i :: acc) is
  in
  mark_delims limit [] 0 |> split_by_index 0 []

let split_no_empty delim ?(limit = max_int) path =
  let l = String.length path in
  let rec do_slashes acc limit i =
    if i >= l then List.rev acc
    else if path.[i] = delim then do_slashes acc limit (i + 1)
    else do_split acc limit i
  and do_split acc limit i =
    if limit <= 0 then
      if i = l then List.rev acc else List.rev (String.sub path i (l - i) :: acc)
    else do_component acc (pred limit) i i
  and do_component acc limit i j =
    if j >= l then
      if i = j then List.rev acc else List.rev (String.sub path i (j - i) :: acc)
    else if path.[j] = delim then
      do_slashes (String.sub path i (j - i) :: acc) limit j
    else do_component acc limit i (j + 1)
  in
  if limit > 0 then do_slashes [] limit 0 else [path]

let chunk_bytes_strict error_on_partial_chunk n b =
  let l = Bytes.length b in
  if l mod n <> 0 then Error error_on_partial_chunk
  else
    let rec split seq offset =
      if offset = l then List.rev seq
      else
        let s = Bytes.sub_string b offset n in
        split (s :: seq) (offset + n)
    in
    Ok (split [] 0)

let chunk_bytes_loose n b =
  let l = Bytes.length b in
  let rec split seq offset =
    if offset = l then List.rev seq
    else if offset + n > l then
      List.rev (Bytes.sub_string b offset (l - offset) :: seq)
    else
      let s = Bytes.sub_string b offset n in
      split (s :: seq) (offset + n)
  in
  split [] 0

let chunk_bytes ?error_on_partial_chunk n b =
  if n <= 0 then raise @@ Invalid_argument "chunk_bytes"
  else
    match error_on_partial_chunk with
    | Some error_on_partial_chunk ->
        chunk_bytes_strict error_on_partial_chunk n b
    | None -> Ok (chunk_bytes_loose n b)

let has_prefix ~prefix s =
  let x = String.length prefix in
  let n = String.length s in
  n >= x && String.sub s 0 x = prefix

let remove_prefix ~prefix s =
  let x = String.length prefix in
  let n = String.length s in
  if n >= x && String.sub s 0 x = prefix then Some (String.sub s x (n - x))
  else None

let remove_suffix ~suffix s =
  let x = String.length suffix in
  let n = String.length s in
  if String.ends_with s ~suffix then Some (String.sub s 0 (n - x)) else None

let common_prefix s1 s2 =
  let last = min (String.length s1) (String.length s2) in
  let rec loop i =
    if last <= i then last else if s1.[i] = s2.[i] then loop (i + 1) else i
  in
  loop 0

let mem_char s c = String.index_opt s c <> None

let fold_left f init s =
  let acc = ref init in
  String.iter (fun c -> acc := f !acc c) s ;
  !acc

let pp_bytes_hex fmt bytes = Hex.(of_bytes bytes |> pp fmt)
