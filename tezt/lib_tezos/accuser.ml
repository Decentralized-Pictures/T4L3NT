(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
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
    base_dir : string;
    node_rpc_port : int;
    mutable pending_ready : unit option Lwt.u list;
  }

  type session_state = {mutable ready : bool}

  let base_default_name = "accuser"

  let default_colors =
    Log.Color.
      [|BG.yellow ++ FG.black; BG.yellow ++ FG.white; BG.yellow ++ FG.blue|]
end

open Parameters
include Daemon.Make (Parameters)

let node_rpc_port accuser = accuser.persistent_state.node_rpc_port

let trigger_ready accuser value =
  let pending = accuser.persistent_state.pending_ready in
  accuser.persistent_state.pending_ready <- [] ;
  List.iter (fun pending -> Lwt.wakeup_later pending value) pending

let set_ready accuser =
  ( match accuser.status with
  | Not_running ->
      ()
  | Running status ->
      status.session_state.ready <- true ) ;
  trigger_ready accuser (Some ())

let handle_raw_stdout accuser line =
  match line with
  (* The accuser is ready when it communicates with a bootstrapped node. *)
  | "Accuser started." ->
      set_ready accuser
  | _ ->
      ()

let create ?(path = Constant.alpha_accuser) ?name ?color ?event_pipe ?base_dir
    node =
  let node_rpc_port = Node.rpc_port node in
  let name = match name with None -> fresh_name () | Some name -> name in
  let base_dir =
    match base_dir with None -> Temp.dir name | Some dir -> dir
  in
  let accuser =
    create
      ~path
      ?name:(Some name)
      ?color
      ?event_pipe
      {base_dir; node_rpc_port; pending_ready = []}
  in
  on_stdout accuser (handle_raw_stdout accuser) ;
  accuser

let run accuser =
  ( match accuser.status with
  | Not_running ->
      ()
  | Running _ ->
      Test.fail "accuser %s is already running" accuser.name ) ;
  let arguments =
    [ "-E";
      "http://localhost:"
      ^ string_of_int accuser.persistent_state.node_rpc_port;
      "--base-dir";
      accuser.persistent_state.base_dir;
      "run" ]
  in
  let on_terminate _ =
    (* Cancel all [Ready] event listeners. *)
    trigger_ready accuser None ; unit
  in
  run accuser {ready = false} arguments ~on_terminate

let check_event ?where accuser name promise =
  let* result = promise in
  match result with
  | None ->
      raise
        (Terminated_before_event {daemon = accuser.name; event = name; where})
  | Some x ->
      return x

let wait_for_ready accuser =
  match accuser.status with
  | Running {session_state = {ready = true; _}; _} ->
      unit
  | Not_running | Running {session_state = {ready = false; _}; _} ->
      let (promise, resolver) = Lwt.task () in
      accuser.persistent_state.pending_ready <-
        resolver :: accuser.persistent_state.pending_ready ;
      check_event accuser "Accuser started." promise

let init ?path ?name ?color ?event_pipe ?base_dir node =
  let* () = Node.wait_for_ready node in
  let accuser = create ?path ?name ?color ?event_pipe ?base_dir node in
  let* () = run accuser in
  return accuser

let restart accuser =
  let* () = terminate accuser in
  let* () = run accuser in
  wait_for_ready accuser
