(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Protocol
open Alpha_context

(**  {2 Types for L2 block and header} *)

(** Hash with b58check encoding BTx(53), for hashes of L2 block headers *)
module Hash : S.HASH

(** Alias for block (header) hashes *)
type hash = Hash.t

(** The level of an L2 block  *)
type level = Tx_rollup_level.t

(** Type of L2 block headers *)
type header = {
  level : level;  (** The level of the L2 block *)
  tezos_block : Block_hash.t;
      (** The Tezos block on which this L2 block in anchored, i.e. the Tezos block
      in which the inbox was sent *)
  predecessor : hash option;  (** The hash predecessor L2 block *)
  context : Tx_rollup_l2_context_hash.t;
      (** The hash of the context resulting of the application of the L2 block's inbox *)
  commitment : Tx_rollup_commitment_hash.t;
      (** The hash of the commitment for the inbox of this block *)
}

(** L2 blocks are composed of a header and an inbox. The inbox contains the
    actual messages. The hash in the block structure corresponds the hash of the
    header. *)
type 'inbox block = {
  hash : hash;
  header : header;
  inbox : 'inbox;
  commitment : Tx_rollup_commitment.Full.t;
}

type t = Inbox.t block

type commitment_included_info = {
  block : Block_hash.t;
  operation : Operation_hash.t;
}

(** Metadata for the block  *)
type metadata = {
  commitment_included : commitment_included_info option;
      (** Contains information if the commitment for this block has been included on L1 *)
  finalized : bool;
      (** Flag to signal if the commitment for this block is finalized on L1 *)
}

(**  {2 Encoding} *)

val level_encoding : level Data_encoding.t

val level_to_string : level -> string

val header_encoding : header Data_encoding.t

val block_encoding : 'inbox Data_encoding.t -> 'inbox block Data_encoding.t

val encoding : t Data_encoding.t

val metadata_encoding : metadata Data_encoding.t

(**  {2 Hashing} *)

(** Returns the hash of an L2 block header *)
val hash_header : header -> hash
