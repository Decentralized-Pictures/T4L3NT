(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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
    runner : Runner.t option;
    base_dir : string;
    uri : Uri.t;
    keys : Account.key list;
    mutable pending_ready : unit option Lwt.u list;
  }

  type session_state = {mutable ready : bool}

  let signer_path = "./octez-signer"

  let base_default_name = "signer"

  let default_uri = Uri.make ~scheme:"http" ~host:"localhost" ~port:17732 ()

  let default_colors =
    Log.Color.
      [|BG.yellow ++ FG.blue; BG.yellow ++ FG.gray; BG.yellow ++ FG.blue|]
end

open Parameters
include Daemon.Make (Parameters)

let uri signer = signer.persistent_state.uri

let trigger_ready signer value =
  let pending = signer.persistent_state.pending_ready in
  signer.persistent_state.pending_ready <- [] ;
  List.iter (fun pending -> Lwt.wakeup_later pending value) pending

let set_ready signer =
  (match signer.status with
  | Not_running -> ()
  | Running status -> status.session_state.ready <- true) ;
  trigger_ready signer (Some ())

let handle_raw_stdout signer line =
  if line =~ rex "^.*accepting HTTP requests on port$" then set_ready signer

let base_dir_arg client = ["--base-dir"; client.base_dir]

let spawn_command ?(env = String_map.empty) ?hooks signer command =
  let env =
    (* Set disclaimer to "Y" if unspecified, otherwise use given value *)
    String_map.update
      "TEZOS_CLIENT_UNSAFE_DISABLE_DISCLAIMER"
      (fun o -> Option.value ~default:"Y" o |> Option.some)
      env
  in
  Process.spawn ~name:signer.name ~color:signer.color ~env ?hooks signer.path
  @@ base_dir_arg signer.persistent_state
  @ command

let passfile = ref ""

let spawn_import_secret_key signer (key : Account.key) =
  match key.secret_key with
  | Unencrypted sk ->
      let sk_uri = "unencrypted:" ^ sk in
      spawn_command signer ["import"; "secret"; "key"; key.alias; sk_uri]

let import_secret_key signer (key : Account.key) =
  spawn_import_secret_key signer key |> Process.check

let create ?name ?color ?event_pipe ?base_dir ?(uri = Parameters.default_uri)
    ?runner ?(keys = [Constant.bootstrap1]) () =
  let name = match name with None -> fresh_name () | Some name -> name in
  let base_dir =
    match base_dir with None -> Temp.dir name | Some dir -> dir
  in
  let signer =
    create
      ~path:signer_path
      ?name:(Some name)
      ?color
      ?event_pipe
      ?runner
      {runner; base_dir; uri; keys; pending_ready = []}
  in
  on_stdout signer (handle_raw_stdout signer) ;
  let* () = Lwt_list.iter_s (import_secret_key signer) keys in
  return signer

let run signer =
  (match signer.status with
  | Not_running -> ()
  | Running _ -> Test.fail "signer %s is already running" signer.name) ;
  let runner = signer.persistent_state.runner in
  let host =
    Option.value ~default:"localhost" (Uri.host signer.persistent_state.uri)
  in
  let port =
    Option.value ~default:7732 (Uri.port signer.persistent_state.uri)
  in
  let arguments =
    [
      "--base-dir";
      signer.persistent_state.base_dir;
      "launch";
      "http";
      "signer";
      "--address";
      host;
      "--port";
      Int.to_string port;
    ]
  in
  let arguments =
    if !passfile = "" then arguments
    else ["--password-filename"; !passfile] @ arguments
  in
  let on_terminate _ =
    (* Cancel all [Ready] event listeners. *)
    trigger_ready signer None ;
    unit
  in
  run signer {ready = false} arguments ~on_terminate ?runner

let check_event ?where signer name promise =
  let* result = promise in
  match result with
  | None ->
      raise
        (Terminated_before_event {daemon = signer.name; event = name; where})
  | Some x -> return x

let wait_for_ready signer =
  match signer.status with
  | Running {session_state = {ready = true; _}; _} -> unit
  | Not_running | Running {session_state = {ready = false; _}; _} ->
      let promise, resolver = Lwt.task () in
      signer.persistent_state.pending_ready <-
        resolver :: signer.persistent_state.pending_ready ;
      check_event signer "Signer started." promise

let init ?name ?color ?event_pipe ?base_dir ?uri ?runner ?keys () =
  let* signer =
    create ?name ?color ?event_pipe ?base_dir ?uri ?runner ?keys ()
  in
  let* () = run signer in
  return signer

let restart signer =
  let* () = terminate signer in
  let* () = run signer in
  wait_for_ready signer
