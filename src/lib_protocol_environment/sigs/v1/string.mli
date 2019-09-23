(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* TEZOS CHANGES

   * Import version 4.06.1
   * Remove unsafe functions
   * Remove deprecated functions (enforcing string immutability)
   * Add binary data extraction functions

*)

(** String operations.

    A string is an immutable data structure that contains a
    fixed-length sequence of (single-byte) characters. Each character
    can be accessed in constant time through its index.

    Given a string [s] of length [l], we can access each of the [l]
    characters of [s] via its index in the sequence. Indexes start at
    [0], and we will call an index valid in [s] if it falls within the
    range [[0...l-1]] (inclusive). A position is the point between two
    characters or at the beginning or end of the string.  We call a
    position valid in [s] if it falls within the range [[0...l]]
    (inclusive). Note that the character at index [n] is between
    positions [n] and [n+1].

    Two parameters [start] and [len] are said to designate a valid
    substring of [s] if [len >= 0] and [start] and [start+len] are
    valid positions in [s].

    OCaml strings used to be modifiable in place, for instance via the
    {!String.set} and {!String.blit} functions described below. This
    usage is deprecated and only possible when the compiler is put in
    "unsafe-string" mode by giving the [-unsafe-string] command-line
    option (which is currently the default for reasons of backward
    compatibility). This is done by making the types [string] and
    [bytes] (see module {!Bytes}) interchangeable so that functions
    expecting byte sequences can also accept strings as arguments and
    modify them.

    All new code should avoid this feature and be compiled with the
    [-safe-string] command-line option to enforce the separation between
    the types [string] and [bytes].

*)

(** Return the length (number of characters) of the given string. *)
external length : string -> int = "%string_length"

(** [String.get s n] returns the character at index [n] in string [s].
    You can also write [s.[n]] instead of [String.get s n].

    Raise [Invalid_argument] if [n] not a valid index in [s]. *)
external get : string -> int -> char = "%string_safe_get"

(** [String.make n c] returns a fresh string of length [n],
    filled with the character [c].

    Raise [Invalid_argument] if [n < 0] or [n > ]{!Sys.max_string_length}. *)
val make : int -> char -> string

(** [String.init n f] returns a string of length [n], with character
    [i] initialized to the result of [f i] (called in increasing
    index order).

    Raise [Invalid_argument] if [n < 0] or [n > ]{!Sys.max_string_length}.

    @since 4.02.0
*)
val init : int -> (int -> char) -> string

(** [String.sub s start len] returns a fresh string of length [len],
    containing the substring of [s] that starts at position [start] and
    has length [len].

    Raise [Invalid_argument] if [start] and [len] do not
    designate a valid substring of [s]. *)
val sub : string -> int -> int -> string

(** Same as {!Bytes.blit_string}. *)
val blit : string -> int -> bytes -> int -> int -> unit

(** [String.concat sep sl] concatenates the list of strings [sl],
    inserting the separator string [sep] between each.

    Raise [Invalid_argument] if the result is longer than
    {!Sys.max_string_length} bytes. *)
val concat : string -> string list -> string

(** [String.iter f s] applies function [f] in turn to all
    the characters of [s].  It is equivalent to
    [f s.[0]; f s.[1]; ...; f s.[String.length s - 1]; ()]. *)
val iter : (char -> unit) -> string -> unit

(** Same as {!String.iter}, but the
    function is applied to the index of the element as first argument
    (counting from 0), and the character itself as second argument.
    @since 4.00.0 *)
val iteri : (int -> char -> unit) -> string -> unit

(** [String.map f s] applies function [f] in turn to all the
    characters of [s] (in increasing index order) and stores the
    results in a new string that is returned.
    @since 4.00.0 *)
val map : (char -> char) -> string -> string

(** [String.mapi f s] calls [f] with each character of [s] and its
    index (in increasing index order) and stores the results in a new
    string that is returned.
    @since 4.02.0 *)
val mapi : (int -> char -> char) -> string -> string

(** Return a copy of the argument, without leading and trailing
    whitespace.  The characters regarded as whitespace are: [' '],
    ['\012'], ['\n'], ['\r'], and ['\t'].  If there is neither leading nor
    trailing whitespace character in the argument, return the original
    string itself, not a copy.
    @since 4.00.0 *)
val trim : string -> string

(** Return a copy of the argument, with special characters
    represented by escape sequences, following the lexical
    conventions of OCaml.
    All characters outside the ASCII printable range (32..126) are
    escaped, as well as backslash and double-quote.

    If there is no special character in the argument that needs
    escaping, return the original string itself, not a copy.

    Raise [Invalid_argument] if the result is longer than
    {!Sys.max_string_length} bytes.

    The function {!Scanf.unescaped} is a left inverse of [escaped],
    i.e. [Scanf.unescaped (escaped s) = s] for any string [s] (unless
    [escape s] fails). *)
val escaped : string -> string

(** [String.index_opt s c] returns the index of the first
    occurrence of character [c] in string [s], or
    [None] if [c] does not occur in [s].
    @since 4.05 *)
val index_opt : string -> char -> int option

(** [String.rindex_opt s c] returns the index of the last occurrence
    of character [c] in string [s], or [None] if [c] does not occur in
    [s].
    @since 4.05 *)
val rindex_opt : string -> char -> int option

(** [String.index_from_opt s i c] returns the index of the
    first occurrence of character [c] in string [s] after position [i]
    or [None] if [c] does not occur in [s] after position [i].

    [String.index_opt s c] is equivalent to [String.index_from_opt s 0 c].
    Raise [Invalid_argument] if [i] is not a valid position in [s].

    @since 4.05
*)
val index_from_opt : string -> int -> char -> int option

(** [String.rindex_from_opt s i c] returns the index of the
    last occurrence of character [c] in string [s] before position [i+1]
    or [None] if [c] does not occur in [s] before position [i+1].

    [String.rindex_opt s c] is equivalent to
    [String.rindex_from_opt s (String.length s - 1) c].

    Raise [Invalid_argument] if [i+1] is not a valid position in [s].

    @since 4.05
*)
val rindex_from_opt : string -> int -> char -> int option

(** [String.contains s c] tests if character [c]
    appears in the string [s]. *)
val contains : string -> char -> bool

(** [String.contains_from s start c] tests if character [c]
    appears in [s] after position [start].
    [String.contains s c] is equivalent to
    [String.contains_from s 0 c].

    Raise [Invalid_argument] if [start] is not a valid position in [s]. *)
val contains_from : string -> int -> char -> bool

(** [String.rcontains_from s stop c] tests if character [c]
    appears in [s] before position [stop+1].

    Raise [Invalid_argument] if [stop < 0] or [stop+1] is not a valid
    position in [s]. *)
val rcontains_from : string -> int -> char -> bool

(** Return a copy of the argument, with all lowercase letters
    translated to uppercase, using the US-ASCII character set.
    @since 4.03.0 *)
val uppercase_ascii : string -> string

(** Return a copy of the argument, with all uppercase letters
    translated to lowercase, using the US-ASCII character set.
    @since 4.03.0 *)
val lowercase_ascii : string -> string

(** Return a copy of the argument, with the first character set to uppercase,
    using the US-ASCII character set.
    @since 4.03.0 *)
val capitalize_ascii : string -> string

(** Return a copy of the argument, with the first character set to lowercase,
    using the US-ASCII character set.
    @since 4.03.0 *)
val uncapitalize_ascii : string -> string

(** An alias for the type of strings. *)
type t = string

(** The comparison function for strings, with the same specification as
    {!Pervasives.compare}.  Along with the type [t], this function [compare]
    allows the module [String] to be passed as argument to the functors
    {!Set.Make} and {!Map.Make}. *)
val compare : t -> t -> int

(** The equal function for strings.
    @since 4.03.0 *)
val equal : t -> t -> bool

(** [String.split_on_char sep s] returns the list of all (possibly empty)
    substrings of [s] that are delimited by the [sep] character.

    The function's output is specified by the following invariants:

    - The list is not empty.
    - Concatenating its elements using [sep] as a separator returns a
      string equal to the input ([String.concat (String.make 1 sep)
      (String.split_on_char sep s) = s]).
    - No string in the result contains the [sep] character.

    @since 4.04.0
*)
val split_on_char : char -> string -> string list

(** Functions reading bytes  *)

(** [get_char buff i] reads 1 byte at offset i as a char *)
val get_char : t -> int -> char

(** [get_uint8 buff i] reads 1 byte at offset i as an unsigned int of 8
    bits. i.e. It returns a value between 0 and 2^8-1 *)
val get_uint8 : t -> int -> int

(** [get_int8 buff i] reads 1 byte at offset i as a signed int of 8
    bits. i.e. It returns a value between -2^7 and 2^7-1 *)
val get_int8 : t -> int -> int

(** Functions reading according to Big Endian byte order *)

(** [get_uint16 buff i] reads 2 bytes at offset i as an unsigned int
      of 16 bits. i.e. It returns a value between 0 and 2^16-1 *)
val get_uint16 : t -> int -> int

(** [get_int16 buff i] reads 2 byte at offset i as a signed int of
      16 bits. i.e. It returns a value between -2^15 and 2^15-1 *)
val get_int16 : t -> int -> int

(** [get_int32 buff i] reads 4 bytes at offset i as an int32. *)
val get_int32 : t -> int -> int32

(** [get_int64 buff i] reads 8 bytes at offset i as an int64. *)
val get_int64 : t -> int -> int64

module LE : sig
  (** Functions reading according to Little Endian byte order *)

  (** [get_uint16 buff i] reads 2 bytes at offset i as an unsigned int
      of 16 bits. i.e. It returns a value between 0 and 2^16-1 *)
  val get_uint16 : t -> int -> int

  (** [get_int16 buff i] reads 2 byte at offset i as a signed int of
      16 bits. i.e. It returns a value between -2^15 and 2^15-1 *)
  val get_int16 : t -> int -> int

  (** [get_int32 buff i] reads 4 bytes at offset i as an int32. *)
  val get_int32 : t -> int -> int32

  (** [get_int64 buff i] reads 8 bytes at offset i as an int64. *)
  val get_int64 : t -> int -> int64
end
