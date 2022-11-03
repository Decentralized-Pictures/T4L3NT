(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
(* Copyright (c) 2022 Marigold, <contact@marigold.dev>                       *)
(* Copyright (c) 2022 Oxhead Alpha <info@oxhead-alpha.com>                   *)
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

include Internal_event.Simple

let section = ["tx_rollup_node"]

let preamble_warning =
  declare_0
    ~section
    ~name:"tx_rollup_node_preamble_warning"
    ~msg:
      "this node is primarily being developed for testing purposes at the \
       moment"
    ~level:Warning
    ()

let configuration_was_written =
  declare_1
    ~section
    ~name:"tx_rollup_node_configuration_written"
    ~msg:"configuration written in {file}"
    ~level:Notice
    ("file", Data_encoding.string)

let starting_node =
  declare_0
    ~section
    ~name:"tx_rollup_node_starting"
    ~msg:"starting the transaction rollup node"
    ~level:Notice
    ()

let rpc_server_is_ready =
  declare_1
    ~section
    ~name:"tx_rollup_node_rpc_server_is_ready"
    ~msg:"the transaction rollup node RPC server is listening on {addr}"
    ~level:Notice
    ("addr", P2p_point.Id.encoding)

let node_is_ready =
  declare_0
    ~section
    ~name:"tx_rollup_node_is_ready"
    ~msg:"the transaction rollup node is ready"
    ~level:Notice
    ()

let cannot_connect =
  declare_1
    ~section
    ~name:"tx_rollup_node_cannot_connect"
    ~msg:"cannot connect to a node, retrying in {delay}s"
    ~level:Warning
    ("delay", Data_encoding.float)

let connection_lost =
  declare_0
    ~section
    ~name:"tx_rollup_node_connection_lost"
    ~msg:"connection to the node has been lost"
    ~level:Warning
    ()

let catch_up_commitments =
  declare_0
    ~section
    ~name:"tx_rollup_node_catch_up_commitments"
    ~msg:"Catching up on commitments"
    ~level:Notice
    ()

let new_block =
  declare_1
    ~section
    ~name:"tx_rollup_node_new_block"
    ~msg:"new block with hash: {block_hash}"
    ~level:Notice
    ("block_hash", Block_hash.encoding)

let processing_block =
  declare_2
    ~section
    ~name:"tx_rollup_node_processing_block"
    ~msg:"processing block: {block_hash} (pred: {predecessor_hash})"
    ~level:Debug
    ("block_hash", Block_hash.encoding)
    ("predecessor_hash", Block_hash.encoding)

let missing_blocks =
  declare_1
    ~section
    ~name:"tx_rollup_node_missing_blocks"
    ~msg:"Rollup node needs to process {nb} missing Tezos blocks"
    ~level:Notice
    ("nb", Data_encoding.int31)

let look_for_origination =
  declare_2
    ~section
    ~name:"tx_rollup_node_look_for_origination"
    ~msg:"Looking for rollup origination in block {block} level {level}"
    ~level:Notice
    ("block", Block_hash.encoding)
    ("level", Data_encoding.int32)

let detected_origination =
  declare_2
    ~section
    ~name:"tx_rollup_node_detected_origination"
    ~msg:"Detected rollup {rollup} origination in {block}"
    ~level:Notice
    ("rollup", Protocol.Alpha_context.Tx_rollup.encoding)
    ("block", Block_hash.encoding)

let tezos_block_processed =
  declare_2
    ~section
    ~name:"tx_rollup_node_tezos_block_processed"
    ~msg:"tezos block {block_hash} at level {level} was sucessfully processed"
    ~level:Notice
    ("block_hash", Block_hash.encoding)
    ("level", Data_encoding.int32)

let block_already_processed =
  declare_1
    ~section
    ~name:"tx_rollup_node_block_already_processed"
    ~msg:
      "the block {block_hash} has already been processed, nothing more to be \
       done"
    ~level:Debug
    ("block_hash", Block_hash.encoding)

let processing_block_predecessor =
  declare_2
    ~section
    ~name:"tx_rollup_node_processing_block_predecessor"
    ~msg:
      "processing block predecessor {predecessor_hash} at level \
       {predecessor_level}"
    ~level:Debug
    ("predecessor_hash", Block_hash.encoding)
    ("predecessor_level", Data_encoding.int32)

let messages_application =
  declare_1
    ~section
    ~name:"tx_rollup_node_messages_application"
    ~msg:"has {number} messages to apply"
    ~level:Notice
    ("number", Data_encoding.int31)

let rollup_block =
  declare_3
    ~section
    ~name:"tx_rollup_level"
    ~msg:"Level {level}: L2 block {hash} at Tezos {tezos_hash}"
    ~level:Notice
    ("level", L2block.level_encoding)
    ("hash", L2block.Hash.encoding)
    ("tezos_hash", Block_hash.encoding)

let inbox_stored =
  declare_4
    ~section
    ~name:"tx_rollup_node_inbox_stored"
    ~msg:
      "an inbox with size {cumulated_size} and resulting context hash \
       {context_hash} has been stored for {block_hash}: {messages}"
    ~level:Notice
    ("block_hash", Block_hash.encoding)
    ("messages", Data_encoding.list Inbox.message_encoding)
    ("cumulated_size", Data_encoding.int31)
    ("context_hash", Protocol.Tx_rollup_l2_context_hash.encoding)

let irmin_store_loaded =
  declare_1
    ~section
    ~name:"tx_rollup_node_irmin_store_loaded"
    ~msg:"an Irmin store has been loaded from {data_dir}"
    ~level:Notice
    ("data_dir", Data_encoding.string)

let new_tezos_head =
  declare_1
    ~section
    ~name:"tx_rollup_node_new_tezos_head"
    ~msg:"a new tezos head ({tezos_head}) is stored"
    ~level:Notice
    ("tezos_head", Block_hash.encoding)

let inject_wait =
  declare_1
    ~section
    ~name:"inject_wait"
    ~msg:"Waiting {delay} seconds to trigger injection"
    ~level:Notice
    ("delay", Data_encoding.float)

module Batcher = struct
  let section = section @ ["batcher"]

  let queue =
    declare_1
      ~section
      ~name:"queue"
      ~msg:"adding {tr_hash} to queue"
      ~level:Notice
      ("tr_hash", L2_transaction.Hash.encoding)

  let batch =
    declare_2
      ~section
      ~name:"batch"
      ~msg:"batching {nb_transactions} transactions into {nb_batches} batches"
      ~level:Notice
      ("nb_batches", Data_encoding.int31)
      ("nb_transactions", Data_encoding.int31)

  let no_full_batch =
    declare_0
      ~section
      ~name:"no_full_batch"
      ~msg:"No full batch to inject and we requested so"
      ~level:Info
      ()

  let batch_success =
    declare_0
      ~section
      ~name:"batch_success"
      ~msg:"transactions were successfully batched"
      ~level:Notice
      ()

  let invalid_transaction =
    declare_1
      ~section
      ~name:"invalid_transaction"
      ~msg:"a batch with this only transaction is invalid: {tr}"
      ("tr", L2_transaction.encoding)

  module Worker = struct
    open Batcher_worker_types

    let section = section @ ["worker"]

    let request_failed =
      declare_3
        ~section
        ~name:"request_failed"
        ~msg:"request {view} failed ({worker_status}): {errors}"
        ~level:Warning
        ("view", Request.encoding)
        ~pp1:Request.pp
        ("worker_status", Worker_types.request_status_encoding)
        ~pp2:Worker_types.pp_status
        ("errors", Error_monad.trace_encoding)
        ~pp3:Error_monad.pp_print_trace

    let request_completed_notice =
      declare_2
        ~section
        ~name:"request_completed_notice"
        ~msg:"{view} {worker_status}"
        ~level:Notice
        ("view", Request.encoding)
        ("worker_status", Worker_types.request_status_encoding)
        ~pp1:Request.pp
        ~pp2:Worker_types.pp_status

    let request_completed_debug =
      declare_2
        ~section
        ~name:"request_completed_debug"
        ~msg:"{view} {worker_status}"
        ~level:Debug
        ("view", Request.encoding)
        ("worker_status", Worker_types.request_status_encoding)
        ~pp1:Request.pp
        ~pp2:Worker_types.pp_status
  end
end

module Accuser = struct
  let section = section @ ["accuser"]

  let bad_finalized_commitment =
    declare_1
      ~name:"bad_finalized_commitment"
      ~msg:"Commitment at level {level} is bad but already finalized!!!"
      ~level:Error
      ("level", Protocol.Alpha_context.Tx_rollup_level.encoding)

  let inbox_merkle_root_mismatch =
    declare_2
      ~name:"inbox_merkle_root_mismatch"
      ~msg:
        "Inbox merkle root for commitment on L1 {l1_merkle_root} is different \
         from the one computed by the rollup node {our_merkle_root}"
      ~level:Warning
      ( "l1_merkle_root",
        Protocol.Alpha_context.Tx_rollup_inbox.Merkle.root_encoding )
      ( "our_merkle_root",
        Protocol.Alpha_context.Tx_rollup_inbox.Merkle.root_encoding )

  let commitment_predecessor_mismatch =
    declare_2
      ~name:"commitment_predecessor_mismatch"
      ~msg:
        "Commitment predecessor L1 {l1_predecessor} is different from the one \
         computed by the rollup node {our_predecessor}"
      ~level:Warning
      ( "l1_predecessor",
        Data_encoding.option
          Protocol.Alpha_context.Tx_rollup_commitment_hash.encoding )
      ( "our_predecessor",
        Data_encoding.option
          Protocol.Alpha_context.Tx_rollup_commitment_hash.encoding )

  let bad_commitment =
    declare_2
      ~name:"bad_commitment"
      ~msg:
        "Detected a bad (rejectable) commitment at level {level} for message \
         at position {position}"
      ~level:Warning
      ("level", Protocol.Alpha_context.Tx_rollup_level.encoding)
      ("position", Data_encoding.int31)
end
