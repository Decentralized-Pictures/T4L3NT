(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

(** Block_validator_process is used to validate new blocks. This validation can be
    - internal: the same processus is used to run the node and to validate blocks
    - external: another processus is used to validate blocks
    This module also ensures the liveness of the operations
    (see [Block_validation:check_liveness]). *)

type validator_environment = {
  genesis : Genesis.t;  (** genesis block of the current chain *)
  user_activated_upgrades : User_activated.upgrades;
      (** user activated upgrades *)
  user_activated_protocol_overrides : User_activated.protocol_overrides;
      (** user activated protocol overrides *)
}

(** For performances reasons, it may be interesting to use another processus
    (from the OS) to validate blocks (External). However, in that case, only
    one processus has a write access to the context. Currently informations
    are exchanged via the file system. *)
type validator_kind =
  | Internal : Context.index -> validator_kind
  | External : {
      data_dir : string;
      context_root : string;
      protocol_root : string;
      process_path : string;
      sandbox_parameters : Data_encoding.json option;
    }
      -> validator_kind

(** Internal representation of the block validator process *)
type t

val init : validator_environment -> validator_kind -> t tzresult Lwt.t

val close : t -> unit Lwt.t

val restore_context_integrity : t -> int option tzresult Lwt.t

(** [apply_block bvp predecessor header os] checks the liveness of
    the operations and then call [Block_validation.apply] *)
val apply_block :
  t ->
  predecessor:State.Block.t ->
  Block_header.t ->
  Operation.t list list ->
  Block_validation.result tzresult Lwt.t

val commit_genesis : t -> chain_id:Chain_id.t -> Context_hash.t tzresult Lwt.t

(** [init_test_chain] must only be called on a forking block. *)
val init_test_chain : t -> State.Block.t -> Block_header.t tzresult Lwt.t
