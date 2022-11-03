(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

open Tezos_lazy_containers
include Tree

exception Uninitialized_self_ref

type key = string list

module E = Encoding
module D = Decoding

type 'a encoding = 'a E.t

type 'a decoding = 'a D.t

type 'a t = {encode : 'a encoding; decode : 'a decoding}

let return x = {encode = E.ignore; decode = D.Syntax.return x}

let conv d e {encode; decode} =
  {encode = E.contramap e encode; decode = D.map d decode}

let conv_lwt d e {encode; decode} =
  {encode = E.contramap_lwt e encode; decode = D.map_lwt d decode}

let scope key {encode; decode} =
  {encode = E.scope key encode; decode = D.scope key decode}

let tup2_ a b =
  {encode = E.tup2 a.encode b.encode; decode = D.Syntax.both a.decode b.decode}

let tup3_ a b c =
  conv
    (fun (a, (b, c)) -> (a, b, c))
    (fun (a, b, c) -> (a, (b, c)))
    (tup2_ a (tup2_ b c))

let tup4_ a b c d =
  conv
    (fun (a, (b, c, d)) -> (a, b, c, d))
    (fun (a, b, c, d) -> (a, (b, c, d)))
    (tup2_ a (tup3_ b c d))

let tup5_ a b c d e =
  conv
    (fun (a, (b, c, d, e)) -> (a, b, c, d, e))
    (fun (a, b, c, d, e) -> (a, (b, c, d, e)))
    (tup2_ a (tup4_ b c d e))

let tup6_ a b c d e f =
  conv
    (fun (a, (b, c, d, e, f)) -> (a, b, c, d, e, f))
    (fun (a, b, c, d, e, f) -> (a, (b, c, d, e, f)))
    (tup2_ a (tup5_ b c d e f))

let tup7_ a b c d e f g =
  conv
    (fun (a, (b, c, d, e, f, g)) -> (a, b, c, d, e, f, g))
    (fun (a, b, c, d, e, f, g) -> (a, (b, c, d, e, f, g)))
    (tup2_ a (tup6_ b c d e f g))

let tup8_ a b c d e f g h =
  conv
    (fun (a, (b, c, d, e, f, g, h)) -> (a, b, c, d, e, f, g, h))
    (fun (a, b, c, d, e, f, g, h) -> (a, (b, c, d, e, f, g, h)))
    (tup2_ a (tup7_ b c d e f g h))

let tup9_ a b c d e f g h i =
  conv
    (fun (a, (b, c, d, e, f, g, h, i)) -> (a, b, c, d, e, f, g, h, i))
    (fun (a, b, c, d, e, f, g, h, i) -> (a, (b, c, d, e, f, g, h, i)))
    (tup2_ a (tup8_ b c d e f g h i))

(* This is to allow for either flat composition of tuples or  where each
   element of the tuple is wrapped under an index node. *)
let flat_or_wrap ~flatten ix enc =
  if flatten then enc else scope [string_of_int ix] enc

let tup2 ~flatten a b =
  tup2_ (flat_or_wrap ~flatten 1 a) (flat_or_wrap ~flatten 2 b)

let tup3 ~flatten a b c =
  tup3_
    (flat_or_wrap ~flatten 1 a)
    (flat_or_wrap ~flatten 2 b)
    (flat_or_wrap ~flatten 3 c)

let tup4 ~flatten a b c d =
  tup4_
    (flat_or_wrap ~flatten 1 a)
    (flat_or_wrap ~flatten 2 b)
    (flat_or_wrap ~flatten 3 c)
    (flat_or_wrap ~flatten 4 d)

let tup5 ~flatten a b c d e =
  tup5_
    (flat_or_wrap ~flatten 1 a)
    (flat_or_wrap ~flatten 2 b)
    (flat_or_wrap ~flatten 3 c)
    (flat_or_wrap ~flatten 4 d)
    (flat_or_wrap ~flatten 5 e)

let tup6 ~flatten a b c d e f =
  tup6_
    (flat_or_wrap ~flatten 1 a)
    (flat_or_wrap ~flatten 2 b)
    (flat_or_wrap ~flatten 3 c)
    (flat_or_wrap ~flatten 4 d)
    (flat_or_wrap ~flatten 5 e)
    (flat_or_wrap ~flatten 6 f)

let tup7 ~flatten a b c d e f g =
  tup7_
    (flat_or_wrap ~flatten 1 a)
    (flat_or_wrap ~flatten 2 b)
    (flat_or_wrap ~flatten 3 c)
    (flat_or_wrap ~flatten 4 d)
    (flat_or_wrap ~flatten 5 e)
    (flat_or_wrap ~flatten 6 f)
    (flat_or_wrap ~flatten 7 g)

let tup8 ~flatten a b c d e f g h =
  tup8_
    (flat_or_wrap ~flatten 1 a)
    (flat_or_wrap ~flatten 2 b)
    (flat_or_wrap ~flatten 3 c)
    (flat_or_wrap ~flatten 4 d)
    (flat_or_wrap ~flatten 5 e)
    (flat_or_wrap ~flatten 6 f)
    (flat_or_wrap ~flatten 7 g)
    (flat_or_wrap ~flatten 8 h)

let tup9 ~flatten a b c d e f g h i =
  tup9_
    (flat_or_wrap ~flatten 1 a)
    (flat_or_wrap ~flatten 2 b)
    (flat_or_wrap ~flatten 3 c)
    (flat_or_wrap ~flatten 4 d)
    (flat_or_wrap ~flatten 5 e)
    (flat_or_wrap ~flatten 6 f)
    (flat_or_wrap ~flatten 7 g)
    (flat_or_wrap ~flatten 8 h)
    (flat_or_wrap ~flatten 9 i)

let raw key = {encode = E.raw key; decode = D.raw key}

let value ?default key de =
  {encode = E.value key de; decode = D.value ?default key de}

module Lazy_map_encoding = struct
  module type S = sig
    type 'a map

    val lazy_map : 'a t -> 'a map t
  end

  module Make (Map : Lazy_map.S) = struct
    let lazy_map value =
      let to_key k = [Map.string_of_key k] in
      let encode =
        E.contramap
          (fun map -> (Map.origin map, Map.loaded_bindings map))
          (E.lazy_mapping to_key value.encode)
      in
      let decode =
        D.map
          (fun (origin, produce_value) -> Map.create ?origin ~produce_value ())
          (let open D.Syntax in
          let+ produce_value = D.lazy_mapping to_key value.decode in
          produce_value)
      in
      {encode; decode}
  end
end

module Make_lazy_vector_encoding (Vector : Tezos_lazy_containers.Lazy_vector.S) =
struct
  let lazy_vector with_key value =
    let open Vector in
    let to_key k = [string_of_key k] in
    let encode =
      E.contramap
        (fun vector ->
          ( (origin vector, loaded_bindings vector),
            num_elements vector,
            first_key vector ))
        (E.tup3
           (E.scope ["contents"] (E.lazy_mapping to_key value.encode))
           (E.scope ["length"] with_key.encode)
           (E.scope ["head"] with_key.encode))
    in
    let decode =
      D.map
        (fun ((origin, produce_value), len, head) ->
          create ~produce_value ~first_key:head ?origin len)
        (let open D.Syntax in
        let+ x = D.scope ["contents"] (D.lazy_mapping to_key value.decode)
        and+ y = D.scope ["length"] with_key.decode
        and+ z = D.scope ["head"] with_key.decode in
        (x, y, z))
    in
    {encode; decode}
end

module Int_lazy_vector = Make_lazy_vector_encoding (Lazy_vector.IntVector)
module Int32_lazy_vector = Make_lazy_vector_encoding (Lazy_vector.Int32Vector)
module Int64_lazy_vector = Make_lazy_vector_encoding (Lazy_vector.Int64Vector)
module Z_lazy_vector = Make_lazy_vector_encoding (Lazy_vector.ZVector)

let int_lazy_vector = Int_lazy_vector.lazy_vector

let int32_lazy_vector = Int32_lazy_vector.lazy_vector

let int64_lazy_vector = Int64_lazy_vector.lazy_vector

let z_lazy_vector = Z_lazy_vector.lazy_vector

let chunk =
  let open Chunked_byte_vector.Chunk in
  conv of_bytes to_bytes (raw [])

let chunked_byte_vector =
  let open Chunked_byte_vector in
  let to_key k = [Int64.to_string k] in
  let encode =
    E.contramap
      (fun vector -> ((origin vector, loaded_chunks vector), length vector))
      (E.tup2
         (E.scope ["contents"] @@ E.lazy_mapping to_key chunk.encode)
         (E.value ["length"] Data_encoding.int64))
  in
  let decode =
    D.map
      (fun ((origin, get_chunk), len) -> create ?origin ~get_chunk len)
      (let open D.Syntax in
      let+ x = D.scope ["contents"] @@ D.lazy_mapping to_key chunk.decode
      and+ y = D.value ["length"] Data_encoding.int64 in
      (x, y))
  in
  {encode; decode}

type ('tag, 'a) case =
  | Case : {
      tag : 'tag;
      probe : 'a -> 'b Lwt.t option;
      extract : 'b -> 'a Lwt.t;
      delegate : 'b t;
    }
      -> ('tag, 'a) case

let case_lwt tag delegate probe extract = Case {tag; delegate; probe; extract}

let case tag delegate probe extract =
  case_lwt
    tag
    delegate
    (fun x -> Option.map Lwt.return @@ probe x)
    (fun x -> Lwt.return @@ extract x)

let tagged_union ?default {encode; decode} cases =
  let to_encode_case (Case {tag; delegate; probe; extract = _}) =
    E.case_lwt tag delegate.encode probe
  in
  let to_decode_case (Case {tag; delegate; extract; probe = _}) =
    D.case_lwt tag delegate.decode extract
  in
  let encode = E.tagged_union encode (List.map to_encode_case cases) in
  let decode = D.tagged_union ?default decode (List.map to_decode_case cases) in
  {encode; decode}

let value_option key encoding =
  let encode = E.value_option key encoding in
  let decode = D.value_option key encoding in
  {encode; decode}

let option enc =
  tagged_union
    ~default:(fun () -> None)
    (value [] Data_encoding.string)
    [
      case "Some" enc Fun.id Option.some;
      case
        "None"
        (return ())
        (function None -> Some () | _ -> None)
        (fun () -> None);
    ]

let delayed f =
  let enc = lazy (f ()) in
  let encode =
    E.delayed (fun () ->
        let {encode; _} = Lazy.force enc in
        encode)
  in
  let decode =
    D.delayed (fun () ->
        let {decode; _} = Lazy.force enc in
        decode)
  in
  {encode; decode}

let either enc_a enc_b =
  tagged_union
    (value [] Data_encoding.string)
    [
      case
        "Left"
        enc_a
        (function Either.Left x -> Some x | _ -> None)
        (function x -> Left x);
      case
        "Right"
        enc_b
        (function Either.Right x -> Some x | _ -> None)
        (function x -> Right x);
    ]

module type TREE = S

type wrapped_tree = Tree.wrapped_tree

module Wrapped : TREE with type tree = wrapped_tree = Tree.Wrapped

let wrapped_tree : wrapped_tree t =
  {encode = E.wrapped_tree; decode = D.wrapped_tree}

module Runner = struct
  module Make (T : TREE) = struct
    let encode {encode; _} value tree = E.run (module T) encode value tree

    let decode {decode; _} tree = D.run (module T) decode tree
  end
end
