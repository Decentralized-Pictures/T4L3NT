(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020-2021 Nomadic Labs, <contact@nomadic-labs.com>          *)
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

open Store_errors
open Naming

type _ t =
  | Stored_data : {
      mutable cache : 'a;
      file : (_, 'a) encoded_file;
      scheduler : Lwt_idle_waiter.t;
    }
      -> 'a t

let read_json_file file =
  Option.catch_os (fun () ->
      Lwt_utils_unix.Json.read_file (Naming.encoded_file_path file) >>= function
      | Ok json ->
          let encoding = Naming.file_encoding file in
          Lwt.return_some (Data_encoding.Json.destruct encoding json)
      | _ -> Lwt.return_none)

let read_file file =
  Lwt.try_bind
    (fun () ->
      let path = Naming.encoded_file_path file in
      Lwt_utils_unix.read_file path)
    (fun str ->
      let encoding = Naming.file_encoding file in
      Lwt.return (Data_encoding.Binary.of_string_opt encoding str))
    (fun _ -> Lwt.return_none)

let get (Stored_data v) =
  Lwt_idle_waiter.task v.scheduler (fun () -> Lwt.return v.cache)

let write_file encoded_file data =
  protect (fun () ->
      let encoding = Naming.file_encoding encoded_file in
      let path = Naming.encoded_file_path encoded_file in
      let encoder data =
        if Naming.is_json_file encoded_file then
          Data_encoding.Json.construct encoding data
          |> Data_encoding.Json.to_string
        else Data_encoding.Binary.to_string_exn encoding data
      in
      let str = encoder data in
      let tmp_filename = path ^ "_tmp" in
      (* Write in a new temporary file then swap the files to avoid
         partial writes. *)
      Lwt_unix.openfile
        tmp_filename
        [Unix.O_WRONLY; O_CREAT; O_TRUNC; O_CLOEXEC]
        0o644
      >>= fun fd ->
      Lwt.catch
        (fun () ->
          Lwt_utils_unix.write_string fd str >>= fun () ->
          Lwt_unix.close fd >>= fun () ->
          Lwt_unix.rename tmp_filename path >>= fun () -> return_unit)
        (fun exn -> Lwt_utils_unix.safe_close fd >>= fun _ -> Lwt.fail exn))

let write (Stored_data v) data =
  Lwt_idle_waiter.force_idle v.scheduler (fun () ->
      if v.cache = data then return_unit
      else (
        v.cache <- data ;
        write_file v.file data))

let create file data =
  let file = file in
  let scheduler = Lwt_idle_waiter.create () in
  write_file file data >>=? fun () ->
  return (Stored_data {cache = data; file; scheduler})

let update_with (Stored_data v) f =
  Lwt_idle_waiter.force_idle v.scheduler (fun () ->
      f v.cache >>= fun new_data ->
      if v.cache = new_data then return_unit
      else (
        v.cache <- new_data ;
        write_file v.file new_data))

let load file =
  (if Naming.is_json_file file then read_json_file file else read_file file)
  >>= function
  | Some cache ->
      let scheduler = Lwt_idle_waiter.create () in
      return (Stored_data {cache; file; scheduler})
  | None -> fail (Missing_stored_data (Naming.encoded_file_path file))

let init file ~initial_data =
  let path = Naming.encoded_file_path file in
  Lwt_unix.file_exists path >>= function
  | true -> load file
  | false -> create file initial_data
