(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
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

include Internal_event.Simple

let section = ["dal"; "node"]

let starting_node =
  declare_0
    ~section
    ~name:"starting_dal_node"
    ~msg:"Starting the DAL node"
    ~level:Notice
    ()

let shutdown_node =
  declare_1
    ~section
    ~name:"stopping_dal_node"
    ~msg:"Stopping DAL node"
    ~level:Notice
    ("exit_status", Data_encoding.int8)

let store_is_ready =
  declare_0
    ~section
    ~name:"dal_node_store_is_ready"
    ~msg:"The DAL node store is ready"
    ~level:Notice
    ()

let rpc_server_is_ready =
  declare_2
    ~section
    ~name:"dal_node_rpc_server_is_ready"
    ~msg:"The DAL node is listening to {addr}:{port}"
    ~level:Notice
    ("addr", Data_encoding.string)
    ("port", Data_encoding.uint16)

let node_is_ready =
  declare_0
    ~section
    ~name:"dal_node_is_ready"
    ~msg:"The DAL node is ready"
    ~level:Notice
    ()

let dac_is_ready =
  declare_0
    ~section
    ~name:"dac_is_ready"
    ~msg:"The Data Availability Committee is ready"
    ~level:Notice
    ()

let data_dir_not_found =
  declare_1
    ~section
    ~name:"dal_node_no_data_dir"
    ~msg:
      "The DAL node data directory {path} doesn't exists. Create using: \
       init-config --data-dir={path} "
    ~level:Error
    ("path", Data_encoding.(string))

let stored_slot_shards =
  declare_2
    ~section
    ~name:"stored_slot_shards"
    ~msg:"Slot stored: commitment {commitment}, shards {shards}"
    ~level:Notice
    ("commitment", Data_encoding.string)
    ("shards", Data_encoding.int31)

let fetched_slot =
  declare_2
    ~section
    ~name:"fetched_slot"
    ~msg:"Slot fetched: size {size}, shards {shards}"
    ~level:Notice
    ("size", Data_encoding.int31)
    ("shards", Data_encoding.int31)

let layer1_node_new_head =
  declare_2
    ~section
    ~name:"dal_node_layer_1_new_head"
    ~msg:"Head of layer 1's node updated to {hash} at level {level}"
    ~level:Notice
    ("hash", Block_hash.encoding)
    ("level", Data_encoding.int32)

let layer1_node_tracking_started =
  declare_0
    ~section
    ~name:"dal_node_layer_1_start_tracking"
    ~msg:"Started tracking layer 1's node"
    ~level:Notice
    ()

let protocol_plugin_resolved =
  declare_2
    ~section
    ~name:"dal_node_plugin_resolved"
    ~msg:"Resolved plugin for {plugin_name} on protocol {proto_hash}"
    ~level:Notice
    ("plugin_name", Data_encoding.string)
    ("proto_hash", Data_encoding.string)

let daemon_error =
  declare_1
    ~section
    ~name:"dal_node_daemon_error"
    ~msg:"Daemon thrown an error: {error}"
    ~level:Notice
    ~pp1:Error_monad.pp_print_trace
    ("error", Error_monad.trace_encoding)

let dac_threshold_not_reached =
  declare_2
    ~section
    ~name:"dac_threshold_not_reached"
    ~msg:
      "Only {provided} out of {required} dac accounts are available for \
       signing messages"
    ~level:Warning
    ("provided", Data_encoding.int31)
    ("required", Data_encoding.int31)

let dac_account_not_available =
  declare_1
    ~section
    ~name:"dac_account_not_available"
    ~msg:
      "There is no account with public key {tz4_account} in the Tezos client \
       wallet. This account won't be used for signing DAC root hash pages."
    ~level:Warning
    ("tz4_account", Tezos_crypto.Aggregate_signature.Public_key_hash.encoding)

let dac_account_cannot_sign =
  declare_1
    ~section
    ~name:"dac_account_cannot_sign"
    ~msg:
      "There is an account with public key {tz4_account} in the Tezos client \
       wallet, but its secret key URI is not available. This account won't be \
       used for signing DAC root hash pages."
    ~level:Warning
    ("tz4_account", Tezos_crypto.Aggregate_signature.Public_key_hash.encoding)

let proto_short_hash_string hash =
  Format.asprintf "%a" Protocol_hash.pp_short hash

let emit_protocol_plugin_resolved ~plugin_name hash =
  emit protocol_plugin_resolved (plugin_name, proto_short_hash_string hash)
