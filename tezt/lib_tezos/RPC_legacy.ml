(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

type ctxt_type = Bytes | Json

module Seed = struct
  let get_seed ?endpoint ?hooks ?(chain = "main") ?(block = "head") client =
    let path = ["chains"; chain; "blocks"; block; "context"; "seed"] in
    let* json = Client.rpc ?endpoint ?hooks POST path client in
    return (JSON.as_string json)

  let get_seed_status ?endpoint ?hooks ?(chain = "main") ?(block = "head")
      client =
    let path =
      ["chains"; chain; "blocks"; block; "context"; "seed_computation"]
    in
    Client.rpc ?endpoint ?hooks GET path client
end

module Script_cache = struct
  let get_cached_contracts ?endpoint ?hooks ?(chain = "main") ?(block = "head")
      client =
    let path =
      ["chains"; chain; "blocks"; block; "context"; "cache"; "contracts"; "all"]
    in
    Client.rpc ?endpoint ?hooks GET path client
end

module Tx_rollup = struct
  let sub_path ?(chain = "main") ?(block = "head") ~rollup sub =
    ["chains"; chain; "blocks"; block; "context"; "tx_rollup"; rollup] @ sub

  let get_state ?endpoint ?hooks ?chain ?block ~rollup client =
    let path = sub_path ?chain ?block ~rollup ["state"] in
    Client.Spawn.rpc ?endpoint ?hooks GET path client

  let get_inbox ?endpoint ?hooks ?chain ?block ~rollup ~level client =
    let path =
      sub_path ?chain ?block ~rollup ["inbox"; Format.sprintf "%d" level]
    in
    Client.Spawn.rpc ?endpoint ?hooks GET path client

  let get_commitment ?endpoint ?hooks ?(chain = "main") ?(block = "head")
      ~rollup ~level client =
    let path =
      sub_path ~chain ~block ~rollup ["commitment"; Format.sprintf "%d" level]
    in
    Client.Spawn.rpc ?endpoint ?hooks GET path client

  let get_pending_bonded_commitments ?endpoint ?hooks ?(chain = "main")
      ?(block = "head") ~rollup ~pkh client =
    let path =
      sub_path ~chain ~block ~rollup ["pending_bonded_commitments"; pkh]
    in
    Client.Spawn.rpc ?endpoint ?hooks GET path client

  module Forge = struct
    module Inbox = struct
      let message_hash ?endpoint ?hooks ?(chain = "main") ?(block = "head")
          ~data client =
        let path =
          [
            "chains";
            chain;
            "blocks";
            block;
            "helpers";
            "forge";
            "tx_rollup";
            "inbox";
            "message_hash";
          ]
        in
        Client.Spawn.rpc ?endpoint ?hooks ~data POST path client

      let merkle_tree_hash ?endpoint ?hooks ?(chain = "main") ?(block = "head")
          ~data client =
        let path =
          [
            "chains";
            chain;
            "blocks";
            block;
            "helpers";
            "forge";
            "tx_rollup";
            "inbox";
            "merkle_tree_hash";
          ]
        in
        Client.Spawn.rpc ?endpoint ?hooks ~data POST path client

      let merkle_tree_path ?endpoint ?hooks ?(chain = "main") ?(block = "head")
          ~data client =
        let path =
          [
            "chains";
            chain;
            "blocks";
            block;
            "helpers";
            "forge";
            "tx_rollup";
            "inbox";
            "merkle_tree_path";
          ]
        in
        Client.Spawn.rpc ?endpoint ?hooks ~data POST path client
    end

    module Commitment = struct
      let merkle_tree_hash ?endpoint ?hooks ?(chain = "main") ?(block = "head")
          ~data client =
        let path =
          [
            "chains";
            chain;
            "blocks";
            block;
            "helpers";
            "forge";
            "tx_rollup";
            "commitment";
            "merkle_tree_hash";
          ]
        in
        Client.Spawn.rpc ?endpoint ?hooks ~data POST path client

      let merkle_tree_path ?endpoint ?hooks ?(chain = "main") ?(block = "head")
          ~data client =
        let path =
          [
            "chains";
            chain;
            "blocks";
            block;
            "helpers";
            "forge";
            "tx_rollup";
            "commitment";
            "merkle_tree_path";
          ]
        in
        Client.Spawn.rpc ?endpoint ?hooks ~data POST path client

      let message_result_hash ?endpoint ?hooks ?(chain = "main")
          ?(block = "head") ~data client =
        let path =
          [
            "chains";
            chain;
            "blocks";
            block;
            "helpers";
            "forge";
            "tx_rollup";
            "commitment";
            "message_result_hash";
          ]
        in
        Client.Spawn.rpc ?endpoint ?hooks ~data POST path client
    end

    module Withdraw = struct
      let withdraw_list_hash ?endpoint ?hooks ?(chain = "main")
          ?(block = "head") ~data client =
        let path =
          [
            "chains";
            chain;
            "blocks";
            block;
            "helpers";
            "forge";
            "tx_rollup";
            "withdraw";
            "withdraw_list_hash";
          ]
        in
        Client.Spawn.rpc ?endpoint ?hooks ~data POST path client
    end
  end
end

let raw_bytes ?endpoint ?hooks ?(chain = "main") ?(block = "head") ?(path = [])
    client =
  let path =
    ["chains"; chain; "blocks"; block; "context"; "raw"; "bytes"] @ path
  in
  Client.rpc ?endpoint ?hooks GET path client

module Curl = struct
  let curl_path_cache = ref None

  let get () =
    Process.(
      try
        let* curl_path =
          match !curl_path_cache with
          | Some curl_path -> return curl_path
          | None ->
              let* curl_path =
                run_and_read_stdout "sh" ["-c"; "command -v curl"]
              in
              let curl_path = String.trim curl_path in
              curl_path_cache := Some curl_path ;
              return curl_path
        in
        return
        @@ Some
             (fun ~url ->
               let* output = run_and_read_stdout curl_path ["-s"; url] in
               return (JSON.parse ~origin:url output))
      with _ -> return @@ None)

  let post () =
    Process.(
      try
        let* curl_path =
          match !curl_path_cache with
          | Some curl_path -> return curl_path
          | None ->
              let* curl_path =
                run_and_read_stdout "sh" ["-c"; "command -v curl"]
              in
              let curl_path = String.trim curl_path in
              curl_path_cache := Some curl_path ;
              return curl_path
        in
        return
        @@ Some
             (fun ~url data ->
               let* output =
                 run_and_read_stdout
                   curl_path
                   [
                     "-X";
                     "POST";
                     "-H";
                     "Content-Type: application/json";
                     "-s";
                     url;
                     "-d";
                     JSON.encode data;
                   ]
               in
               return (JSON.parse ~origin:url output))
      with _ -> return @@ None)
end
