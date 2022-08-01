(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
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

open Alpha_context

(** This module provides various helpers to manipulate tickets, that
    are used by the Transaction Rollups. *)

(** [parse_ticket ~consume_deserialization_gas ~ticketer ~contents ~ty
    ctxt] reconstructs a ticket from individual parts submitted as
    part of a layer-1 operation. *)
val parse_ticket :
  consume_deserialization_gas:Script.consume_deserialization_gas ->
  ticketer:Contract.t ->
  contents:Script.lazy_expr ->
  ty:Script.lazy_expr ->
  context ->
  (context * Ticket_token.ex_token, error trace) result Lwt.t

(** Same as [parse_ticket], but in addition, build a transaction to
     let [source] transfers [amount] units of said ticket to
     [destination]. *)
val parse_ticket_and_operation :
  consume_deserialization_gas:Script.consume_deserialization_gas ->
  ticketer:Contract.t ->
  contents:Script.lazy_expr ->
  ty:Script.lazy_expr ->
  source:Contract.t ->
  destination:Contract.t ->
  entrypoint:Entrypoint.t ->
  amount:Z.t ->
  context ->
  (context * Ticket_token.ex_token * Script_typed_ir.packed_internal_operation)
  tzresult
  Lwt.t

(** [make_withdraw_order ctxt tx_rollup ex_token claimer amount]
    computes a withdraw order that specify that [claimer] is entitled
    to get the ownership of [amount] units of [ex_token] which were
    deposited to [tx_rollup]. *)
val make_withdraw_order :
  context ->
  Tx_rollup.t ->
  Ticket_token.ex_token ->
  public_key_hash ->
  Tx_rollup_l2_qty.t ->
  (context * Tx_rollup_withdraw.order) tzresult Lwt.t

(** [transfer_ticket_with_hashes ctxt ~src_hash ~dst_hash qty] updates
    the table of tickets moves [qty] units of a given ticket from a
    source to a destination, as encoded by [src_hash] and [dst_hash].

    Consistency between [src_hash] and [dst_hash] is the
    responsibility of the caller. Whenever possible, [transfer_ticket]
    should be preferred, but [transfer_ticket_with_hashes] could be
    preferred to reduce gas comsumption (e.g., to reuse hashes already
    computed).

    In addition to an updated context, this function returns the
    number of bytes that were newly allocated for the table of
    tickets. *)
val transfer_ticket_with_hashes :
  context ->
  src_hash:Ticket_hash.t ->
  dst_hash:Ticket_hash.t ->
  Z.t ->
  (context * Z.t) tzresult Lwt.t

(** [transfer_ticket ctxt ~src ~dst ex_token qty] updates the table of
    tickets moves [qty] units of [ex_token] from [src] to [dst], as
    encoded by [src_hash] and [dst_hash].

    In addition to an updated context, this function returns the
    number of bytes that were newly allocated for the table of
    tickets. *)
val transfer_ticket :
  context ->
  src:Destination.t ->
  dst:Destination.t ->
  Ticket_token.ex_token ->
  counter ->
  (context * counter, error trace) result Lwt.t
