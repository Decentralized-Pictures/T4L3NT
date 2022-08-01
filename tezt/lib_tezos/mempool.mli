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

(** The mempool type description. *)
type t = {
  applied : string list;
  branch_delayed : string list;
  branch_refused : string list;
  refused : string list;
  outdated : string list;
  unprocessed : string list;
}

(** A comparable type for mempool where classification and ordering
   does not matter. *)
val typ : t Check.typ

(** A comparable type for mempool where ordering does not matter. *)
val classified_typ : t Check.typ

val empty : t

(** Symetric difference (union(a, b) - intersection(a, b)) *)
val symmetric_diff : t -> t -> t

(** Build a value of type {!t} from a json returned by
   {!RPC.get_mempool_pending_operations}. *)
val of_json : JSON.t -> t

(** Call [RPC.get_mempool_pending_operations] and wrap the result in a
    value of type [Mempool.t] *)
val get_mempool :
  ?endpoint:Client.endpoint ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?applied:bool ->
  ?branch_delayed:bool ->
  ?branch_refused:bool ->
  ?refused:bool ->
  ?outdated:bool ->
  Client.t ->
  t Lwt.t

(** Check that each field of [t] contains the same elements as the
    argument of the same name. Ordening does not matter. Omitted
    arguments default to the empty list. This is useful when we expect a
    sparse mempool. *)
val check_mempool :
  ?applied:string list ->
  ?branch_delayed:string list ->
  ?branch_refused:string list ->
  ?refused:string list ->
  ?outdated:string list ->
  ?unprocessed:string list ->
  t ->
  unit
