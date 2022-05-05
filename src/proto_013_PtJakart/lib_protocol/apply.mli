(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2020-2021 Nomadic Labs <contact@nomadic-labs.com>           *)
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

(** This module supports advancing the ledger state by applying [operation]s.

    Each operation application takes and returns an [Alpha_context.t], representing
    the old and new state, respectively.

    The [Main] module provides wrappers for the functionality in this module,
    satisfying the Protocol signature.
 *)

open Alpha_context
open Apply_results

type error +=
  | Internal_operation_replay of packed_internal_contents
  | Gas_quota_exceeded_init_deserialize
  | Tx_rollup_feature_disabled
  | Tx_rollup_invalid_transaction_amount
  | Tx_rollup_non_internal_transaction
  | Sc_rollup_feature_disabled
  | Inconsistent_counters
  | Forbidden_zero_ticket_quantity

val begin_partial_construction :
  context ->
  predecessor_level:Level.t ->
  toggle_vote:Liquidity_baking_repr.liquidity_baking_toggle_vote ->
  (t
  * packed_successful_manager_operation_result list
  * Liquidity_baking.Toggle_EMA.t)
  tzresult
  Lwt.t

type 'a full_construction = {
  ctxt : context;
  protocol_data : 'a;
  payload_producer : Signature.public_key_hash;
  block_producer : Signature.public_key_hash;
  round : Round.t;
  implicit_operations_results : packed_successful_manager_operation_result list;
  liquidity_baking_toggle_ema : Liquidity_baking.Toggle_EMA.t;
}

val begin_full_construction :
  context ->
  predecessor_timestamp:Time.t ->
  predecessor_level:Level.t ->
  predecessor_round:Round.t ->
  round:Round.t ->
  Block_header.contents ->
  Block_header.contents full_construction tzresult Lwt.t

val begin_application :
  context ->
  Chain_id.t ->
  Block_header.t ->
  Fitness.t ->
  predecessor_timestamp:Time.t ->
  predecessor_level:Level.t ->
  predecessor_round:Round.t ->
  (t
  * Signature.public_key
  * Signature.public_key_hash
  * packed_successful_manager_operation_result list
  * Liquidity_baking.Toggle_EMA.t)
  tzresult
  Lwt.t

type apply_mode =
  | Application of {
      predecessor_block : Block_hash.t;
      payload_hash : Block_payload_hash.t;
      locked_round : Round.t option;
      predecessor_level : Level.t;
      predecessor_round : Round.t;
      round : Round.t;
    } (* Both partial and normal *)
  | Full_construction of {
      predecessor_block : Block_hash.t;
      payload_hash : Block_payload_hash.t;
      predecessor_level : Level.t;
      predecessor_round : Round.t;
      round : Round.t;
    }
  | Partial_construction of {
      predecessor_level : Level.t;
      predecessor_round : Round.t;
      grand_parent_round : Round.t;
    }

val apply_operation :
  context ->
  Chain_id.t ->
  apply_mode ->
  Script_ir_translator.unparsing_mode ->
  payload_producer:public_key_hash ->
  Operation_list_hash.elt ->
  'a operation ->
  (context * 'a operation_metadata, error trace) result Lwt.t

type finalize_application_mode =
  | Finalize_full_construction of {
      level : Raw_level.t;
      predecessor_round : Round.t;
    }
  | Finalize_application of Fitness.t

val finalize_application :
  context ->
  finalize_application_mode ->
  Block_header.contents ->
  payload_producer:public_key_hash ->
  block_producer:public_key_hash ->
  Liquidity_baking.Toggle_EMA.t ->
  packed_successful_manager_operation_result list ->
  round:Round.t ->
  predecessor:Block_hash.t ->
  migration_balance_updates:Receipt.balance_updates ->
  (context * Fitness.t * block_metadata, error trace) result Lwt.t

val apply_manager_contents_list :
  context ->
  Script_ir_translator.unparsing_mode ->
  payload_producer:public_key_hash ->
  Chain_id.t ->
  'a Kind.manager prechecked_contents_list ->
  (context * 'a Kind.manager contents_result_list) Lwt.t

val apply_contents_list :
  context ->
  Chain_id.t ->
  apply_mode ->
  Script_ir_translator.unparsing_mode ->
  payload_producer:public_key_hash ->
  'kind operation ->
  'kind contents_list ->
  (context * 'kind contents_result_list) tzresult Lwt.t

(** [precheck_manager_contents_list validation_state contents_list]
   Returns an updated context, and a list of prechecked contents
   containing balance updates for fees related to each manager
   operation in [contents_list]

   If [mempool_mode], the function checks whether the total gas limit
   of this batch of operation is below the [gas_limit] of a block and
   fails with a permanent error when above. Otherwise, the gas limit
   of the batch is removed from the one of the block (when possible)
   before moving on. *)
val precheck_manager_contents_list :
  context ->
  'kind Kind.manager contents_list ->
  mempool_mode:bool ->
  (context * 'kind Kind.manager prechecked_contents_list) tzresult Lwt.t

(** [value_of_key ctxt k] builds a value identified by key [k]
    so that it can be put into the cache. *)
val value_of_key :
  context -> Context.Cache.key -> Context.Cache.value tzresult Lwt.t

(** Check if endorsements are required for a given level. *)
val are_endorsements_required :
  context -> level:Raw_level.t -> bool tzresult Lwt.t

(** Check if a block's endorsing power is at least the minim required. *)
val check_minimum_endorsements :
  endorsing_power:int -> minimum:int -> unit tzresult

(** [check_manager_signature validation_state op raw_operation]
    The function starts by retrieving the public key hash [pkh] of the manager
    operation. In case the operation is batched, the function also checks that
    the sources are all the same.
    Once the [pkh] is retrieved, the function looks for its associated public
    key. For that, the manager operation is inspected to check if it contains
    a public key revelation. If not, the public key is searched in the context.

    @return [Error Invalid_signature] if the signature check fails
    @return [Error Unrevealed_manager_key] if the manager has not yet been
    revealed
    @return [Error Missing_manager_contract] if the key is not found in the
    context
    @return [Error Inconsistent_sources] if the operations in a batch are not
    from the same manager *)
val check_manager_signature :
  context ->
  Chain_id.t ->
  'a Kind.manager contents_list ->
  'b operation ->
  (unit, error trace) result Lwt.t
