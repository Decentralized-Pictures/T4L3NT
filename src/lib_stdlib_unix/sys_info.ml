(*****************************************************************************)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Memory
open Error_monad

type Error_monad.error += Unix_system_info_failure of string

let () =
  Error_monad.register_error_kind
    `Temporary
    ~id:"unix.system_info"
    ~title:"Unix System_info failure"
    ~description:"Unix System_info failure"
    ~pp:(fun ppf s ->
      Format.fprintf ppf "@[<v 2>Unix system_info failure %s@]" s)
    Data_encoding.(obj1 (req "failure" string))
    (function Unix_system_info_failure s -> Some s | _ -> None)
    (fun s -> Unix_system_info_failure s)

let error_info process error =
  Unix_system_info_failure
    (Format.asprintf "Unix_system_info_failure (%s: %s)" process error)

type sysname = Linux | Darwin | Unknown of string

let uname =
  Lwt.catch
    (fun () ->
      Lwt_process.with_process_in
        ~env:[|"LC_ALL=C"|]
        ("uname", [|"uname"|])
        (fun pc -> Lwt_io.read_line pc#stdout)
      >>= function
      | "Linux" ->
          Lwt.return_ok Linux
      | "Darwin" ->
          Lwt.return_ok Darwin
      | os ->
          Lwt.return_ok (Unknown os))
    (function
      | exn -> Lwt.return_error (error_info "uname" (Printexc.to_string exn)))

let page_size () =
  let get_conf_process =
    uname
    >>= function
    | Ok Linux ->
        Lwt.return_ok ("getconf", [|"getconf"; "PAGE_SIZE"|])
    | Ok Darwin ->
        Lwt.return_ok ("pagesize", [|"pagesize"|])
    | Ok (Unknown _) ->
        Lwt.return_error (error_info "pagesize" "Unknown unix system")
    | Error (Unix_system_info_failure e) ->
        Lwt.return_error (error_info "pagesize" e)
    | Error e ->
        Lwt.return_error e
  in
  get_conf_process
  >>= function
  | Error e ->
      Lwt.return_error e
  | Ok process ->
      Lwt.catch
        (fun () ->
          Lwt_process.with_process_in process ~env:[|"LC_ALL=C"|] (fun pc ->
              Lwt_io.read_line pc#stdout
              >>= fun ps -> Lwt.return_ok (int_of_string ps)))
        (function
          | exn ->
              Lwt.return_error (error_info "pagesize" (Printexc.to_string exn)))

let linux_statm pid =
  Lwt.catch
    (fun () ->
      let fname = Format.asprintf "/proc/%d/statm" pid in
      Lwt_unix.file_exists fname
      >>= function
      | true ->
          Lwt_io.with_file ~mode:Input fname (fun ic ->
              Lwt_io.read_line ic
              >>= fun line ->
              match List.map Int64.of_string @@ TzString.split ' ' line with
              | size :: resident :: shared :: text :: lib :: data :: dt :: _
                -> (
                  page_size ()
                  >>= function
                  | Error e ->
                      Lwt.return_error e
                  | Ok page_size ->
                      Lwt.return_ok
                        (Statm
                           {
                             page_size;
                             size;
                             resident;
                             shared;
                             text;
                             lib;
                             data;
                             dt;
                           }) )
              | _ ->
                  Lwt.return_error
                    (error_info
                       "procfs statm"
                       "Unexpected proc/<pid>/statm format"))
      | false ->
          Lwt.return_error
            (error_info "procfs statm" (Format.asprintf "%s not found" fname)))
    (function
      | exn ->
          Lwt.return_error (error_info "procfs statm" (Printexc.to_string exn)))

let darwin_ps pid =
  Lwt.catch
    (fun () ->
      Lwt_process.with_process_in
        ~env:[|"LC_ALL=C"|]
        ("ps", [|"ps"; "-o"; "pid,%mem,rss"; "-p"; string_of_int pid|])
        (fun pc ->
          Lwt_io.read_line_opt pc#stdout
          >>= function
          | None ->
              Lwt.return_error
                (error_info "ps" "Unexpected ps answer (1st line)")
          | Some _ -> (
              (* first line is useless *)
              Lwt_io.read_line_opt pc#stdout
              >>= function
              | None ->
                  Lwt.return_error
                    (error_info "ps" "Unexpected ps answer (2nd line)")
              | Some ps_stats -> (
                match TzString.split ' ' ps_stats with
                | _pid :: mem :: resident :: _ -> (
                    page_size ()
                    >>= function
                    | Error e ->
                        Lwt.return_error e
                    | Ok page_size ->
                        Lwt.return_ok
                          (Ps
                             {
                               page_size;
                               mem = float_of_string mem;
                               resident = Int64.of_string resident;
                             }) )
                | _ ->
                    Lwt.return_error (error_info "ps" "Unexpected answer") ) )))
    (function
      | exn -> Lwt.return_error (error_info "ps" (Printexc.to_string exn)))

let memory_stats () =
  let pid = Unix.getpid () in
  uname
  >>= function
  | Error e ->
      Lwt.return_error e
  | Ok Linux ->
      linux_statm pid
  | Ok Darwin ->
      darwin_ps pid
  | _ ->
      Lwt.return_error (error_info "memory_stats" "Unknown unix system")
