(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

open Tezos_webassembly_interpreter

type key = string list

module type S = sig
  type tree

  type 'a map

  type vector_key

  type 'a vector

  type ('tag, 'a) case

  module Decoding : Tree_decoding.S with type tree = tree

  module Encoding : Tree_encoding.S with type tree = tree

  type 'a t

  val encode : 'a t -> 'a -> tree -> tree Lwt.t

  val decode : 'a t -> tree -> 'a Lwt.t

  val custom : 'a Encoding.t -> 'a Decoding.t -> 'a t

  val conv : ('a -> 'b) -> ('b -> 'a) -> 'a t -> 'b t

  val conv_lwt : ('a -> 'b Lwt.t) -> ('b -> 'a Lwt.t) -> 'a t -> 'b t

  val tup2 : 'a t -> 'b t -> ('a * 'b) t

  val tup3 : 'a t -> 'b t -> 'c t -> ('a * 'b * 'c) t

  val raw : key -> bytes t

  val value : key -> 'a Data_encoding.t -> 'a t

  val scope : key -> 'a t -> 'a t

  val lazy_mapping : 'a t -> 'a map t

  val lazy_vector : vector_key t -> 'a t -> 'a vector t

  val case : 'tag -> 'b t -> ('a -> 'b option) -> ('b -> 'a) -> ('tag, 'a) case

  val tagged_union : 'tag t -> ('tag, 'a) case list -> 'a t
end

module Make
    (M : Lazy_map.S with type 'a effect = 'a Lwt.t)
    (V : Lazy_vector.S with type 'a effect = 'a Lwt.t)
    (T : Tree.S) :
  S
    with type tree = T.tree
     and type 'a map = 'a M.t
     and type vector_key = V.key
     and type 'a vector = 'a V.t = struct
  module Encoding = Tree_encoding.Make (T)
  module Decoding = Tree_decoding.Make (T)
  module E = Encoding
  module D = Decoding

  type tree = T.tree

  type vector_key = V.key

  type 'a vector = 'a V.t

  type 'a map = 'a M.t

  type 'a encoding = 'a E.t

  type 'a decoding = 'a D.t

  type 'a t = {encode : 'a encoding; decode : 'a decoding}

  let custom encode decode = {encode; decode}

  let conv d e {encode; decode} =
    {encode = E.contramap e encode; decode = D.map d decode}

  let conv_lwt d e {encode; decode} =
    {encode = E.contramap_lwt e encode; decode = D.map_lwt d decode}

  let tup2 lhs rhs =
    {
      encode = E.tup2 lhs.encode rhs.encode;
      decode = D.Syntax.both lhs.decode rhs.decode;
    }

  let tup3 one two three =
    conv
      (fun (a, (b, c)) -> (a, b, c))
      (fun (a, b, c) -> (a, (b, c)))
      (tup2 one (tup2 two three))

  let encode {encode; _} value tree = E.run encode value tree

  let decode {decode; _} tree = D.run decode tree

  let raw key = {encode = E.raw key; decode = D.raw key}

  let value key de = {encode = E.value key de; decode = D.value key de}

  let scope key {encode; decode} =
    {encode = E.scope key encode; decode = D.scope key decode}

  let lazy_mapping value =
    let to_key k = [M.string_of_key k] in
    let encode =
      E.contramap M.loaded_bindings (E.lazy_mapping to_key value.encode)
    in
    let decode =
      D.map
        (fun produce_value -> M.create ~produce_value ())
        (D.lazy_mapping to_key value.decode)
    in
    {encode; decode}

  let lazy_vector with_key value =
    let to_key k = [V.string_of_key k] in
    let encode =
      E.contramap
        (fun vector ->
          (V.loaded_bindings vector, V.num_elements vector, V.first_key vector))
        (E.tup3
           (E.lazy_mapping to_key value.encode)
           (E.scope ["length"] with_key.encode)
           (E.scope ["head"] with_key.encode))
    in
    let decode =
      D.map
        (fun (produce_value, len, head) ->
          V.create ~produce_value ~first_key:head len)
        (let open D.Syntax in
        let+ x = D.lazy_mapping to_key value.decode
        and+ y = D.scope ["length"] with_key.decode
        and+ z = D.scope ["head"] with_key.decode in
        (x, y, z))
    in
    {encode; decode}

  type ('tag, 'a) case =
    | Case : {
        tag : 'tag;
        probe : 'a -> 'b option;
        extract : 'b -> 'a;
        delegate : 'b t;
      }
        -> ('tag, 'a) case

  let case tag delegate probe extract = Case {tag; delegate; probe; extract}

  let tagged_union {encode; decode} cases =
    let to_encode_case (Case {tag; delegate; probe; extract = _}) =
      E.case tag delegate.encode probe
    in
    let to_decode_case (Case {tag; delegate; extract; probe = _}) =
      D.case tag delegate.decode extract
    in
    let encode = E.tagged_union encode (List.map to_encode_case cases) in
    let decode = D.tagged_union decode (List.map to_decode_case cases) in
    {encode; decode}
end
