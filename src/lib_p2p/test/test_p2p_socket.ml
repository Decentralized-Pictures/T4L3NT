(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2019-2020 Nomadic Labs, <contact@nomadic-labs.com>          *)
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

(** Testing
    -------
    Component:    P2P
    Invocation:   dune build @src/lib_p2p/test/runtest_p2p_socket_ipv4
    Dependencies: src/lib_p2p/test/process.ml
    Subject:      Sockets and client-server communications.
*)

include Internal_event.Legacy_logging.Make (struct
  let name = "test.p2p.connection"
end)

let tzassert b pos =
  let p (file, lnum, cnum, _) = (file, lnum, cnum) in
  if b then return_unit else fail (Exn (Assert_failure (p pos)))

let addr = ref Ipaddr.V6.localhost

let canceler = Lwt_canceler.create () (* unused *)

let proof_of_work_target = Crypto_box.make_pow_target 16.

let id1 = P2p_identity.generate proof_of_work_target

let id2 = P2p_identity.generate proof_of_work_target

let id0 =
  (* Luckily, this will be an insufficient proof of work! *)
  P2p_identity.generate (Crypto_box.make_pow_target 0.)

let version =
  {
    Network_version.chain_name =
      Distributed_db_version.Name.of_string "SANDBOXED_TEZOS";
    distributed_db_version = Distributed_db_version.one;
    p2p_version = P2p_version.zero;
  }

type metadata = unit

let conn_meta_config : metadata P2p_params.conn_meta_config =
  {
    conn_meta_encoding = Data_encoding.empty;
    conn_meta_value = (fun () -> ());
    private_node = (fun _ -> false);
  }

let rec listen ?port addr =
  let tentative_port =
    match port with None -> 1024 + Random.int 8192 | Some port -> port
  in
  let uaddr = Ipaddr_unix.V6.to_inet_addr addr in
  let main_socket = Lwt_unix.(socket PF_INET6 SOCK_STREAM 0) in
  Lwt_unix.(setsockopt main_socket SO_REUSEADDR true) ;
  Lwt.catch
    (fun () ->
      Lwt_unix.bind main_socket (ADDR_INET (uaddr, tentative_port))
      >>= fun () ->
      Lwt_unix.listen main_socket 1 ;
      Lwt.return (main_socket, tentative_port))
    (function
      | Unix.Unix_error ((Unix.EADDRINUSE | Unix.EADDRNOTAVAIL), _, _)
        when port = None ->
          listen addr
      | exn ->
          Lwt.fail exn)

let sync ch =
  Process.Channel.push ch ()
  >>=? fun () -> Process.Channel.pop ch >>=? fun () -> return_unit

let rec sync_nodes nodes =
  iter_p (fun p -> Process.receive p) nodes
  >>=? fun () ->
  iter_p (fun p -> Process.send p ()) nodes >>=? fun () -> sync_nodes nodes

let sync_nodes nodes =
  sync_nodes nodes
  >>= function
  | Ok () | Error (Exn End_of_file :: _) ->
      return_unit
  | Error _ as err ->
      Lwt.return err

let run_nodes client server =
  listen !addr
  >>= fun (main_socket, port) ->
  Process.detach ~prefix:"server: " (fun channel ->
      let sched = P2p_io_scheduler.create ~read_buffer_size:(1 lsl 12) () in
      server channel sched main_socket
      >>=? fun () -> P2p_io_scheduler.shutdown sched >>= fun () -> return_unit)
  >>=? fun server_node ->
  Process.detach ~prefix:"client: " (fun channel ->
      Lwt_utils_unix.safe_close main_socket
      >>= (function
            | Error trace ->
                Format.eprintf "Uncaught error: %a\n%!" pp_print_error trace ;
                Lwt.return_unit
            | Ok () ->
                Lwt.return_unit)
      >>= fun () ->
      let sched = P2p_io_scheduler.create ~read_buffer_size:(1 lsl 12) () in
      client channel sched !addr port
      >>=? fun () -> P2p_io_scheduler.shutdown sched >>= fun () -> return_unit)
  >>=? fun client_node ->
  let nodes = [server_node; client_node] in
  Lwt.ignore_result (sync_nodes nodes) ;
  Process.wait_all nodes

let raw_accept sched main_socket =
  P2p_fd.accept main_socket
  >>= fun (fd, sockaddr) ->
  let fd = P2p_io_scheduler.register sched fd in
  let point =
    match sockaddr with
    | Lwt_unix.ADDR_UNIX _ ->
        assert false
    | Lwt_unix.ADDR_INET (addr, port) ->
        (Ipaddr_unix.V6.of_inet_addr_exn addr, port)
  in
  Lwt.return (fd, point)

let accept sched main_socket =
  raw_accept sched main_socket
  >>= fun (fd, point) ->
  id1
  >>= fun id1 ->
  P2p_socket.authenticate
    ~canceler
    ~proof_of_work_target
    ~incoming:true
    fd
    point
    id1
    version
    conn_meta_config

let raw_connect sched addr port =
  P2p_fd.socket PF_INET6 SOCK_STREAM 0
  >>= fun fd ->
  let uaddr = Lwt_unix.ADDR_INET (Ipaddr_unix.V6.to_inet_addr addr, port) in
  P2p_fd.connect fd uaddr
  >>= fun () ->
  let fd = P2p_io_scheduler.register sched fd in
  Lwt.return fd

let connect sched addr port id =
  raw_connect sched addr port
  >>= fun fd ->
  id
  >>= fun id ->
  id1
  >>= fun id1 ->
  P2p_socket.authenticate
    ~canceler
    ~proof_of_work_target
    ~incoming:false
    fd
    (addr, port)
    id
    version
    conn_meta_config
  >>=? fun (info, auth_fd) ->
  tzassert (not info.incoming) __POS__
  >>=? fun () ->
  tzassert (P2p_peer.Id.compare info.peer_id id1.peer_id = 0) __POS__
  >>=? fun () -> return auth_fd

let is_connection_closed = function
  | Error (Tezos_p2p_services.P2p_errors.Connection_closed :: _) ->
      true
  | Ok _ ->
      false
  | Error err ->
      log_notice "Error: %a" pp_print_error err ;
      false

let is_decoding_error = function
  | Error (Tezos_p2p_services.P2p_errors.Decoding_error _ :: _) ->
      true
  | Ok _ ->
      false
  | Error err ->
      log_notice "Error: %a" pp_print_error err ;
      false

(** Writing then reading through the same pipe a chunk of message [msg]
    with encryption/decryption.
*)
module Crypto_test = struct
  (* maximal size of the buffer *)
  let bufsize = (1 lsl 16) - 1

  let header_length = 2

  (* The size of extra data added by encryption. *)
  let tag_length = Crypto_box.tag_length

  (* The number of bytes added by encryption + header *)
  let extrabytes = header_length + tag_length

  let max_content_length = bufsize - extrabytes

  type data = {
    channel_key : Crypto_box.channel_key;
    mutable local_nonce : Crypto_box.nonce;
    mutable remote_nonce : Crypto_box.nonce;
  }

  let () = assert (tag_length >= header_length)

  let write_chunk fd cryptobox_data msg =
    let msg_length = Bytes.length msg in
    fail_unless
      (msg_length <= max_content_length)
      Tezos_p2p_services.P2p_errors.Invalid_message_size
    >>=? fun () ->
    let encrypted_length = tag_length + msg_length in
    let payload_length = header_length + encrypted_length in
    let tag = Bytes.make tag_length '\x00' in
    let cmsg = Bytes.copy msg in
    let local_nonce = cryptobox_data.local_nonce in
    cryptobox_data.local_nonce <- Crypto_box.increment_nonce local_nonce ;
    Crypto_box.fast_box_noalloc cryptobox_data.channel_key local_nonce tag cmsg ;
    let payload = Bytes.make payload_length '\x00' in
    TzEndian.set_int16 payload 0 encrypted_length ;
    Bytes.blit tag 0 payload header_length tag_length ;
    Bytes.blit cmsg 0 payload extrabytes msg_length ;
    return (Unix.write fd payload 0 payload_length)
    >>=? fun i -> tzassert (payload_length = i) __POS__

  let read_chunk fd cryptobox_data =
    let header_buf = Bytes.create header_length in
    return (Unix.read fd header_buf 0 header_length)
    >>=? fun i ->
    tzassert (header_length = i) __POS__
    >>=? fun () ->
    let encrypted_length = TzEndian.get_uint16 header_buf 0 in
    assert (encrypted_length >= tag_length) ;
    let msg_length = encrypted_length - tag_length in
    let tag = Bytes.make tag_length '\x00' in
    return (Unix.read fd tag 0 tag_length)
    >>=? fun i ->
    tzassert (tag_length = i) __POS__
    >>=? fun () ->
    let msg = Bytes.make msg_length '\x00' in
    ( if msg_length > 0 then return (Unix.read fd msg 0 msg_length)
    else return 0 )
    >>=? fun i ->
    tzassert (msg_length = i) __POS__
    >>=? fun () ->
    let remote_nonce = cryptobox_data.remote_nonce in
    cryptobox_data.remote_nonce <- Crypto_box.increment_nonce remote_nonce ;
    match
      Crypto_box.fast_box_open_noalloc
        cryptobox_data.channel_key
        remote_nonce
        tag
        msg
    with
    | false ->
        fail Tezos_p2p_services.P2p_errors.Decipher_error
    | true ->
        return msg

  let (sk, pk, pkh) = Crypto_box.random_keypair ()

  let zero_nonce = Crypto_box.zero_nonce

  let channel_key = Crypto_box.precompute sk pk

  let (in_fd, out_fd) = Unix.pipe ()

  let data = {channel_key; local_nonce = zero_nonce; remote_nonce = zero_nonce}

  let wrap () =
    Alcotest.test_case "ACK" `Quick (fun () ->
        Lwt_main.run
          (let msg = Bytes.of_string "test" in
           write_chunk out_fd data msg
           >>= fun _ ->
           read_chunk in_fd data
           >>= function
           | Ok res when Bytes.equal msg res ->
               Lwt.return_unit
           | Ok res ->
               Format.kasprintf
                 Stdlib.failwith
                 "Error : %s <> %s"
                 (Bytes.to_string res)
                 (Bytes.to_string msg)
           | Error error ->
               Format.kasprintf Stdlib.failwith "%a" pp_print_error error))
end

(** Spawns a client and a server. After the client getting connected to
    the server, it reads a message [simple_msg] sent by the server and
    stores in [msg] of fixed same size. It asserts that both messages
    and identical.
*)
module Low_level = struct
  let simple_msg = Rand.generate (1 lsl 4)

  let client _ch sched addr port =
    let msg = Bytes.create (Bytes.length simple_msg) in
    raw_connect sched addr port
    >>= fun fd ->
    P2p_io_scheduler.read_full fd msg
    >>=? fun () ->
    tzassert (Bytes.compare simple_msg msg = 0) __POS__
    >>=? fun () -> P2p_io_scheduler.close fd

  let server _ch sched socket =
    raw_accept sched socket
    >>= fun (fd, _point) ->
    P2p_io_scheduler.write fd simple_msg
    >>=? fun () -> P2p_io_scheduler.close fd >>=? fun _ -> return_unit

  let run _dir = run_nodes client server
end

(** Spawns a client and a server. The client connects to the server
    using identity [id2], this identity is checked on server-side. The
    server sends a Nack message with no rejection motive. The client
    asserts that its connection has been rejected by Nack.
*)
module Nack = struct
  let encoding = Data_encoding.bytes

  let is_rejected = function
    | Error (Tezos_p2p_services.P2p_errors.Rejected_by_nack _ :: _) ->
        true
    | Ok _ ->
        false
    | Error err ->
        log_notice "Error: %a" pp_print_error err ;
        false

  let server _ch sched socket =
    accept sched socket
    >>=? fun (info, auth_fd) ->
    tzassert info.incoming __POS__
    >>=? fun () ->
    id2
    >>= fun id2 ->
    tzassert (P2p_peer.Id.compare info.peer_id id2.peer_id = 0) __POS__
    >>=? fun () ->
    P2p_socket.nack auth_fd P2p_rejection.No_motive []
    >>= fun () -> return_unit

  let client _ch sched addr port =
    connect sched addr port id2
    >>=? fun auth_fd ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>= fun conn -> tzassert (is_rejected conn) __POS__

  let run _dir = run_nodes client server
end

(** Spawns a client and a server. A client trying to connect to a
    server receives and Ack message but replies with a Nack. The
    connection is hence rejected by the client.
*)
module Nacked = struct
  let encoding = Data_encoding.bytes

  let server _ch sched socket =
    accept sched socket
    >>=? fun (_info, auth_fd) ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>= fun conn -> tzassert (Nack.is_rejected conn) __POS__

  let client _ch sched addr port =
    connect sched addr port id2
    >>=? fun auth_fd ->
    P2p_socket.nack auth_fd P2p_rejection.No_motive []
    >>= fun () -> return_unit

  (* This test is skipped because its result on the CI is not deterministic *)
  let run _dir = return_unit
end

(** Spawns a client and a server. A client tries to connect to a
    server. Both parties acknowledge. The server sends [simple_msg],
    while the client sends [simple_msg2]. Both messages are checked for
    consistency. Then, the connection is closed.
*)
module Simple_message = struct
  let encoding = Data_encoding.bytes

  let simple_msg = Rand.generate (1 lsl 4)

  let simple_msg2 = Rand.generate (1 lsl 4)

  let server ch sched socket =
    accept sched socket
    >>=? fun (_info, auth_fd) ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    P2p_socket.write_sync conn simple_msg
    >>=? fun () ->
    P2p_socket.read conn
    >>=? fun (_msg_size, msg) ->
    tzassert (Bytes.compare simple_msg2 msg = 0) __POS__
    >>=? fun () ->
    sync ch >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let client ch sched addr port =
    connect sched addr port id2
    >>=? fun auth_fd ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    P2p_socket.write_sync conn simple_msg2
    >>=? fun () ->
    P2p_socket.read conn
    >>=? fun (_msg_size, msg) ->
    tzassert (Bytes.compare simple_msg msg = 0) __POS__
    >>=? fun () ->
    sync ch >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let run _dir = run_nodes client server
end

(** Spawns a client and a server. A client tries to connect to a
    server. Both parties acknowledge. The server sends [simple_msg] and
    the client sends [simple_msg2] with a binary chunk size of 21. Both
    messages are checked for consistency.
*)
module Chunked_message = struct
  let encoding = Data_encoding.bytes

  let simple_msg = Rand.generate (1 lsl 8)

  let simple_msg2 = Rand.generate (1 lsl 8)

  let server ch sched socket =
    accept sched socket
    >>=? fun (_info, auth_fd) ->
    P2p_socket.accept ~canceler ~binary_chunks_size:21 auth_fd encoding
    >>=? fun conn ->
    P2p_socket.write_sync conn simple_msg
    >>=? fun () ->
    P2p_socket.read conn
    >>=? fun (_msg_size, msg) ->
    tzassert (Bytes.compare simple_msg2 msg = 0) __POS__
    >>=? fun () ->
    sync ch >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let client ch sched addr port =
    connect sched addr port id2
    >>=? fun auth_fd ->
    P2p_socket.accept ~canceler ~binary_chunks_size:21 auth_fd encoding
    >>=? fun conn ->
    P2p_socket.write_sync conn simple_msg2
    >>=? fun () ->
    P2p_socket.read conn
    >>=? fun (_msg_size, msg) ->
    tzassert (Bytes.compare simple_msg msg = 0) __POS__
    >>=? fun () ->
    sync ch >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let run _dir = run_nodes client server
end

(** Two messages of size 131072 bytes are randomly generated. After
    successful connection, both parties send the latter messages.
*)
module Oversized_message = struct
  let encoding = Data_encoding.bytes

  let simple_msg = Rand.generate (1 lsl 17)

  let simple_msg2 = Rand.generate (1 lsl 17)

  let server ch sched socket =
    accept sched socket
    >>=? fun (_info, auth_fd) ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    P2p_socket.write_sync conn simple_msg
    >>=? fun () ->
    P2p_socket.read conn
    >>=? fun (_msg_size, msg) ->
    tzassert (Bytes.compare simple_msg2 msg = 0) __POS__
    >>=? fun () ->
    sync ch >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let client ch sched addr port =
    connect sched addr port id2
    >>=? fun auth_fd ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    P2p_socket.write_sync conn simple_msg2
    >>=? fun () ->
    P2p_socket.read conn
    >>=? fun (_msg_size, msg) ->
    tzassert (Bytes.compare simple_msg msg = 0) __POS__
    >>=? fun () ->
    sync ch >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let run _dir = run_nodes client server
end

(** After then successful connection of a client to a server, the client
    attempts to read a message. However, the server decides to close
    the connection.
*)
module Close_on_read = struct
  let encoding = Data_encoding.bytes

  let simple_msg = Rand.generate (1 lsl 4)

  let server ch sched socket =
    accept sched socket
    >>=? fun (_info, auth_fd) ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    sync ch >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let client ch sched addr port =
    connect sched addr port id2
    >>=? fun auth_fd ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    sync ch
    >>=? fun () ->
    P2p_socket.read conn
    >>= fun err ->
    tzassert (is_connection_closed err) __POS__
    >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let run _dir = run_nodes client server
end

(** After the successful connection of a client to a server, the client
    attempts to send a message. However, the server decides to close
    the connection.
*)
module Close_on_write = struct
  let encoding = Data_encoding.bytes

  let simple_msg = Rand.generate (1 lsl 4)

  let server ch sched socket =
    accept sched socket
    >>=? fun (_info, auth_fd) ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    P2p_socket.close conn >>= fun _stat -> sync ch >>=? fun () -> return_unit

  let client ch sched addr port =
    connect sched addr port id2
    >>=? fun auth_fd ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    sync ch
    >>=? fun () ->
    Lwt_unix.sleep 0.1
    >>= fun () ->
    P2p_socket.write_sync conn simple_msg
    >>= fun err ->
    tzassert (is_connection_closed err) __POS__
    >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let run _dir = run_nodes client server
end

(** A dummy message is generated into [garbled_msg]. After the
    successful connection of a client to a server, the server sends
    [garbled_msg] and waits by reading a close connection is declared
    by the client.  On the side of the client, it is asserted that the
    message cannot be decoded.
*)
module Garbled_data = struct
  let encoding =
    let open Data_encoding in
    dynamic_size @@ option @@ string

  (* generate a fixed garbled_msg to avoid 'Data_encoding.Binary.Await
     _', which blocks 'make test' *)
  let garbled_msg =
    let buf = Bytes.create (1 lsl 4) in
    TzEndian.set_int32 buf 0 (Int32.of_int 4) ;
    TzEndian.set_int32 buf 4 (Int32.of_int (-1)) ;
    TzEndian.set_int32 buf 8 (Int32.of_int (-1)) ;
    TzEndian.set_int32 buf 12 (Int32.of_int (-1)) ;
    buf

  let server _ch sched socket =
    accept sched socket
    >>=? fun (_info, auth_fd) ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    P2p_socket.raw_write_sync conn garbled_msg
    >>=? fun () ->
    P2p_socket.read conn
    >>= fun err ->
    tzassert (is_connection_closed err) __POS__
    >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let client _ch sched addr port =
    connect sched addr port id2
    >>=? fun auth_fd ->
    P2p_socket.accept ~canceler auth_fd encoding
    >>=? fun conn ->
    P2p_socket.read conn
    >>= fun err ->
    tzassert (is_decoding_error err) __POS__
    >>=? fun () -> P2p_socket.close conn >>= fun _stat -> return_unit

  let run _dir = run_nodes client server
end

let log_config = ref None

let spec =
  Arg.
    [ ( "--addr",
        String (fun p -> addr := Ipaddr.V6.of_string_exn p),
        " Listening addr" );
      ( "-v",
        Unit
          (fun () ->
            log_config :=
              Some
                (Lwt_log_sink_unix.create_cfg
                   ~rules:"test.p2p.connection -> info; p2p.connection -> info"
                   ())),
        " Log up to info msgs" );
      ( "-vv",
        Unit
          (fun () ->
            log_config :=
              Some
                (Lwt_log_sink_unix.create_cfg
                   ~rules:
                     "test.p2p.connection -> debug; p2p.connection -> debug"
                   ())),
        " Log up to debug msgs" ) ]

let init_logs = lazy (Internal_event_unix.init ?lwt_log_sink:!log_config ())

let wrap n f =
  Alcotest.test_case n `Quick (fun () ->
      Lwt_main.run
        ( Lazy.force init_logs
        >>= fun () ->
        f ()
        >>= function
        | Ok () ->
            Lwt.return_unit
        | Error error ->
            Format.kasprintf Stdlib.failwith "%a" pp_print_error error ))

let main () =
  let anon_fun _num_peers = raise (Arg.Bad "No anonymous argument.") in
  let usage_msg = "Usage: %s.\nArguments are:" in
  Arg.parse spec anon_fun usage_msg ;
  Alcotest.run
    ~argv:[|""|]
    "tezos-p2p"
    [ ( "p2p-connection.",
        [ wrap "low-level" Low_level.run;
          wrap "nack" Nack.run;
          wrap "nacked" Nacked.run;
          wrap "simple-message" Simple_message.run;
          wrap "chunked-message" Chunked_message.run;
          wrap "oversized-message" Oversized_message.run;
          wrap "close-on-read" Close_on_read.run;
          wrap "close-on-write" Close_on_write.run;
          wrap "garbled-data" Garbled_data.run;
          Crypto_test.wrap () ] ) ]

let () =
  Sys.catch_break true ;
  try main () with _ -> ()
