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

let version_number_004 = "\000"
let version_number = "\001"
let proof_of_work_nonce_size = 8
let nonce_length = 32
let max_revelations_per_block = 32
let max_proposals_per_delegate = 20
let max_operation_data_length = 16 * 1024 (* 16kB *)

type fixed = {
  proof_of_work_nonce_size : int ;
  nonce_length : int ;
  max_revelations_per_block : int ;
  max_operation_data_length : int ;
  max_proposals_per_delegate : int ;
}

let fixed_encoding =
  let open Data_encoding in
  conv
    (fun c ->
       (c.proof_of_work_nonce_size,
        c.nonce_length,
        c.max_revelations_per_block,
        c.max_operation_data_length,
        c.max_proposals_per_delegate))
    (fun (proof_of_work_nonce_size,
          nonce_length,
          max_revelations_per_block,
          max_operation_data_length,
          max_proposals_per_delegate) ->
      { proof_of_work_nonce_size ;
        nonce_length ;
        max_revelations_per_block ;
        max_operation_data_length ;
        max_proposals_per_delegate ;
      } )
    (obj5
       (req "proof_of_work_nonce_size" uint8)
       (req "nonce_length" uint8)
       (req "max_revelations_per_block" uint8)
       (req "max_operation_data_length" int31)
       (req "max_proposals_per_delegate" uint8))

let fixed = {
  proof_of_work_nonce_size ;
  nonce_length ;
  max_revelations_per_block ;
  max_operation_data_length ;
  max_proposals_per_delegate ;
}

type parametric = {
  preserved_cycles: int ;
  blocks_per_cycle: int32 ;
  blocks_per_commitment: int32 ;
  blocks_per_roll_snapshot: int32 ;
  blocks_per_voting_period: int32 ;
  time_between_blocks: Period_repr.t list ;
  endorsers_per_block: int ;
  hard_gas_limit_per_operation: Z.t ;
  hard_gas_limit_per_block: Z.t ;
  proof_of_work_threshold: int64 ;
  tokens_per_roll: Tez_repr.t ;
  michelson_maximum_type_size: int;
  seed_nonce_revelation_tip: Tez_repr.t ;
  origination_size: int ;
  block_security_deposit: Tez_repr.t ;
  endorsement_security_deposit: Tez_repr.t ;
  block_reward: Tez_repr.t ;
  endorsement_reward: Tez_repr.t ;
  cost_per_byte: Tez_repr.t ;
  hard_storage_limit_per_operation: Z.t ;
  test_chain_duration: int64 ;  (* in seconds *)
  quorum_min: int32 ;
  quorum_max: int32 ;
  min_proposal_quorum: int32 ;
  initial_endorsers: int ;
  delay_per_missing_endorsement: Period_repr.t ;
}

let parametric_encoding =
  let open Data_encoding in
  conv
    (fun c ->
       (( c.preserved_cycles,
          c.blocks_per_cycle,
          c.blocks_per_commitment,
          c.blocks_per_roll_snapshot,
          c.blocks_per_voting_period,
          c.time_between_blocks,
          c.endorsers_per_block,
          c.hard_gas_limit_per_operation,
          c.hard_gas_limit_per_block),
        ((c.proof_of_work_threshold,
          c.tokens_per_roll,
          c.michelson_maximum_type_size,
          c.seed_nonce_revelation_tip,
          c.origination_size,
          c.block_security_deposit,
          c.endorsement_security_deposit,
          c.block_reward),
         (c.endorsement_reward,
          c.cost_per_byte,
          c.hard_storage_limit_per_operation,
          c.test_chain_duration,
          c.quorum_min,
          c.quorum_max,
          c.min_proposal_quorum,
          c.initial_endorsers,
          c.delay_per_missing_endorsement
         ))) )
    (fun (( preserved_cycles,
            blocks_per_cycle,
            blocks_per_commitment,
            blocks_per_roll_snapshot,
            blocks_per_voting_period,
            time_between_blocks,
            endorsers_per_block,
            hard_gas_limit_per_operation,
            hard_gas_limit_per_block),
          ((proof_of_work_threshold,
            tokens_per_roll,
            michelson_maximum_type_size,
            seed_nonce_revelation_tip,
            origination_size,
            block_security_deposit,
            endorsement_security_deposit,
            block_reward),
           (endorsement_reward,
            cost_per_byte,
            hard_storage_limit_per_operation,
            test_chain_duration,
            quorum_min,
            quorum_max,
            min_proposal_quorum,
            initial_endorsers,
            delay_per_missing_endorsement))) ->
      { preserved_cycles ;
        blocks_per_cycle ;
        blocks_per_commitment ;
        blocks_per_roll_snapshot ;
        blocks_per_voting_period ;
        time_between_blocks ;
        endorsers_per_block ;
        hard_gas_limit_per_operation ;
        hard_gas_limit_per_block ;
        proof_of_work_threshold ;
        tokens_per_roll ;
        michelson_maximum_type_size ;
        seed_nonce_revelation_tip ;
        origination_size ;
        block_security_deposit ;
        endorsement_security_deposit ;
        block_reward ;
        endorsement_reward ;
        cost_per_byte ;
        hard_storage_limit_per_operation ;
        test_chain_duration ;
        quorum_min ;
        quorum_max ;
        min_proposal_quorum ;
        initial_endorsers ;
        delay_per_missing_endorsement ;
      } )
    (merge_objs
       (obj9
          (req "preserved_cycles" uint8)
          (req "blocks_per_cycle" int32)
          (req "blocks_per_commitment" int32)
          (req "blocks_per_roll_snapshot" int32)
          (req "blocks_per_voting_period" int32)
          (req "time_between_blocks" (list Period_repr.encoding))
          (req "endorsers_per_block" uint16)
          (req "hard_gas_limit_per_operation" z)
          (req "hard_gas_limit_per_block" z))
       (merge_objs
          (obj8
             (req "proof_of_work_threshold" int64)
             (req "tokens_per_roll" Tez_repr.encoding)
             (req "michelson_maximum_type_size" uint16)
             (req "seed_nonce_revelation_tip" Tez_repr.encoding)
             (req "origination_size" int31)
             (req "block_security_deposit" Tez_repr.encoding)
             (req "endorsement_security_deposit" Tez_repr.encoding)
             (req "block_reward" Tez_repr.encoding))
          (obj9
             (req "endorsement_reward" Tez_repr.encoding)
             (req "cost_per_byte" Tez_repr.encoding)
             (req "hard_storage_limit_per_operation" z)
             (req "test_chain_duration" int64)
             (req "quorum_min" int32)
             (req "quorum_max" int32)
             (req "min_proposal_quorum" int32)
             (req "initial_endorsers" uint16)
             (req "delay_per_missing_endorsement" Period_repr.encoding)
          )))

type t = {
  fixed : fixed ;
  parametric : parametric ;
}

let encoding =
  let open Data_encoding in
  conv
    (fun { fixed ; parametric } -> (fixed, parametric))
    (fun (fixed , parametric) -> { fixed ; parametric })
    (merge_objs fixed_encoding parametric_encoding)
