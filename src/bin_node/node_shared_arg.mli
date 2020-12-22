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

type t = {
  data_dir : string option;
  config_file : string;
  network : Node_config_file.blockchain_network option;
  connections : int option;
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
  synchronisation_threshold : int option;
  latency : int option;
}

module Term : sig
  val args : t Cmdliner.Term.t

  val data_dir : string option Cmdliner.Term.t

  val config_file : string option Cmdliner.Term.t
end

val read_data_dir : t -> string tzresult Lwt.t

val read_and_patch_config_file :
  ?may_override_network:bool ->
  ?ignore_bootstrap_peers:bool ->
  t ->
  Node_config_file.t tzresult Lwt.t

module Manpage : sig
  val misc_section : string

  val args : Cmdliner.Manpage.block list

  val bugs : Cmdliner.Manpage.block list
end
