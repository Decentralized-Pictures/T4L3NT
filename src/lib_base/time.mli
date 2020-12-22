(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2019 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

(** Time management

    This module supports two distinct notions of time. The first notion of time
    is the time as handled by the protocol. This is the time that appears in the
    header of blocks, the time that baking slots are specified on, etc. It only
    has second-level precision.

    The second notion of time is the time as handled by the system. This is the
    time as returned by the processor clock, the time that network timeouts are
    specified on, etc. In has sub-second precision.

    The distinction between the two notions of time is important for multiple
    reasons:
    - Protocol time and system time may evolve independently. E.g., if a
    protocol update changes the notion of time.
    - Protocol time and system time have different levels of precision.
    - Protocol time and system time have different end-of-times. Respectively
    that's int64 end-of-time (some time in the year 292277026596) and rfc3339
    end-of-time (end of the year 9999).

*)

module Protocol : sig
  (** {1:Protocol time} *)

  (** The out-of-protocol view of in-protocol timestamps. The precision of
      in-protocol timestamps are only precise to the second.

      Note that the out-of-protocol view does not necessarily match the
      in-protocol representation.  *)

  (** The type of protocol times *)
  type t

  (** Unix epoch is 1970-01-01 00:00:00 +0000 (UTC) *)
  val epoch : t

  include Compare.S with type t := t

  (** [add t s] is [s] seconds later than [t] *)
  val add : t -> int64 -> t

  (** [diff a b] is the number of seconds between [a] and [b]. It is negative if
      [b] is later than [a]. *)
  val diff : t -> t -> int64

  (** Conversions to and from string representations. *)

  val of_notation : string -> t option

  val of_notation_exn : string -> t

  val to_notation : t -> string

  (** Conversion to and from "number of seconds since epoch" representation. *)

  val of_seconds : int64 -> t

  val to_seconds : t -> int64

  (** Serialization functions *)

  val encoding : t Data_encoding.t

  (* Note: the RFC has a different range than the internal representation.
     Specifically, the RFC can only represent times from 0000-00-00 and
     9999-12-31 (inclusive). The rfc-encoding fails for dates outside of this
     range.

     For this reason, it is preferable to use {!encoding} and only resort to
     [rfc_encoding] for human-readable format. *)
  val rfc_encoding : t Data_encoding.t

  val rpc_arg : t RPC_arg.t

  (** Pretty-printing functions *)

  (* Pretty print as a number of seconds after epoch. *)
  val pp : Format.formatter -> t -> unit

  (* Note: pretty-printing uses the rfc3999 for human-readability. As mentioned
     in the comment on {!rfc_encoding}, this representation fails when given
     dates too far in the future (after 9999-12-31) or the past (before
     0000-00-00).

     For reliable, generic pretty-printing use {!pp}. *)
  val pp_hum : Format.formatter -> t -> unit
end

module System : sig
  (** {1:System time} *)

  (** A representation of timestamps.

      NOTE: This representation is limited to times between
      0000-01-01 00:00:00 UTC and 9999-12-31 23:59:59.999999999999 UTC

      NOTE: This is based on the system clock. As a result, it is affected by
      system clock adjustments. IF you need monotonous time, you can use
      [Mtime]. *)

  type t = Ptime.t

  val epoch : t

  module Span : sig
    (** A representation of spans of time between two timestamps. *)
    type t = Ptime.Span.t

    (** [multiply_exn factor t] is a time spans that lasts [factor] time as long
        as [t]. It fails if the time span cannot be represented. *)
    val multiply_exn : float -> t -> t

    (** [of_seconds_exn f] is a time span of [f] seconds. It fails if the time
        span cannot be represented. *)
    val of_seconds_exn : float -> t

    (** Serialization functions *)

    val rpc_arg : t RPC_arg.t

    val pp_hum : Format.formatter -> t -> unit

    val encoding : t Data_encoding.t
  end

  (** Conversions to and from Protocol time. Note that converting system time to
      protocol time truncates any subsecond precision.  *)

  val of_protocol_opt : Protocol.t -> t option

  val of_protocol_exn : Protocol.t -> t

  val to_protocol : t -> Protocol.t

  (** Conversions to and from string. It uses rfc3339. *)

  val of_notation_opt : string -> t option

  val of_notation_exn : string -> t

  val to_notation : t -> string

  (** Serialization. *)

  val encoding : t Data_encoding.t

  val rfc_encoding : t Data_encoding.t

  val rpc_arg : t RPC_arg.t

  (** Pretty-printing *)

  val pp_hum : Format.formatter -> t -> unit

  (** Timestamping data. *)

  (** Data with an associated time stamp. *)
  type 'a stamped = {data : 'a; stamp : t}

  val stamped_encoding : 'a Data_encoding.t -> 'a stamped Data_encoding.t

  (** [stamp d] is a timestamped version of [d]. *)
  val stamp : time:t -> 'a -> 'a stamped

  val pp_stamped :
    (Format.formatter -> 'a -> unit) -> Format.formatter -> 'a stamped -> unit

  (** [recent a b] is either [a] or [b] (which ever carries the most recent
      timestamp), or [None] if both [a] and [b] are [None]. *)
  val recent : ('a * t) option -> ('a * t) option -> ('a * t) option

  (** Helper modules *)

  val hash : t -> int

  include Compare.S with type t := t

  module Set : Set.S with type elt = t

  module Map : Map.S with type key = t

  module Table : Hashtbl.S with type key = t
end
