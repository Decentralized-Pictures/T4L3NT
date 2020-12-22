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

type t = private {
  level : Raw_level_repr.t;
      (** The level of the block relative to genesis. This
                              is also the Shell's notion of level. *)
  level_position : int32;
      (** The level of the block relative to the block that started the first
     version of protocol alpha. *)
  cycle : Cycle_repr.t;
      (** The current cycle's number. Note that cycles are a protocol-specific
     notion. As a result, the cycle number starts at 0 with the first block of
     the first version of protocol alpha. *)
  cycle_position : int32;
      (** The current level of the block relative to the first block of the current
     cycle. *)
  expected_commitment : bool;
}

(* Note that, the type `t` above must respect some invariants (hence the
   `private` annotation). Notably:

   level_position = cycle * blocks_per_cycle + cycle_position
*)

type level = t

include Compare.S with type t := level

val encoding : level Data_encoding.t

val pp : Format.formatter -> level -> unit

val pp_full : Format.formatter -> level -> unit

val root_level : Raw_level_repr.t -> level

val level_from_raw :
  first_level:Raw_level_repr.t ->
  blocks_per_cycle:int32 ->
  blocks_per_commitment:int32 ->
  Raw_level_repr.t ->
  level

val diff : level -> level -> int32

(** Compatibility module with Level_repr.t from protocol 007.
    In this version, the [voting_period] and [voting_period_position] fields are
    deprecated and replaced by a new RPC endpoint at
    [Voting_services.voting_period] *)
type compat_t = {
  level : Raw_level_repr.t;
  level_position : int32;
  cycle : Cycle_repr.t;
  cycle_position : int32;
  voting_period : int32;
  voting_period_position : int32;
  expected_commitment : bool;
}

val compat_encoding : compat_t Data_encoding.t

val to_deprecated_type :
  t -> voting_period_index:int32 -> voting_period_position:int32 -> compat_t
