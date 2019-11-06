(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2019 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Cmdliner
open Node_logging

let ( // ) = Filename.concat

type t = {
  data_dir : string option;
  config_file : string;
  min_connections : int option;
  expected_connections : int option;
  max_connections : int option;
  max_download_speed : int option;
  max_upload_speed : int option;
  binary_chunks_size : int option;
  peer_table_size : int option;
  expected_pow : float option;
  peers : string list;
  no_bootstrap_peers : bool;
  listen_addr : string option;
  discovery_addr : string option;
  rpc_listen_addrs : string list;
  private_mode : bool;
  disable_mempool : bool;
  enable_testchain : bool;
  cors_origins : string list;
  cors_headers : string list;
  rpc_tls : Node_config_file.tls option;
  log_output : Lwt_log_sink_unix.Output.t option;
  bootstrap_threshold : int option;
  history_mode : History_mode.t option;
}

let wrap data_dir config_file connections max_download_speed max_upload_speed
    binary_chunks_size peer_table_size listen_addr discovery_addr peers
    no_bootstrap_peers bootstrap_threshold private_mode disable_mempool
    enable_testchain expected_pow rpc_listen_addrs rpc_tls cors_origins
    cors_headers log_output history_mode =
  let actual_data_dir =
    Option.unopt ~default:Node_config_file.default_data_dir data_dir
  in
  let config_file =
    Option.unopt ~default:(actual_data_dir // "config.json") config_file
  in
  let rpc_tls =
    Option.map ~f:(fun (cert, key) -> {Node_config_file.cert; key}) rpc_tls
  in
  (* when `--connections` is used,
     override all the bounds defined in the configuration file. *)
  let ( bootstrap_threshold,
        min_connections,
        expected_connections,
        max_connections,
        peer_table_size ) =
    match connections with
    | None ->
        (bootstrap_threshold, None, None, None, peer_table_size)
    | Some x -> (
        let peer_table_size =
          match peer_table_size with
          | None ->
              Some (8 * x)
          | Some _ ->
              peer_table_size
        in
        match bootstrap_threshold with
        | None ->
            ( Some (min (x / 4) 2),
              Some (x / 2),
              Some x,
              Some (3 * x / 2),
              peer_table_size )
        | Some bs ->
            (Some bs, Some (x / 2), Some x, Some (3 * x / 2), peer_table_size)
        )
  in
  {
    data_dir;
    config_file;
    min_connections;
    expected_connections;
    max_connections;
    max_download_speed;
    max_upload_speed;
    binary_chunks_size;
    expected_pow;
    peers;
    no_bootstrap_peers;
    listen_addr;
    discovery_addr;
    rpc_listen_addrs;
    private_mode;
    disable_mempool;
    enable_testchain;
    cors_origins;
    cors_headers;
    rpc_tls;
    log_output;
    peer_table_size;
    bootstrap_threshold;
    history_mode;
  }

module Manpage = struct
  let misc_section = "MISC OPTIONS"

  let p2p_section = "P2P OPTIONS"

  let rpc_section = "RPC OPTIONS"

  let args = [`S p2p_section; `S rpc_section; `S misc_section]

  let bugs =
    [ `S "BUGS";
      `P "Check bug reports at https://gitlab.com/tezos/tezos/issues." ]
end

module Term = struct
  let log_output_converter =
    ( (fun s ->
        match Lwt_log_sink_unix.Output.of_string s with
        | Some res ->
            `Ok res
        | None ->
            `Error s),
      Lwt_log_sink_unix.Output.pp )

  let history_mode_converter =
    let open History_mode in
    ( (function
      | "archive" ->
          `Ok Archive
      | "full" ->
          `Ok Full
      | "experimental-rolling" ->
          `Ok Rolling
      | s ->
          `Error s),
      pp )

  (* misc args *)

  let docs = Manpage.misc_section

  let history_mode =
    let doc =
      "Set the mode for the chain's data history storage. Possible values are \
       $(i,archive), $(i,full) (default), $(i,experimental-rolling). Archive \
       mode retains all data since the genesis block. Full mode only \
       maintains block headers and operations allowing replaying the chain \
       since the genesis if wanted. (Experimental-)Rolling mode retains only \
       the most recent data (i.e. from the 5 last cycles) and deletes the \
       rest."
    in
    Arg.(
      value
      & opt (some history_mode_converter) None
      & info ~docs ~doc ~docv:"<mode>" ["history-mode"])

  let log_output =
    let doc =
      "Log output. Either $(i,stdout), $(i,stderr), $(i,syslog:<facility>) or \
       a file path."
    in
    Arg.(
      value
      & opt (some log_output_converter) None
      & info ~docs ~docv:"OUTPUT" ~doc ["log-output"])

  let data_dir =
    let doc = "The directory where the Tezos node will store all its data." in
    Arg.(
      value & opt (some string) None & info ~docs ~doc ~docv:"DIR" ["data-dir"])

  let config_file =
    let doc = "The main configuration file." in
    Arg.(
      value
      & opt (some string) None
      & info ~docs ~doc ~docv:"FILE" ["config-file"])

  (* P2p args *)

  let docs = Manpage.p2p_section

  let connections =
    let doc =
      "Sets min_connections, expected_connections, max_connections to NUM / \
       2, NUM, (3 * NUM) / 2, respectively. Sets peer_table_size to 8 * NUM \
       unless it is already defined in the configuration file. Sets \
       bootstrap_threshold to min(NUM / 4, 2) unless it is already defined in \
       the configuration file."
    in
    Arg.(
      value & opt (some int) None & info ~docs ~doc ~docv:"NUM" ["connections"])

  let max_download_speed =
    let doc = "The maximum number of bytes read per second." in
    Arg.(
      value
      & opt (some int) None
      & info ~docs ~doc ~docv:"NUM" ["max-download-speed"])

  let max_upload_speed =
    let doc = "The maximum number of bytes sent per second." in
    Arg.(
      value
      & opt (some int) None
      & info ~docs ~doc ~docv:"NUM" ["max-upload-speed"])

  let binary_chunks_size =
    let doc =
      "Size limit (in kB) of binary blocks that are sent to other peers."
    in
    Arg.(
      value
      & opt (some int) None
      & info ~docs ~doc ~docv:"NUM" ["binary-chunks-size"])

  let peer_table_size =
    let doc =
      "Maximum size of internal peer tables, used to store metadata/logs \
       about a peer or about a to-be-authenticated host:port couple."
    in
    Arg.(
      value
      & opt (some int) None
      & info ~docs ~doc ~docv:"NUM" ["peer-table-size"])

  let listen_addr =
    let doc =
      "The TCP address and port at which this instance can be reached."
    in
    Arg.(
      value
      & opt (some string) None
      & info ~docs ~doc ~docv:"ADDR:PORT" ["net-addr"])

  let discovery_addr =
    let doc = "The UDP address and port used for local peer discovery." in
    Arg.(
      value
      & opt (some string) None
      & info ~docs ~doc ~docv:"ADDR:PORT" ["discovery-addr"])

  let no_bootstrap_peers =
    let doc =
      "Ignore the peers found in the config file (or the hard-coded bootstrap \
       peers in the absence of config file)."
    in
    Arg.(value & flag & info ~docs ~doc ["no-bootstrap-peers"])

  let bootstrap_threshold =
    let doc =
      "Set the number of peers with whom a chain synchronization must be \
       completed to bootstrap the node"
    in
    Arg.(
      value
      & opt (some int) None
      & info ~docs ~doc ~docv:"NUM" ["bootstrap-threshold"])

  let peers =
    let doc =
      "A peer to bootstrap the network from. Can be used several times to add \
       several peers."
    in
    Arg.(
      value & opt_all string [] & info ~docs ~doc ~docv:"ADDR:PORT" ["peer"])

  let expected_pow =
    let doc = "Expected level of proof-of-work for peers identity." in
    Arg.(
      value
      & opt (some float) None
      & info ~docs ~doc ~docv:"FLOAT" ["expected-pow"])

  let private_mode =
    let doc =
      "Only open outgoing/accept incoming connections to/from peers listed in \
       'bootstrap-peers' or provided with '--peer' option."
    in
    Arg.(value & flag & info ~docs ~doc ["private-mode"])

  let disable_mempool =
    let doc =
      "If set to [true], the node will not participate in the propagation of \
       pending operations (mempool). Default value is [false]. It can be used \
       to decrease the memory and computation footprints of the node."
    in
    Arg.(value & flag & info ~docs ~doc ["disable-mempool"])

  let enable_testchain =
    let doc =
      "If set, the node will spawn a testchain during the protocol's testing \
       voting period. It will increase the node storage usage and computation \
       by additionally validating the test network blocks."
    in
    Arg.(value & flag & info ~docs ~doc ["enable-testchain"])

  (* rpc args *)
  let docs = Manpage.rpc_section

  let rpc_listen_addrs =
    let doc =
      "The TCP socket address at which this RPC server instance can be reached."
    in
    Arg.(
      value & opt_all string [] & info ~docs ~doc ~docv:"ADDR:PORT" ["rpc-addr"])

  let rpc_tls =
    let doc =
      "Enable TLS for this RPC server with the provided certificate and key."
    in
    Arg.(
      value
      & opt (some (pair string string)) None
      & info ~docs ~doc ~docv:"crt,key" ["rpc-tls"])

  let cors_origins =
    let doc =
      "CORS origin allowed by the RPC server via Access-Control-Allow-Origin; \
       may be used multiple times"
    in
    Arg.(
      value & opt_all string [] & info ~docs ~doc ~docv:"ORIGIN" ["cors-origin"])

  let cors_headers =
    let doc =
      "Header reported by Access-Control-Allow-Headers reported during CORS \
       preflighting; may be used multiple times"
    in
    Arg.(
      value & opt_all string [] & info ~docs ~doc ~docv:"HEADER" ["cors-header"])

  (* Args. *)

  let args =
    let open Term in
    const wrap $ data_dir $ config_file $ connections $ max_download_speed
    $ max_upload_speed $ binary_chunks_size $ peer_table_size $ listen_addr
    $ discovery_addr $ peers $ no_bootstrap_peers $ bootstrap_threshold
    $ private_mode $ disable_mempool $ enable_testchain $ expected_pow
    $ rpc_listen_addrs $ rpc_tls $ cors_origins $ cors_headers $ log_output
    $ history_mode
end

let read_config_file args =
  if Sys.file_exists args.config_file then
    Node_config_file.read args.config_file
  else return Node_config_file.default_config

let read_data_dir args =
  read_config_file args
  >>=? fun cfg ->
  let {data_dir; _} = args in
  let data_dir = Option.unopt ~default:cfg.data_dir data_dir in
  return data_dir

let read_and_patch_config_file ?(ignore_bootstrap_peers = false) args =
  read_config_file args
  >>=? fun cfg ->
  let { data_dir;
        min_connections;
        expected_connections;
        max_connections;
        max_download_speed;
        max_upload_speed;
        binary_chunks_size;
        peer_table_size;
        expected_pow;
        peers;
        no_bootstrap_peers;
        listen_addr;
        private_mode;
        discovery_addr;
        disable_mempool;
        enable_testchain;
        rpc_listen_addrs;
        rpc_tls;
        cors_origins;
        cors_headers;
        log_output;
        bootstrap_threshold;
        history_mode;
        config_file = _ } =
    args
  in
  let bootstrap_peers =
    if no_bootstrap_peers || ignore_bootstrap_peers then (
      log_info "Ignoring bootstrap peers" ;
      peers )
    else cfg.p2p.bootstrap_peers @ peers
  in
  Node_config_file.update
    ?data_dir
    ?min_connections
    ?expected_connections
    ?max_connections
    ?max_download_speed
    ?max_upload_speed
    ?binary_chunks_size
    ?peer_table_size
    ?expected_pow
    ~bootstrap_peers
    ?listen_addr
    ?discovery_addr
    ~rpc_listen_addrs
    ~private_mode
    ~disable_mempool
    ~enable_testchain
    ~cors_origins
    ~cors_headers
    ?rpc_tls
    ?log_output
    ?bootstrap_threshold
    ?history_mode
    cfg
