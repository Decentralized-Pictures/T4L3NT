(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022 Trili Tech, <contact@trili.tech>                       *)
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

module V2_0_0 : sig
  (** This module provides Proof-Generating Virtual Machine (PVM) running
    WebAssembly (version 2.0.0). *)

  module type S = sig
    include Sc_rollup_PVM_sig.S

    (** [parse_boot_sector s] builds a boot sector from its human
      writable description. *)
    val parse_boot_sector : string -> string option

    (** [pp_boot_sector fmt s] prints a human readable representation of
     a boot sector. *)
    val pp_boot_sector : Format.formatter -> string -> unit

    (* Required by L2 node: *)

    (** [get_tick state] gets the total tick counter for the given PVM state. *)
    val get_tick : state -> Sc_rollup_tick_repr.t Lwt.t

    (** PVM status *)
    type status =
      | Computing
      | Waiting_for_input_message
      | Waiting_for_reveal of Sc_rollup_PVM_sig.reveal

    (** [get_status state] gives you the current execution status for the PVM. *)
    val get_status : state -> status Lwt.t

    (** [get_outbox outbox_level state] returns the outbox in [state]
       for a given [outbox_level]. *)
    val get_outbox :
      Raw_level_repr.t -> state -> Sc_rollup_PVM_sig.output list Lwt.t
  end

  module type P = sig
    module Tree :
      Context.TREE with type key = string list and type value = bytes

    type tree = Tree.tree

    type proof

    val proof_encoding : proof Data_encoding.t

    val proof_before : proof -> Sc_rollup_repr.State_hash.t

    val proof_after : proof -> Sc_rollup_repr.State_hash.t

    val verify_proof :
      proof -> (tree -> (tree * 'a) Lwt.t) -> (tree * 'a) option Lwt.t

    val produce_proof :
      Tree.t -> tree -> (tree -> (tree * 'a) Lwt.t) -> (proof * 'a) option Lwt.t
  end

  module type Make_wasm = module type of Wasm_2_0_0.Make

  (** Build a WebAssembly PVM using the given proof-supporting context. *)
  module Make (Lib_scoru_Wasm : Make_wasm) (Context : P) :
    S
      with type context = Context.Tree.t
       and type state = Context.tree
       and type proof = Context.proof

  (** This PVM is used for verification in the Protocol. [produce_proof] always returns [None]. *)
  module Protocol_implementation :
    S
      with type context = Context.t
       and type state = Context.tree
       and type proof = Context.Proof.tree Context.Proof.t

  (** This is the state hash of reference that both the prover of the
      node and the verifier of the protocol {!Protocol_implementation}
      have to agree on (if they do, it means they are using the same
      tree structure). *)
  val reference_initial_state_hash : Sc_rollup_repr.State_hash.t

  (** Number of ticks between snapshotable states, chosen low enough
      to maintain refutability.

      {b Warning:} This value is used to specialize the dissection
      predicate of the WASM PVM. Do not change it without a migration
      plan for already originated smart rollups.

      Depends on
      - speed (tick/s) of node in slow mode (from benchmark, 6000000 tick/s)
      - the number of ticks in a commitment ({!Int64.max_int},
         as per Number_of_ticks.max_value)

      see #3590 for more pointers *)
  val ticks_per_snapshot : Z.t

  (* The number of outboxes to keep, which is for a period of two weeks. For a
     block time of 30 seconds, this equals to 2 * 60 * 24 * 14 = 40_320
     blocks. *)
  val outbox_validity_period : int32

  (* Maximum number of outbox messages per level.

     Equals to {Constants_parametric_repr.max_outbox_messages_per_level}. *)
  val outbox_message_limit : Z.t

  (** The hash requested by the WASM PVM if it cannot decode the input
      provided by the WASM kernel, that is, if the bytes value cannot
      be decoded with {!Sc_rollup_reveal_hash.encoding}. *)
  val well_known_reveal_hash : Sc_rollup_reveal_hash.t

  (** The preimage of {!well_known_reveal_hash}. *)
  val well_known_reveal_preimage : string
end
