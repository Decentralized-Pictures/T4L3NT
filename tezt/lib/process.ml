(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2020 Metastate AG <hello@metastate.dev>                     *)
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

open Base
module String_map = Map.Make (String)

(* An [echo] represents the standard output or standard error output of a process.
   Those outputs are duplicated: one copy is automatically logged,
   the other goes into [lwt_channel] so that the user can read it.

   Strings of [queue] are never empty. *)
type echo = {
  queue : string Queue.t;
  mutable lwt_channel : Lwt_io.input_channel option;
  mutable closed : bool;
  mutable pending : unit Lwt.u list;
}

let on_log = ref None

let on_spawn = ref None

let wake_up_echo echo =
  let pending = echo.pending in
  echo.pending <- [] ;
  List.iter (fun pending -> Lwt.wakeup_later pending ()) pending

let push_to_echo echo string =
  if String.length string > 0 then (
    Queue.push string echo.queue ;
    wake_up_echo echo )

let close_echo echo =
  if not echo.closed then (
    echo.closed <- true ;
    wake_up_echo echo )

let create_echo () =
  let echo =
    {queue = Queue.create (); lwt_channel = None; closed = false; pending = []}
  in
  let rec read bytes ofs len =
    match Queue.take_opt echo.queue with
    | None ->
        if echo.closed then return 0
        else
          (* Nothing to read, for now. *)
          let (promise, resolver) = Lwt.task () in
          echo.pending <- resolver :: echo.pending ;
          let* () = promise in
          read bytes ofs len
    | Some str ->
        (* We won't use [str] after that so [Bytes.unsafe_from_string] is safe. *)
        let str_len = String.length str in
        if str_len <= len then (
          Lwt_bytes.blit_from_bytes
            (Bytes.unsafe_of_string str)
            0
            bytes
            ofs
            str_len ;
          return str_len )
        else (
          Lwt_bytes.blit_from_bytes
            (Bytes.unsafe_of_string str)
            0
            bytes
            ofs
            len ;
          push_to_echo echo (String.sub str len (str_len - len)) ;
          return len )
  in
  let lwt_channel = Lwt_io.(make ~mode:input) read in
  echo.lwt_channel <- Some lwt_channel ;
  echo

let get_echo_lwt_channel echo =
  match echo.lwt_channel with
  | None ->
      (* Impossible: [lwt_channel] is filled by [Some ...] immediately after the [echo]
           is created by [create_echo]. *)
      assert false
  | Some lwt_channel ->
      lwt_channel

type t = {
  id : int;
  name : string;
  command : string;
  arguments : string list;
  color : Log.Color.t;
  lwt_process : Lwt_process.process_full;
  log_status_on_exit : bool;
  stdout : echo;
  stderr : echo;
}

let get_unique_name =
  let name_counts = ref String_map.empty in
  fun name ->
    let index =
      match String_map.find_opt name !name_counts with
      | None ->
          0
      | Some i ->
          i
    in
    name_counts := String_map.add name (index + 1) !name_counts ;
    name ^ "#" ^ string_of_int index

let fresh_id =
  let next = ref 0 in
  fun () ->
    let id = !next in
    incr next ; id

module ID_map = Map.Make (Int)

let live_processes = ref ID_map.empty

let show_signal code =
  if code = Sys.sigabrt then "SIGABRT"
  else if code = Sys.sigalrm then "SIGALRM"
  else if code = Sys.sigfpe then "SIGFPE"
  else if code = Sys.sighup then "SIGHUP"
  else if code = Sys.sigill then "SIGILL"
  else if code = Sys.sigint then "SIGINT"
  else if code = Sys.sigkill then "SIGKILL"
  else if code = Sys.sigpipe then "SIGPIPE"
  else if code = Sys.sigquit then "SIGQUIT"
  else if code = Sys.sigsegv then "SIGSEGV"
  else if code = Sys.sigterm then "SIGTERM"
  else if code = Sys.sigusr1 then "SIGUSR1"
  else if code = Sys.sigusr2 then "SIGUSR2"
  else if code = Sys.sigchld then "SIGCHLD"
  else if code = Sys.sigcont then "SIGCONT"
  else if code = Sys.sigstop then "SIGSTOP"
  else if code = Sys.sigtstp then "SIGTSTP"
  else if code = Sys.sigttin then "SIGTTIN"
  else if code = Sys.sigttou then "SIGTTOU"
  else if code = Sys.sigvtalrm then "SIGVTALRM"
  else if code = Sys.sigprof then "SIGPROF"
  else if code = Sys.sigbus then "SIGBUS"
  else if code = Sys.sigpoll then "SIGPOLL"
  else if code = Sys.sigsys then "SIGSYS"
  else if code = Sys.sigtrap then "SIGTRAP"
  else if code = Sys.sigurg then "SIGURG"
  else if code = Sys.sigxcpu then "SIGXCPU"
  else if code = Sys.sigxfsz then "SIGXFSZ"
  else string_of_int code

let wait process =
  let* status = (process.lwt_process)#status in
  (* If we already removed [process] from [!live_processes], we already logged
     the exit status. *)
  if ID_map.mem process.id !live_processes then (
    live_processes := ID_map.remove process.id !live_processes ;
    if process.log_status_on_exit then
      match status with
      | WEXITED code ->
          Log.debug "%s exited with code %d." process.name code
      | WSIGNALED code ->
          Log.debug
            "%s was killed by signal %s."
            process.name
            (show_signal code)
      | WSTOPPED code ->
          Log.debug
            "%s was stopped by signal %s."
            process.name
            (show_signal code) ) ;
  return status

(* Read process outputs and log them.
   Also take care of removing the process from [live_processes] on termination. *)
let handle_process ~log_output process =
  let rec handle_output name (ch : Lwt_io.input_channel) echo =
    let* line = Lwt_io.read_line_opt ch in
    match line with
    | None ->
        close_echo echo ; Lwt_io.close ch
    | Some line ->
        if log_output then (
          Log.debug ~prefix:name ~color:process.color "%s" line ;
          Option.iter (fun f -> f line) !on_log ) ;
        push_to_echo echo line ;
        (* TODO: here we assume that all lines end with "\n",
             but it may not always be the case:
             - there may be lines ending with "\r\n";
             - the last line may not end with "\n" before the EOF. *)
        push_to_echo echo "\n" ;
        handle_output name ch echo
  in
  let* () =
    handle_output process.name (process.lwt_process)#stdout process.stdout
  and* () =
    handle_output process.name (process.lwt_process)#stderr process.stderr
  and* _ = wait process in
  unit

let spawn_with_stdin ?(log_status_on_exit = true) ?(log_output = true) ?name
    ?(color = Log.Color.FG.cyan) ?(env = []) command arguments =
  let name =
    match name with None -> get_unique_name command | Some name -> name
  in
  Option.iter (fun f -> f command arguments) !on_spawn ;
  Log.command ~color:Log.Color.bold ~prefix:name command arguments ;
  let old_env =
    let not_modified item =
      match String.split_on_char '=' item with
      | name :: _ ->
          List.for_all (fun (new_name, _) -> name <> new_name) env
      | _ ->
          (* Weird. Let's remove this. *)
          false
    in
    Unix.environment () |> Array.to_list |> List.filter not_modified
    |> Array.of_list
  in
  let new_env =
    List.map (fun (name, value) -> name ^ "=" ^ value) env |> Array.of_list
  in
  let env = Array.append old_env new_env in
  let lwt_process =
    Lwt_process.open_process_full
      ~env
      (command, Array.of_list (command :: arguments))
  in
  let process =
    {
      id = fresh_id ();
      name;
      command;
      arguments;
      color;
      lwt_process;
      log_status_on_exit;
      stdout = create_echo ();
      stderr = create_echo ();
    }
  in
  live_processes := ID_map.add process.id process !live_processes ;
  async (handle_process ~log_output process) ;
  (process, (process.lwt_process)#stdin)

let spawn ?log_status_on_exit ?log_output ?name ?color ?env command arguments =
  let (process, stdin) =
    spawn_with_stdin
      ?log_status_on_exit
      ?log_output
      ?name
      ?color
      ?env
      command
      arguments
  in
  async (Lwt_io.close stdin) ;
  process

let terminate process =
  Log.debug "Send SIGTERM to %s." process.name ;
  (process.lwt_process)#kill Sys.sigterm

let kill process =
  Log.debug "Send SIGKILL to %s." process.name ;
  (process.lwt_process)#terminate

exception
  Failed of {
    name : string;
    command : string;
    arguments : string list;
    status : Unix.process_status;
    expect_failure : bool;
  }

let () =
  Printexc.register_printer
  @@ function
  | Failed {name; command; arguments; status; expect_failure} ->
      let reason =
        match status with
        | WEXITED code ->
            Printf.sprintf "exited with code %d" code
        | WSIGNALED code ->
            Printf.sprintf "was killed by signal %d" code
        | WSTOPPED code ->
            Printf.sprintf "was killed by signal %d" code
      in
      Some
        (Printf.sprintf
           "%s%s %s (full command: %s)"
           name
           (if expect_failure then " was expected to fail," else "")
           reason
           (String.concat " " (List.map Log.quote_shell (command :: arguments))))
  | _ ->
      None

let check ?(expect_failure = false) process =
  let* status = wait process in
  match status with
  | WEXITED n when (n = 0 && not expect_failure) || (n <> 0 && expect_failure)
    ->
      unit
  | _ ->
      raise
        (Failed
           {
             name = process.name;
             command = process.command;
             arguments = process.arguments;
             status;
             expect_failure;
           })

let run ?log_status_on_exit ?name ?color ?env ?expect_failure command arguments
    =
  spawn ?log_status_on_exit ?name ?color ?env command arguments
  |> check ?expect_failure

let clean_up () =
  let list = ID_map.bindings !live_processes |> List.map snd in
  List.iter terminate list ;
  Lwt_list.iter_p
    (fun process ->
      let* _ = wait process in
      unit)
    list

let stdout process = get_echo_lwt_channel process.stdout

let stderr process = get_echo_lwt_channel process.stderr

let name process = process.name

let check_and_read_stdout ?expect_failure process =
  let* () = check ?expect_failure process
  and* output = read_all (stdout process) in
  return output

let check_and_read_stderr ?expect_failure process =
  let* () = check ?expect_failure process
  and* output = read_all (stderr process) in
  return output

let run_and_read_stdout ?log_status_on_exit ?name ?color ?env ?expect_failure
    command arguments =
  let process =
    spawn ?log_status_on_exit ?name ?color ?env command arguments
  in
  check_and_read_stdout ?expect_failure process

let run_and_read_stderr ?log_status_on_exit ?name ?color ?env ?expect_failure
    command arguments =
  let process =
    spawn ?log_status_on_exit ?name ?color ?env command arguments
  in
  check_and_read_stdout ?expect_failure process
