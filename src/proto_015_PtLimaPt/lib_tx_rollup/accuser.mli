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

open Protocol.Alpha_context

(** [build_rejection state ~reject_commitment block ~position] constructs a
    rejection operation for rejecting message at position [position] in the (bad)
    commitment [reject_commitment], using the actual L2 block [block].  *)
val build_rejection :
  State.t ->
  reject_commitment:Tx_rollup_commitment.Full.t ->
  L2block.t ->
  position:int ->
  (Protocol.Tx_rollup_l2_proof.t * Kind.tx_rollup_rejection manager_operation)
  tzresult
  Lwt.t

(** [reject_bad_commitment ~source state commitment] injects a rejection
    operation with [source] if the [commitment] is rejectable. *)
val reject_bad_commitment :
  source:Signature.Public_key_hash.t ->
  State.t ->
  Tx_rollup_commitment.Full.t ->
  unit tzresult Lwt.t
