(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Marigold <contact@marigold.dev>                        *)
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

let make ?data ?query_string =
  RPC.make
    ?data
    ?query_string
    ~get_host:Dac_node.rpc_host
    ~get_port:Dac_node.rpc_port
    ~get_scheme:(Fun.const "http")

(** [encode_bytes_for_json raw] encodes arbitrary byte sequence as hex string for JSON *)
let encode_bytes_to_hex_string raw =
  "\"" ^ match Hex.of_string raw with `Hex s -> s ^ "\""

let decode_hex_string_to_bytes s = Hex.to_string (`Hex s)

let get_bytes_from_json_string_node json =
  JSON.as_string json |> decode_hex_string_to_bytes

let get_preimage page_hash = make GET ["preimage"; page_hash] JSON.as_string

let post_store_preimage ~payload ~pagination_scheme =
  let preimage =
    JSON.parse
      ~origin:"dal_node_dac_store_preimage_rpc"
      (Format.sprintf
         {|{"payload":%s,"pagination_scheme":"%s"}|}
         (encode_bytes_to_hex_string payload)
         pagination_scheme)
  in
  let data : RPC_core.data = Data (JSON.unannotate preimage) in
  make ~data POST ["store_preimage"] @@ fun json ->
  JSON.
    ( json |-> "root_hash" |> as_string,
      json |-> "external_message" |> get_bytes_from_json_string_node )

let get_verify_signature external_msg =
  let query_string =
    [("external_message", match Hex.of_string external_msg with `Hex s -> s)]
  in
  make ~query_string GET ["verify_signature"] JSON.as_bool

let put_dac_member_signature ~hex_root_hash ~dac_member_pkh ~signature =
  let (`Hex root_hash) = hex_root_hash in
  let payload =
    `O
      [
        ("root_hash", `String root_hash);
        ("signer_pkh", `String dac_member_pkh);
        ( "signature",
          `String (Tezos_crypto.Aggregate_signature.to_b58check signature) );
      ]
  in
  let data : RPC_core.data = Data payload in
  make ~data PUT ["dac_member_signature"] @@ fun _resp -> ()

let get_certificate ~hex_root_hash =
  let (`Hex page_hash) = hex_root_hash in
  make GET ["certificates"; page_hash] @@ fun json ->
  JSON.
    ( json |-> "witnesses" |> as_int,
      json |-> "aggregate_signature" |> as_string,
      json |-> "root_hash" |> as_string )

let get_missing_page ~hex_root_hash =
  make GET ["missing_page"; Hex.show hex_root_hash] JSON.as_string

module Coordinator = struct
  let post_preimage ~payload =
    let preimage =
      JSON.parse
        ~origin:"Rollup.DAC.RPC.coordinator_post_preimage"
        (encode_bytes_to_hex_string payload)
    in
    let data : RPC_core.data = Data (JSON.unannotate preimage) in
    make ~data POST ["preimage"] JSON.as_string
end
