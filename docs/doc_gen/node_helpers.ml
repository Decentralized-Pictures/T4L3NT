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

let genesis : Genesis.t =
  {
    time = Time.Protocol.of_notation_exn "2018-04-17T11:46:23Z";
    block =
      Block_hash.of_b58check_exn
        "BLockGenesisGenesisGenesisGenesisGenesisa52f8bUWPcg";
    protocol =
      Protocol_hash.of_b58check_exn
        "ProtoGenesisGenesisGenesisGenesisGenesisGenesk612im";
  }

let with_node f =
  let run dir =
    let ( / ) = Filename.concat in
    let node_config : Node.config =
      {
        genesis;
        chain_name = Distributed_db_version.Name.of_string "TEZOS_DOCGEN";
        sandboxed_chain_name =
          Distributed_db_version.Name.of_string "SANDBOXED_TEZOS_DOCGEN";
        user_activated_upgrades = [];
        user_activated_protocol_overrides = [];
        patch_context = None;
        data_dir = dir;
        store_root = dir / "store";
        context_root = dir / "context";
        protocol_root = dir / "protocol";
        p2p = None;
        checkpoint = None;
        disable_mempool = true;
        enable_testchain = false;
      }
    in
    Node.create
      ~singleprocess:true
      node_config
      Node.default_peer_validator_limits
      Node.default_block_validator_limits
      Node.default_prevalidator_limits
      Node.default_chain_validator_limits
      None
    >>=? fun node -> f node >>=? fun () -> return ()
  in
  Lwt_utils_unix.with_tempdir "tezos_rpcdoc_" run
  >>= function
  | Ok () ->
      Lwt.return_unit
  | Error err ->
      Format.eprintf "%a@." pp_print_error err ;
      Stdlib.exit 1
