(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Trili Tech  <contact@trili.tech>                       *)
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

(** Testing
    -------
    Component:    Tree_encoding_decoding
    Invocation:   dune exec  src/lib_scoru_wasm/test/test_scoru_wasm.exe \
                    -- test "$Encodings^"
    Subject:      Encoding tests for the tezos-scoru-wasm library
*)

open Tztest
open Tezos_webassembly_interpreter
open Tezos_scoru_wasm

(* Use context-binary for testing. *)
module Context = Tezos_context_memory.Context_binary

module Tree :
  Tezos_context_sigs.Context.TREE
    with type t = Context.t
     and type tree = Context.tree
     and type key = string list
     and type value = bytes = struct
  type t = Context.t

  type tree = Context.tree

  type key = Context.key

  type value = Context.value

  include Context.Tree
end

module Map =
  Lazy_map.Make
    (Lazy_map.Effect.Lwt)
    (struct
      type t = string

      let compare = String.compare

      let to_string x = x
    end)

module Merklizer =
  Tree_encoding_decoding.Make (Map) (Lazy_vector.LwtIntVector) (Tree)

let empty_tree () =
  let open Lwt_syntax in
  let* index = Context.init "/tmp" in
  let empty_store = Context.empty index in
  return @@ Context.Tree.empty empty_store

let test_encode_decode enc value f =
  let open Lwt_result_syntax in
  let*! empty_tree = empty_tree () in
  let*! tree = Merklizer.encode enc value empty_tree in
  let*! value' = Merklizer.decode enc tree in
  f value'

let encode_decode enc value = test_encode_decode enc value Lwt.return

let assert_round_trip enc value equal =
  let open Lwt_syntax in
  let* value' = encode_decode enc value in
  let open Lwt_result_syntax in
  assert (equal value' value) ;
  return_unit

let test_string () =
  let enc = Merklizer.value ["key"] Data_encoding.string in
  assert_round_trip enc "Hello" String.equal

let test_int () =
  let enc = Merklizer.value ["key"] Data_encoding.int32 in
  assert_round_trip enc 42l Int32.equal

let test_tree () =
  let enc =
    Merklizer.scope ["foo"] @@ Merklizer.value ["key"] Data_encoding.int32
  in
  assert_round_trip enc 42l Int32.equal

let test_raw () =
  let enc = Merklizer.raw ["key"] in
  assert_round_trip enc (Bytes.of_string "CAFEBABE") Bytes.equal

let test_conv () =
  let open Merklizer in
  let enc =
    conv int_of_string string_of_int (value ["key"] Data_encoding.string)
  in
  assert_round_trip enc 42 Int.equal

type contact =
  | Email of string
  | Address of {street : string; number : int}
  | No_address

let test_tagged_union () =
  let open Merklizer in
  let open Lwt_result_syntax in
  let enc =
    tagged_union
      (value [] Data_encoding.string)
      [
        case
          "Email"
          (value [] Data_encoding.string)
          (function Email s -> Some s | _ -> None)
          (fun s -> Email s);
        case
          "Address"
          (tup2
             (value ["street"] Data_encoding.string)
             (value ["number"] Data_encoding.int31))
          (function
            | Address {street; number} -> Some (street, number) | _ -> None)
          (fun (street, number) -> Address {street; number});
        case
          "No Address"
          (value [] Data_encoding.unit)
          (function No_address -> Some () | _ -> None)
          (fun () -> No_address);
      ]
  in
  let* () = assert_round_trip enc No_address Stdlib.( = ) in
  let* () = assert_round_trip enc (Email "foo@bar.com") Stdlib.( = ) in
  let* () =
    assert_round_trip
      enc
      (Address {street = "Main Street"; number = 10})
      Stdlib.( = )
  in
  return_unit

let test_lazy_mapping () =
  let open Merklizer in
  let open Lwt_result_syntax in
  let enc = lazy_mapping (value ["key"] Data_encoding.string) in
  let map = Map.create () in
  let key = "key" in
  let value = "value" in
  let map = Map.set key value map in
  (* Load the [key] from the map *)
  let*! value' = Map.get key map in
  assert (value' = value) ;
  let*! decoded_map = encode_decode enc map in
  (* Load the [key] from the decoded map. *)
  let*! value' = Map.get key decoded_map in
  assert (value' = value) ;
  assert (Map.to_string Fun.id map = Map.to_string Fun.id decoded_map) ;
  return_unit

let test_add_to_decoded_empty_map () =
  let open Merklizer in
  let open Lwt_result_syntax in
  let enc = lazy_mapping (value ["key"] Data_encoding.string) in
  let map = Map.create () in
  let*! decoded_map1 = encode_decode enc map in
  let map = Map.set "key" "value" decoded_map1 in
  let*! decoded_map2 = encode_decode enc map in
  let*! value' = Map.get "key" decoded_map2 in
  assert (value' = "value") ;
  return_unit

let test_lazy_vector () =
  let open Merklizer in
  let open Lwt_result_syntax in
  let enc =
    lazy_vector (value [] Data_encoding.int31) (value [] Data_encoding.string)
  in
  let vector = Lazy_vector.LwtIntVector.create 100 in
  (* Load the key [K1] from the vector . *)
  let vector = Lazy_vector.LwtIntVector.set 42 "42" vector in
  let*! value = Lazy_vector.LwtIntVector.get 42 vector in
  assert (value = "42") ;
  let*! decoded_vector = encode_decode enc vector in
  (* Load the key [42] from the decoded vector. *)
  let*! value = Lazy_vector.LwtIntVector.get 42 decoded_vector in
  assert (value = "42") ;
  assert (
    Lazy_vector.LwtIntVector.to_string Fun.id vector
    = Lazy_vector.LwtIntVector.to_string Fun.id decoded_vector) ;
  return_unit

let tests =
  [
    tztest "String" `Quick test_string;
    tztest "Int" `Quick test_int;
    tztest "Tree" `Quick test_tree;
    tztest "Raw" `Quick test_raw;
    tztest "Convert" `Quick test_conv;
    tztest "Tagged-union" `Quick test_tagged_union;
    tztest "Lazy mapping" `Quick test_lazy_mapping;
    tztest
      "Add element to decoded empty map"
      `Quick
      test_add_to_decoded_empty_map;
    tztest "Lazy vector" `Quick test_lazy_vector;
  ]
