(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs <contact@nomadic-labs.com>                *)
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

module Parameters = struct
  type persistent_state = {
    arguments : string list;
    mutable pending_ready : unit option Lwt.u list;
    rpc_addr : string;
    rpc_port : int;
    rollup_node : Sc_rollup_node.t;
    runner : Runner.t option;
  }

  type session_state = {mutable ready : bool}

  let base_default_name = "evm_proxy_server"

  let default_colors = Log.Color.[|FG.magenta|]
end

open Parameters
include Daemon.Make (Parameters)

let path = "./octez-evm-proxy-server"

let connection_arguments ?rpc_addr ?rpc_port rollup_node_endpoint =
  let open Cli_arg in
  let rpc_port =
    match rpc_port with None -> Port.fresh () | Some port -> port
  in
  ( [
      "--rollup-node-endpoint";
      rollup_node_endpoint;
      "--rpc-port";
      string_of_int rpc_port;
    ]
    @ optional_arg "--rpc-addr" Fun.id rpc_addr,
    Option.value ~default:"127.0.0.1" rpc_addr,
    rpc_port )

let trigger_ready sc_node value =
  let pending = sc_node.persistent_state.pending_ready in
  sc_node.persistent_state.pending_ready <- [] ;
  List.iter (fun pending -> Lwt.wakeup_later pending value) pending

let set_ready proxy_server =
  (match proxy_server.status with
  | Not_running -> ()
  | Running status -> status.session_state.ready <- true) ;
  trigger_ready proxy_server (Some ())

let event_ready_name = "evm_proxy_server_is_ready.v0"

let handle_event (proxy_server : t) {name; value = _; timestamp = _} =
  if name = event_ready_name then set_ready proxy_server else ()

let check_event proxy_server name promise =
  let* result = promise in
  match result with
  | None ->
      raise
        (Terminated_before_event
           {daemon = proxy_server.name; event = name; where = None})
  | Some x -> return x

let wait_for_ready proxy_server =
  match proxy_server.status with
  | Running {session_state = {ready = true; _}; _} -> unit
  | Not_running | Running {session_state = {ready = false; _}; _} ->
      let promise, resolver = Lwt.task () in
      proxy_server.persistent_state.pending_ready <-
        resolver :: proxy_server.persistent_state.pending_ready ;
      check_event proxy_server event_ready_name promise

let create ?runner ?rpc_addr ?rpc_port rollup_node =
  let rollup_node_endpoint = Sc_rollup_node.endpoint rollup_node in
  let arguments, rpc_addr, rpc_port =
    connection_arguments ?rpc_addr ?rpc_port rollup_node_endpoint
  in
  let proxy_server =
    create
      ~path
      {arguments; pending_ready = []; rpc_addr; rpc_port; rollup_node; runner}
  in
  on_event proxy_server (handle_event proxy_server) ;
  proxy_server

let run proxy_server =
  let* () =
    run
      proxy_server
      {ready = false}
      (["run"] @ proxy_server.persistent_state.arguments)
  in
  let* () = wait_for_ready proxy_server in
  unit

let spawn_command proxy_server args =
  Process.spawn ?runner:proxy_server.persistent_state.runner path @@ args

let spawn_run proxy_server =
  spawn_command proxy_server (["run"] @ proxy_server.persistent_state.arguments)

let endpoint (proxy_server : t) =
  Format.sprintf
    "http://%s:%d"
    proxy_server.persistent_state.rpc_addr
    proxy_server.persistent_state.rpc_port

let init ?runner ?rpc_addr ?rpc_port rollup_node =
  let proxy_server = create ?runner ?rpc_addr ?rpc_port rollup_node in
  let* () = run proxy_server in
  return proxy_server

let request method_ parameters : JSON.t =
  `O
    [
      ("jsonrpc", `String "2.0");
      ("method", `String method_);
      ("params", parameters);
      ("id", `String "0");
    ]
  |> JSON.annotate ~origin:"evm_proxy_server"

let call_evm_rpc proxy_server ~method_ ~parameters =
  let endpoint = endpoint proxy_server in
  RPC.Curl.post endpoint (request method_ parameters) |> Runnable.run
