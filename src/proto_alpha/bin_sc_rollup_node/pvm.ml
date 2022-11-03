(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

(** Desired module type of a PVM from the L2 node's perspective *)
module type S = sig
  include
    Sc_rollup.PVM.S
      with type context = Context.index
       and type hash = Sc_rollup.State_hash.t

  (** [get_tick state] gets the total tick counter for the given PVM state. *)
  val get_tick : state -> Sc_rollup.Tick.t Lwt.t

  (** PVM status *)
  type status

  (** [get_status state] gives you the current execution status for the PVM. *)
  val get_status : state -> status Lwt.t

  (** [string_of_status status] returns a string representation of [status]. *)
  val string_of_status : status -> string

  (** [get_outbox state] returns a list of outputs available in the
      outbox of [state]. *)
  val get_outbox : state -> Sc_rollup.output list Lwt.t

  (** State storage for this PVM. *)
  module State : sig
    (** [find context] returns the PVM state stored in the [context], if any. *)
    val find : Context.t -> state option Lwt.t

    (** [lookup state path] returns the data stored for the path [path] in the
        PVM state [state].  *)
    val lookup : state -> string list -> bytes option Lwt.t

    (** [set context state] saves the PVM state [state] in the context and
        returns the updated context. Note: [set] does not perform any write on
        disk, this information must be committed using {!Context.commit}. *)
    val set : Context.t -> state -> Context.t Lwt.t
  end
end
