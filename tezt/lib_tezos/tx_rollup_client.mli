(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(** transactional Rollup client state *)
type t

(** [create ?name ?path ?base_dir ?path node] returns a fresh client
   identified by a specified [name], logging in [color], executing the
   program at [path], storing local information in [base_dir], and
   communicating with the specified [node]. *)
val create :
  protocol:Protocol.t ->
  ?name:string ->
  ?base_dir:string ->
  ?wallet_dir:string ->
  ?color:Log.Color.t ->
  Tx_rollup_node.t ->
  t

val get_balance :
  ?block:string -> t -> tz4_address:string -> ticket_id:string -> int Lwt.t

val get_inbox : ?block:string -> t -> string Lwt.t

val get_block : ?style:[`Fancy | `Raw] -> t -> block:string -> string Lwt.t

val craft_tx_transaction :
  t ->
  signer:string ->
  ?counter:int64 ->
  Rollup.Tx_rollup.l2_transfer ->
  JSON.t Lwt.t

val craft_tx_transfers :
  t ->
  signer:string ->
  ?counter:int64 ->
  Rollup.Tx_rollup.l2_transfer list ->
  JSON.t Lwt.t

val craft_tx_withdraw :
  ?counter:Int64.t ->
  t ->
  qty:Int64.t ->
  signer:string ->
  dest:string ->
  ticket:string ->
  JSON.t Lwt.t

val craft_tx_batch :
  ?show_hex:bool ->
  t ->
  transactions_and_sig:JSON.t ->
  [`Hex of string | `Json of JSON.t] Lwt.t

val sign_transaction :
  ?aggregate:bool ->
  ?aggregated_signature:string ->
  t ->
  transaction:JSON.t ->
  signers:string list ->
  string Lwt.t

val transfer :
  ?counter:int64 ->
  t ->
  source:string ->
  Rollup.Tx_rollup.l2_transfer ->
  string Lwt.t

val withdraw :
  ?counter:int64 ->
  t ->
  source:string ->
  Rollup.Tx_rollup.l2_withdraw ->
  string Lwt.t

val get_batcher_queue : t -> string Lwt.t

val get_batcher_transaction : t -> transaction_hash:string -> string Lwt.t

val inject_batcher_transaction :
  ?expect_failure:bool ->
  t ->
  transactions_and_sig:JSON.t ->
  (string * string) Lwt.t

val get_message_proof :
  ?block:string -> t -> message_position:int -> string Lwt.t

module RPC : sig
  val get : t -> string -> string Lwt.t

  val post : t -> ?data:Ezjsonm.value -> string -> string Lwt.t
end
