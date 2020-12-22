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

open Error_monad

let () =
  register_error_kind
    `Temporary
    ~id:"unix_error"
    ~title:"Unix error"
    ~description:"An unhandled unix exception"
    ~pp:Format.pp_print_string
    Data_encoding.(obj1 (req "msg" string))
    (function
      | Exn (Unix.Unix_error (err, fn, _)) ->
          Some ("Unix error in " ^ fn ^ ": " ^ Unix.error_message err)
      | _ ->
          None)
    (fun msg -> Exn (Failure msg))

let default_net_timeout = ref (Ptime.Span.of_int_s 8)

let read_bytes ?(timeout = !default_net_timeout) ?(pos = 0) ?len fd buf =
  let buflen = Bytes.length buf in
  let len = match len with None -> buflen - pos | Some l -> l in
  if pos < 0 || pos + len > buflen then invalid_arg "read_bytes" ;
  let rec inner pos len =
    if len = 0 then Lwt.return_unit
    else
      Lwt_unix.with_timeout (Ptime.Span.to_float_s timeout) (fun () ->
          Lwt_unix.read fd buf pos len)
      >>= function
      | 0 ->
          Lwt.fail End_of_file
          (* other endpoint cleanly closed its connection *)
      | nb_read ->
          inner (pos + nb_read) (len - nb_read)
  in
  inner pos len

let write_bytes ?(pos = 0) ?len descr buf =
  let buflen = Bytes.length buf in
  let len = match len with None -> buflen - pos | Some l -> l in
  if pos < 0 || pos + len > buflen then invalid_arg "write_bytes" ;
  let rec inner pos len =
    if len = 0 then Lwt.return_unit
    else
      Lwt_unix.write descr buf pos len
      >>= function
      | 0 ->
          Lwt.fail End_of_file
          (* other endpoint cleanly closed its connection *)
      | nb_written ->
          inner (pos + nb_written) (len - nb_written)
  in
  inner pos len

let write_string ?(pos = 0) ?len descr buf =
  let len = match len with None -> String.length buf - pos | Some l -> l in
  let rec inner pos len =
    if len = 0 then Lwt.return_unit
    else
      Lwt_unix.write_string descr buf pos len
      >>= function
      | 0 ->
          Lwt.fail End_of_file
          (* other endpoint cleanly closed its connection *)
      | nb_written ->
          inner (pos + nb_written) (len - nb_written)
  in
  inner pos len

let remove_dir dir =
  let rec remove dir =
    let files = Lwt_unix.files_of_directory dir in
    Lwt_stream.iter_s
      (fun file ->
        if file = "." || file = ".." then Lwt.return_unit
        else
          let file = Filename.concat dir file in
          if Sys.is_directory file then remove file else Lwt_unix.unlink file)
      files
    >>= fun () -> Lwt_unix.rmdir dir
  in
  if Sys.file_exists dir && Sys.is_directory dir then remove dir
  else Lwt.return_unit

let rec create_dir ?(perm = 0o755) dir =
  Lwt_unix.file_exists dir
  >>= function
  | false ->
      create_dir (Filename.dirname dir)
      >>= fun () ->
      Lwt.catch
        (fun () -> Lwt_unix.mkdir dir perm)
        (function
          | Unix.Unix_error (Unix.EEXIST, _, _) ->
              (* This is the case where the directory has been created
                 by another Lwt.t, after the call to Lwt_unix.file_exists. *)
              Lwt.return_unit
          | e ->
              Lwt.fail e)
  | true -> (
      Lwt_unix.stat dir
      >>= function
      | {st_kind = S_DIR; _} ->
          Lwt.return_unit
      | _ ->
          Stdlib.failwith "Not a directory" )

let safe_close fd =
  Lwt.catch
    (fun () -> Lwt_unix.close fd >>= fun () -> return_unit)
    (fun exc -> fail (Exn exc))

let create_file ?(perm = 0o644) name content =
  Lwt_unix.openfile name Unix.[O_TRUNC; O_CREAT; O_WRONLY] perm
  >>= fun fd ->
  Lwt.try_bind
    (fun () -> Lwt_unix.write_string fd content 0 (String.length content))
    (fun v ->
      safe_close fd
      >>= function
      | Error trace ->
          Format.eprintf "Uncaught error: %a\n%!" pp_print_error trace ;
          Lwt.return v
      | Ok () ->
          Lwt.return v)
    (fun exc ->
      safe_close fd
      >>= function
      | Error trace ->
          Format.eprintf "Uncaught error: %a\n%!" pp_print_error trace ;
          raise exc
      | Ok () ->
          raise exc)

let read_file fn = Lwt_io.with_file fn ~mode:Input (fun ch -> Lwt_io.read ch)

let of_sockaddr = function
  | Unix.ADDR_UNIX _ ->
      None
  | Unix.ADDR_INET (addr, port) -> (
    match Ipaddr_unix.of_inet_addr addr with
    | V4 addr ->
        Some (Ipaddr.v6_of_v4 addr, port)
    | V6 addr ->
        Some (addr, port) )

let getaddrinfo ~passive ~node ~service =
  let open Lwt_unix in
  getaddrinfo
    node
    service
    (AI_SOCKTYPE SOCK_STREAM :: (if passive then [AI_PASSIVE] else []))
  >>= fun addr ->
  let points =
    List.filter_map (fun {ai_addr; _} -> of_sockaddr ai_addr) addr
  in
  Lwt.return points

let getpass () =
  let open Unix in
  (* Turn echoing off and fail if we can't. *)
  let tio = tcgetattr stdin in
  let old_echo = tio.c_echo in
  let old_echonl = tio.c_echonl in
  tio.c_echo <- false ;
  tio.c_echonl <- true ;
  tcsetattr stdin TCSAFLUSH tio ;
  (* Read the passwd. *)
  let passwd = read_line () in
  (* Restore terminal. *)
  tio.c_echo <- old_echo ;
  tio.c_echonl <- old_echonl ;
  tcsetattr stdin TCSAFLUSH tio ;
  passwd

module Json = struct
  let to_root = function
    | `O ctns ->
        `O ctns
    | `A ctns ->
        `A ctns
    | `Null ->
        `O []
    | oth ->
        `A [oth]

  let write_file file json =
    let json = to_root json in
    protect (fun () ->
        Lwt_io.with_file ~mode:Output file (fun chan ->
            let str = Data_encoding.Json.to_string ~minify:false json in
            Lwt_io.write chan str >|= ok))

  let read_file file =
    protect (fun () ->
        Lwt_io.with_file ~mode:Input file (fun chan ->
            Lwt_io.read chan
            >>= fun str ->
            return (Ezjsonm.from_string str :> Data_encoding.json)))
end

let with_tempdir name f =
  let base_dir = Filename.temp_file name "" in
  Lwt_unix.unlink base_dir
  >>= fun () ->
  Lwt_unix.mkdir base_dir 0o700
  >>= fun () ->
  Lwt.finalize (fun () -> f base_dir) (fun () -> remove_dir base_dir)

let rec retry ?(log = fun _ -> Lwt.return_unit) ?(n = 5) ?(sleep = 1.) f =
  f ()
  >>= function
  | Ok r ->
      Lwt.return_ok r
  | Error error as x ->
      if n > 0 then
        log error
        >>= fun () ->
        Lwt_unix.sleep sleep >>= fun () -> retry ~log ~n:(n - 1) ~sleep f
      else Lwt.return x
