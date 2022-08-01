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

type seed_computation_status =
  | Nonce_revelation_stage
  | Vdf_revelation_stage of {
      seed_discriminant : Seed_repr.seed;
      seed_challenge : Seed_repr.seed;
    }
  | Computation_finished

type error +=
  | Unknown of {
      oldest : Cycle_repr.t;
      cycle : Cycle_repr.t;
      latest : Cycle_repr.t;
    }
  | Already_accepted
  | Unverified_vdf
  | Too_early_revelation

(* `Permanent *)

(** Generates the first [preserved_cycles+2] seeds for which
    there are no nonces. *)
val init :
  ?initial_seed:State_hash.t -> Raw_context.t -> Raw_context.t tzresult Lwt.t

(** Verifies if a VDF (result, proof) is valid, if so updates the seed with a
   function of the VDF result. *)
val check_vdf_and_update_seed :
  Raw_context.t -> Seed_repr.vdf_solution -> Raw_context.t tzresult Lwt.t

val for_cycle : Raw_context.t -> Cycle_repr.t -> Seed_repr.seed tzresult Lwt.t

(** Computes RANDAO output for cycle #(current_cycle + preserved + 1) *)
val compute_randao : Raw_context.t -> Raw_context.t tzresult Lwt.t

(** Must be run at the end of the cycle, resets the VDF state and returns
    unrevealed nonces to know which party has to forfeit its endorsing
    rewards for that cycle.  *)
val cycle_end :
  Raw_context.t ->
  Cycle_repr.t ->
  (Raw_context.t * Nonce_storage.unrevealed list) tzresult Lwt.t

(** Return the random seed computation status, that is whether the VDF
  computation period has started, and if so the information needed, or if it has
  finished for the current cycle. *)
val get_seed_computation_status :
  Raw_context.t -> seed_computation_status tzresult Lwt.t
