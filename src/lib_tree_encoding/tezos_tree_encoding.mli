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

exception Incorrect_tree_type

exception Uninitialized_self_ref

(** A key in the tree is a list of string. *)
type key = string trace

(** {2 Types}*)

(** Represents a partial encoder for a specific constructor of a sum-type. *)
type ('tag, 'a) case

(** Represents an encoder and a decoder. *)
type 'a t

(** {2 Functions }*)

(** [return x] is an encoder that does nothing on encoding. On decoding it
    ignores the tree and returns [x]. *)
val return : 'a -> 'a t

(** [conv f g enc] transforms from one encoding to a different one using
    [f] for mapping the results decoded using [enc], and [g] for mapping from
    the input.

    It is the user's responsibility to ensure that [f] and [g] are inverses,
    that is, that [f (g x) = g (f x)] for all [x]. *)
val conv : ('a -> 'b) -> ('b -> 'a) -> 'a t -> 'b t

(** [conv_lwt f g enc] is the same as [conv] but where [f] and [g] are
    effectful (produce lwt promises).

    It is the user's responsibility to ensure that [f] and [g] are inverses,
    that is, that [f (g x) = g (f x)] for all [x]. *)
val conv_lwt : ('a -> 'b Lwt.t) -> ('b -> 'a Lwt.t) -> 'a t -> 'b t

(** [tup2 ~flatten e1 e2] combines [e1] and [e2] into an encoder for pairs.
    If [flatten] is true, the elements are encoded directly under the given
    tree, otherwise each element is wrapped under an index node to avoid
    colliding keys.

    Example:
      [encode
        (tup2
          ~flatten:false
           (value [] Data_encoding.string)
           (value [] Data_encoding.string))
        (("A", "B"))]

    Gives a tree:
      "A"
      "B"

    While
      [encode
          (tup2
              ~flatten:true
              (value [] Data_encoding.string)
              (value [] Data_encoding.string))
          (("A", "B"))]

    Gives a tree:
      [1] -> "A"
      [2] -> "B" *)
val tup2 : flatten:bool -> 'a t -> 'b t -> ('a * 'b) t

(** [tup3 ?flatten e1 e2 e3] combines the given encoders [e1 .. e3] into an
    encoder for a tuple of three elements. *)
val tup3 : flatten:bool -> 'a t -> 'b t -> 'c t -> ('a * 'b * 'c) t

(** [tup4 ?flatten  e1 e2 e3 e4] combines the given encoders [e1 .. e4] into an
    encoder for a tuple of four elements. *)
val tup4 : flatten:bool -> 'a t -> 'b t -> 'c t -> 'd t -> ('a * 'b * 'c * 'd) t

(** [tup5 ?flatten e1 e2 e3 e4 e5] combines the given encoders [e1 .. e5] into
    an encoder for a tuple of five elements. *)
val tup5 :
  flatten:bool ->
  'a t ->
  'b t ->
  'c t ->
  'd t ->
  'e t ->
  ('a * 'b * 'c * 'd * 'e) t

(** [tup6 ?flatten e1 e2 e3 e4 e5 e6] combines the given encoders [e1 .. e6]
    into an encoder for a tuple of six elements. *)
val tup6 :
  flatten:bool ->
  'a t ->
  'b t ->
  'c t ->
  'd t ->
  'e t ->
  'f t ->
  ('a * 'b * 'c * 'd * 'e * 'f) t

(** [tup7 ?flatten e1 e2 e3 e4 e5 e6 e7] combines the given encoders
    [e1 .. e7] into an encoder for a tuple of seven elements. *)
val tup7 :
  flatten:bool ->
  'a t ->
  'b t ->
  'c t ->
  'd t ->
  'e t ->
  'f t ->
  'g t ->
  ('a * 'b * 'c * 'd * 'e * 'f * 'g) t

(** [tup8 ?flatten e1 e2 e3 e4 e5 e6 e7 e8] combines the given encoders
    [e1 .. e8] into an encoder for a tuple of eight elements. *)
val tup8 :
  flatten:bool ->
  'a t ->
  'b t ->
  'c t ->
  'd t ->
  'e t ->
  'f t ->
  'g t ->
  'h t ->
  ('a * 'b * 'c * 'd * 'e * 'f * 'g * 'h) t

(** [tup9 ~flatten e1 e2 e3 e4 e5 e6 e7 e8 e9] combines the given encoders
    [e1 .. e9] into an encoder for a tuple of nine elements. *)
val tup9 :
  flatten:bool ->
  'a t ->
  'b t ->
  'c t ->
  'd t ->
  'e t ->
  'f t ->
  'g t ->
  'h t ->
  'i t ->
  ('a * 'b * 'c * 'd * 'e * 'f * 'g * 'h * 'i) t

(** [raw key] is an encoder for bytes under the given [key]. *)
val raw : key -> bytes t

(** [value_option key encoding] returns an encoder that uses [encoding]
    for encoding values, but does not fail if the [key] is
    absent. *)
val value_option : key -> 'a Data_encoding.t -> 'a option t

(** [value ?default key enc] creates an encoder under the given
    [key] using the provided data-encoding [enc] for
    encoding/decoding values, and using [default] as a fallback when
    decoding in case the [key] is absent from the tree. *)
val value : ?default:'a -> key -> 'a Data_encoding.t -> 'a t

(** [scope key enc] moves the given encoder [enc] to encode values under a
    branch [key]. *)
val scope : key -> 'a t -> 'a t

module Lazy_map_encoding : sig
  module type S = sig
    type 'a map

    val lazy_map : 'a t -> 'a map t
  end

  (** [Make (YouMap)] creates a module with the [lazy_map]
      combinator which can be used to decode [YouMap] specifically. *)
  module Make (Map : Tezos_lazy_containers.Lazy_map.S) :
    S with type 'a map := 'a Map.t
end

val int_lazy_vector :
  int t -> 'a t -> 'a Tezos_lazy_containers.Lazy_vector.IntVector.t t

val int32_lazy_vector :
  int32 t -> 'a t -> 'a Tezos_lazy_containers.Lazy_vector.Int32Vector.t t

val int64_lazy_vector :
  int64 t -> 'a t -> 'a Tezos_lazy_containers.Lazy_vector.Int64Vector.t t

val z_lazy_vector :
  Z.t t -> 'a t -> 'a Tezos_lazy_containers.Lazy_vector.ZVector.t t

(** [chunk] is an encoder for the chunks used by [chunked_by_vector]. *)
val chunk : Tezos_lazy_containers.Chunked_byte_vector.Chunk.t t

(** [chunked_byte_vector] is an encoder for [chunked_byte_vector]. *)
val chunked_byte_vector : Tezos_lazy_containers.Chunked_byte_vector.t t

(** [case tag enc inj proj] returns a partial encoder that represents a case
    in a sum-type. The encoder hides the (existentially bound) type of the
    parameter to the specific case, provided converter functions [inj] and
    [proj] for the base encoder [enc]. *)
val case : 'tag -> 'b t -> ('a -> 'b option) -> ('b -> 'a) -> ('tag, 'a) case

(** [case_lwt tag enc inj proj] same as [case tag enc inj proj] but where
    [inj] and [proj] returns in lwt values. *)
val case_lwt :
  'tag -> 'b t -> ('a -> 'b Lwt.t option) -> ('b -> 'a Lwt.t) -> ('tag, 'a) case

(** [tagged_union tag_enc cases] returns an encoder that use [tag_enc] for
    encoding the value of a field [tag]. The encoder searches through the list
    of cases for a matching branch. When a matching branch is found, it uses
    its embedded encoder for the value. This function is used for constructing
    encoders for sum-types.

    The [default] labeled argument can be provided to have a
    fallback in case the value is missing from the tree. *)
val tagged_union :
  ?default:(unit -> 'a) -> 'tag t -> ('tag, 'a) case list -> 'a t

(** [option enc] lifts the given encoding [enc] to one that can encode
    optional values. *)
val option : 'a t -> 'a option t

(** [delayed f] produces a tree encoder/decoder that delays evaluation of
    [f ()] until the encoder or decoder is actually needed. This is required
    to allow for directly recursive encoders/decoders. *)
val delayed : (unit -> 'a t) -> 'a t

(** [either enc_a enc_b] returns an encoder where [enc_a] is used for
    the left case of [Either.t], and [enc_b] for the [Right] case. *)
val either : 'a t -> 'b t -> ('a, 'b) Either.t t

module type TREE = sig
  type tree

  type key := string list

  type value := bytes

  (** @raise Incorrect_tree_type *)
  val select : Tezos_lazy_containers.Lazy_map.tree -> tree

  val wrap : tree -> Tezos_lazy_containers.Lazy_map.tree

  val remove : tree -> key -> tree Lwt.t

  val add : tree -> key -> value -> tree Lwt.t

  val add_tree : tree -> key -> tree -> tree Lwt.t

  val find : tree -> key -> value option Lwt.t

  val find_tree : tree -> key -> tree option Lwt.t

  val hash : tree -> Context_hash.t

  val length : tree -> key -> int Lwt.t

  val list :
    tree -> ?offset:int -> ?length:int -> key -> (string * tree) list Lwt.t
end

type wrapped_tree

module Wrapped : TREE with type tree = wrapped_tree

(** [wrapped_tree] is a tree encoding for wrapped tree. *)
val wrapped_tree : wrapped_tree t

module Runner : sig
  (** Builds a new runner for encoders using a specific tree. *)
  module Make (T : TREE) : sig
    (** [encode enc x tree] encodes a value [x] using the encoder [enc]
    into the provided [tree]. *)
    val encode : 'a t -> 'a -> T.tree -> T.tree Lwt.t

    (** [decode enc x tree] decodes a value using the encoder [enc] from
    the provided [tree]. *)
    val decode : 'a t -> T.tree -> 'a Lwt.t
  end
end
