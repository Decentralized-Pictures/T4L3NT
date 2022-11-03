(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech  <contact@trili.tech>                        *)
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

open QCheck_alcotest
open QCheck2
open Chunked_byte_vector

let create_works =
  Test.make ~name:"create works" Gen.ui64 (fun len ->
      let vector = create len in
      length vector = len)

let to_bytes_works =
  Test.make ~name:"from_bytes to_bytes roundtrip" Gen.string (fun str ->
      let open Lwt.Syntax in
      Lwt_main.run
      @@
      let bytes = Bytes.of_string str in
      let vector = of_bytes bytes in
      let* bytes' = to_bytes vector in
      let vector' = of_bytes bytes' in
      let+ bytes'' = to_bytes vector' in
      bytes = bytes' && bytes = bytes'')

let load_bytes_works_no_offset =
  Test.make
    ~name:"load_bytes without offset"
    (Gen.tup3 Gen.string Gen.nat Gen.nat)
    (fun (str, _offset, num_bytes) ->
      let open Lwt.Syntax in
      Lwt_main.run
      @@
      let bytes = Bytes.of_string str in
      let len = Bytes.length bytes in
      let offset = 0 in
      let num_bytes =
        if len > offset + 1 then num_bytes mod (len - offset - 1) else 0
      in
      let vector = of_bytes bytes in
      let+ bytes' =
        load_bytes vector (Int64.of_int offset) (Int64.of_int num_bytes)
      in
      let expected = Bytes.sub bytes offset num_bytes in
      expected = bytes')

let load_bytes_works =
  Test.make
    ~name:"load_bytes roundtrip"
    (Gen.tup3 Gen.string Gen.nat Gen.nat)
    (fun (str, offset, num_bytes) ->
      let open Lwt.Syntax in
      Lwt_main.run
      @@
      let bytes = Bytes.of_string str in
      let len = Bytes.length bytes in
      let offset = offset mod max 1 len in
      let num_bytes =
        if len > offset + 1 then num_bytes mod (len - offset - 1) else 0
      in
      let vector = of_bytes bytes in
      let+ bytes' =
        load_bytes vector (Int64.of_int offset) (Int64.of_int num_bytes)
      in
      let expected =
        if num_bytes = 0 then Bytes.empty else Bytes.sub bytes offset num_bytes
      in
      expected = bytes')

let store_load_byte_works =
  Test.make ~name:"store_byte and load_byte work" Gen.string (fun str ->
      let open Lwt.Syntax in
      Lwt_main.run
      @@
      let bytes = Bytes.of_string str in
      let len = Int64.of_int (Bytes.length bytes) in
      let vector = create len in
      let* mapping =
        Lwt_list.map_s (fun i ->
            let index = Int64.of_int i in
            let byte = Bytes.get_uint8 bytes i in
            let+ () = store_byte vector index byte in
            (index, byte))
        @@ List.init (Bytes.length bytes) Fun.id
      in
      Lwt_list.for_all_p
        (fun (i, c) ->
          let+ v = load_byte vector i in
          v = c)
        mapping)

let grow_works =
  Test.make
    ~name:"grow works"
    Gen.(pair string small_int)
    (fun (init_str, grow_len) ->
      let open Lwt.Syntax in
      Lwt_main.run
      @@
      let grow_len = Int64.of_int grow_len in
      let vector = of_string init_str in
      let check_contents () =
        Lwt_list.for_all_p (fun i ->
            let index = Int64.of_int i in
            let+ v = load_byte vector index in
            v = Char.code (String.get init_str i))
        @@ List.init (String.length init_str) Fun.id
      in
      let* check1 = check_contents () in
      grow vector grow_len ;
      let+ check2 = check_contents () in
      let check3 =
        Int64.(length vector = add grow_len (of_int (String.length init_str)))
      in
      check1 && check2 && check3)

let can_write_after_grow =
  Test.make
    ~name:"can write after grow"
    Gen.(string_size (101 -- 1_000))
    (fun append_str ->
      let open Lwt.Syntax in
      Lwt_main.run
      @@
      let chunk_size = Chunked_byte_vector.Chunk.size in
      (* We initialize the vector with a string of a size slightly
         under [chunk_size]. This is to be sure that the previous
         value remains accessible after [store_bytes] on the last
         chunk of [vector], that was filled in the process. *)
      let init_size = Int64.(sub chunk_size 100L) in
      let vector =
        of_string (String.make (Int64.to_int chunk_size - 100) 'a')
      in
      let* v = load_byte vector 0L in
      assert (v = Char.code 'a') ;
      grow vector (String.length append_str |> Int64.of_int) ;
      let* () = store_bytes vector init_size @@ Bytes.of_string append_str in
      let* v = load_byte vector 0L in
      assert (v = Char.code 'a') ;
      let* v = load_byte vector init_size in
      assert (v = Char.code (String.get append_str 0)) ;
      let+ v = load_byte vector chunk_size in
      assert (v = Char.code (String.get append_str 100)) ;
      true)

let internal_num_pages_edge_case =
  let test () =
    let open Chunked_byte_vector in
    let open Alcotest in
    check int64 "exact value" 0L (Chunk.num_needed 0L) ;
    check int64 "exact value" 1L (Chunk.num_needed Chunk.size) ;
    check int64 "exact value" 1L (Chunk.num_needed (Int64.pred Chunk.size)) ;
    check int64 "exact value" 2L (Chunk.num_needed (Int64.succ Chunk.size))
  in
  ("internal: num_pages edge case", `Quick, test)

let tests =
  [
    to_alcotest create_works;
    to_alcotest store_load_byte_works;
    to_alcotest grow_works;
    to_alcotest can_write_after_grow;
    to_alcotest load_bytes_works_no_offset;
    to_alcotest to_bytes_works;
    to_alcotest load_bytes_works;
    internal_num_pages_edge_case;
  ]
