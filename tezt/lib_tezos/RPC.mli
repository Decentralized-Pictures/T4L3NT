(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(** In all RPCs, default [chain] is "main" and default [block] is "head". *)

(** {2 Shell RPCs *)

(** Call RPC /network/connections if [peer_id] is [None].
    Call RPC /network/connections/[peer_id] otherwise. *)
val get_connections :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?peer_id:string ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/chain_id *)
val get_chain_id :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain] *)
val force_bootstrapped :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?bootstrapped:bool ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/checkpoint *)
val get_checkpoint :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /injection/block *)
val inject_block :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  data:JSON.u ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/blocks/[block]/header/protocol_data *)
val get_protocol_data :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?block:string ->
  ?offset:int ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/blocks/[block]/operations *)
val get_operations :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?block:string ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chains/[chain]/mempool/pending_operations *)
val get_mempool_pending_operations :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/blocks/[block]/helpers/preapply/block *)
val preapply_block :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?block:string ->
  data:JSON.u ->
  Client.t ->
  JSON.t Lwt.t

(** {2 Protocol RPCs *)

(** Call RPC /chain/[chain]/blocks/[block]/context/constants *)
val get_constants :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?block:string ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/blocks/[block]/context/constants/errors *)
val get_constants_errors :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?block:string ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/blocks/[block]/helpers/baking_rights *)
val get_baking_rights :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?block:string ->
  ?delegate:string ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/blocks/[block]/helpers/current_level *)
val get_current_level :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?block:string ->
  ?offset:int ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/blocks/[block]/helpers/endorsing_rights *)
val get_endorsing_rights :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?block:string ->
  ?delegate:string ->
  Client.t ->
  JSON.t Lwt.t

(** Call RPC /chain/[chain]/blocks/[block]/helpers/levels_in_current_cycle *)
val get_levels_in_current_cycle :
  ?node:Node.t ->
  ?hooks:Process.hooks ->
  ?chain:string ->
  ?block:string ->
  Client.t ->
  JSON.t Lwt.t

module Contracts : sig
  (** Common protocol RPSs for contracts (i.e. under [/contracts]). *)

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts *)
  val get_all :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    string list Lwt.t

  (** Same as [get_all], but do not wait for the process to exit. *)
  val spawn_get_all :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts/[contract_id] *)
  val get :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get], but do not wait for the process to exit. *)
  val spawn_get :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts/[contract_id]/balance *)
  val get_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_balance], but do not wait for the process to exit. *)
  val spawn_get_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts/[contract_id]/big_map_get *)
  val big_map_get :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    data:JSON.u ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [big_map_get], but do not wait for the process to exit. *)
  val spawn_big_map_get :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    data:JSON.u ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts/[contract_id]/counter *)
  val get_counter :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_counter], but do not wait for the process to exit. *)
  val spawn_get_counter :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts/[contract_id]/delegate *)
  val get_delegate :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_delegate], but do not wait for the process to exit. *)
  val spawn_get_delegate :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts/[contract_id]/entrypoints *)
  val get_entrypoints :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_entrypoints], but do not wait for the process to exit. *)
  val spawn_get_entrypoints :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts/[contract_id]/manager_key *)
  val get_manager_key :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_manager_key], but do not wait for the process to exit. *)
  val spawn_get_manager_key :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts/[contract_id]/script *)
  val get_script :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_script], but do not wait for the process to exit. *)
  val spawn_get_script :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/contracts/[contract_id]/storage *)
  val get_storage :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_storage], but do not wait for the process to exit. *)
  val spawn_get_storage :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    contract_id:string ->
    Client.t ->
    Process.t
end

module Delegates : sig
  (** Common protocol RPSs for delegates (i.e. under [/delegates]). *)

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates *)
  val get_all :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    string list Lwt.t

  (** Same as [get_all], but do not wait for the process to exit. *)
  val spawn_get_all :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh] *)
  val get :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get], but do not wait for the process to exit. *)
  val spawn_get :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh]/balance *)
  val get_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_balance], but do not wait for the process to exit. *)
  val spawn_get_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh]/deactivated *)
  val get_deactivated :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_deactivated], but do not wait for the process to exit. *)
  val spawn_get_deactivated :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh]/delegated_balance *)
  val get_delegated_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_delegated_balance], but do not wait for the process to exit. *)
  val spawn_get_delegated_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh]/delegated_contracts *)
  val get_delegated_contracts :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_delegated_contracts], but do not wait for the process to exit. *)
  val spawn_get_delegated_contracts :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh]/frozen_balance *)
  val get_frozen_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_frozen_balance], but do not wait for the process to exit. *)
  val spawn_get_frozen_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh]/frozen_balance_by_cycle *)
  val get_frozen_balance_by_cycle :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_frozen_balance_by_cycle], but do not wait for the process to exit. *)
  val spawn_get_frozen_balance_by_cycle :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh]/grace_period *)
  val get_grace_period :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_grace_period], but do not wait for the process to exit. *)
  val spawn_get_grace_period :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh]/staking_balance *)
  val get_staking_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_staking_balance], but do not wait for the process to exit. *)
  val spawn_get_staking_balance :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t

  (** Call RPC /chain/[chain]/blocks/[block]/context/delegates/[pkh]/voting_power *)
  val get_voting_power :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Same as [get_voting_power], but do not wait for the process to exit. *)
  val spawn_get_voting_power :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    pkh:string ->
    Client.t ->
    Process.t
end

module Votes : sig
  (** Common protocol RPSs for votes (i.e. under [/votes]). *)

  (** Call RPC /chain/[chain]/blocks/[block]/votes/ballot_list *)
  val get_ballot_list :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Call RPC /chain/[chain]/blocks/[block]/votes/ballots *)
  val get_ballots :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Call RPC /chain/[chain]/blocks/[block]/votes/current_period_kind *)
  val get_current_period_kind :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Call RPC /chain/[chain]/blocks/[block]/votes/current_proposal *)
  val get_current_proposal :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Call RPC /chain/[chain]/blocks/[block]/votes/current_quorum *)
  val get_current_quorum :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Call RPC /chain/[chain]/blocks/[block]/votes/listings *)
  val get_listings :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Call RPC /chain/[chain]/blocks/[block]/votes/proposals *)
  val get_proposals :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Call RPC /chain/[chain]/blocks/[block]/votes/current_period *)
  val get_current_period :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Call RPC /chain/[chain]/blocks/[block]/votes/successor_period *)
  val get_successor_period :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t

  (** Call RPC /chain/[chain]/blocks/[block]/votes/total_voting_power *)
  val get_total_voting_power :
    ?node:Node.t ->
    ?hooks:Process.hooks ->
    ?chain:string ->
    ?block:string ->
    Client.t ->
    JSON.t Lwt.t
end
