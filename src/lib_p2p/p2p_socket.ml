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

(* TODO test `close ~wait:true`. *)

include Internal_event.Legacy_logging.Make (struct
  let name = "p2p.connection"
end)

module Crypto = struct
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

  (* We do the following assumptions on the NaCl library.  Note that
     we also make the assumption, here, that the NaCl library allows
     in-place boxing and unboxing, since we use the same buffer for
     input and output. *)
  let () = assert (tag_length >= header_length)

  (* msg is overwritten and should not be used after this invocation *)
  let write_chunk ?canceler fd cryptobox_data msg =
    let msg_length = Bytes.length msg in
    fail_unless
      (msg_length <= max_content_length)
      P2p_errors.Invalid_message_size
    >>=? fun () ->
    let encrypted_length = tag_length + msg_length in
    let payload_length = header_length + encrypted_length in
    let tag = Bytes.create tag_length in
    let local_nonce = cryptobox_data.local_nonce in
    cryptobox_data.local_nonce <- Crypto_box.increment_nonce local_nonce ;
    Crypto_box.fast_box_noalloc cryptobox_data.channel_key local_nonce tag msg ;
    let payload = Bytes.create payload_length in
    TzEndian.set_uint16 payload 0 encrypted_length ;
    Bytes.blit tag 0 payload header_length tag_length ;
    Bytes.blit msg 0 payload extrabytes msg_length ;
    P2p_io_scheduler.write ?canceler fd payload

  let read_chunk ?canceler fd cryptobox_data =
    let header_buf = Bytes.create header_length in
    P2p_io_scheduler.read_full ?canceler ~len:header_length fd header_buf
    >>=? fun () ->
    let encrypted_length = TzEndian.get_uint16 header_buf 0 in
    fail_unless
      (encrypted_length >= tag_length)
      P2p_errors.Invalid_incoming_ciphertext_size
    >>=? fun () ->
    let tag = Bytes.create tag_length in
    P2p_io_scheduler.read_full ?canceler ~len:tag_length fd tag
    >>=? fun () ->
    let msg_length = encrypted_length - tag_length in
    let msg = Bytes.create msg_length in
    (* read_full fails if msg is empty *)
    ( if msg_length > 0 then
      P2p_io_scheduler.read_full ?canceler ~len:msg_length fd msg
    else return_unit )
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
        fail P2p_errors.Decipher_error
    | true ->
        return msg
end

(* Note: there is an inconsistency here, since we display an error in
   bytes, whereas the option is set in kbytes. Also, since the default
   size is 64kB-1, it is actually impossible to set the default
   size using the option (the max is 63 kB). *)
let check_binary_chunks_size size =
  let value = size - Crypto.extrabytes in
  fail_unless
    (value > 0 && value <= Crypto.max_content_length)
    (P2p_errors.Invalid_chunks_size
       {value = size; min = Crypto.extrabytes + 1; max = Crypto.bufsize})

module Connection_message = struct
  type t = {
    port : int option;
    public_key : Crypto_box.public_key;
    proof_of_work_stamp : Crypto_box.nonce;
    message_nonce : Crypto_box.nonce;
    version : Network_version.t;
  }

  let encoding =
    let open Data_encoding in
    conv
      (fun {port; public_key; proof_of_work_stamp; message_nonce; version} ->
        let port = match port with None -> 0 | Some port -> port in
        (port, public_key, proof_of_work_stamp, message_nonce, version))
      (fun (port, public_key, proof_of_work_stamp, message_nonce, version) ->
        let port = if port = 0 then None else Some port in
        {port; public_key; proof_of_work_stamp; message_nonce; version})
      (obj5
         (req "port" uint16)
         (req "pubkey" Crypto_box.public_key_encoding)
         (req "proof_of_work_stamp" Crypto_box.nonce_encoding)
         (req "message_nonce" Crypto_box.nonce_encoding)
         (req "version" Network_version.encoding))

  let write ~canceler fd message =
    let encoded_message_len = Data_encoding.Binary.length encoding message in
    fail_unless
      (encoded_message_len < 1 lsl (Crypto.header_length * 8))
      Tezos_base.Data_encoding_wrapper.Unexpected_size_of_decoded_buffer
    >>=? fun () ->
    let len = Crypto.header_length + encoded_message_len in
    let buf = Bytes.create len in
    match
      Data_encoding.Binary.write encoding message buf Crypto.header_length len
    with
    | Error we ->
        fail (Tezos_base.Data_encoding_wrapper.Encoding_error we)
    | Ok last ->
        fail_unless
          (last = len)
          Tezos_base.Data_encoding_wrapper.Unexpected_size_of_encoded_value
        >>=? fun () ->
        TzEndian.set_int16 buf 0 encoded_message_len ;
        P2p_io_scheduler.write ~canceler fd buf
        >>=? fun () ->
        (* We return the raw message as it is used later to compute
           the nonces *)
        return buf

  let read ~canceler fd =
    let header_buf = Bytes.create Crypto.header_length in
    P2p_io_scheduler.read_full
      ~canceler
      ~len:Crypto.header_length
      fd
      header_buf
    >>=? fun () ->
    let len = TzEndian.get_uint16 header_buf 0 in
    let pos = Crypto.header_length in
    let buf = Bytes.create (pos + len) in
    TzEndian.set_int16 buf 0 len ;
    P2p_io_scheduler.read_full ~canceler ~len ~pos fd buf
    >>=? fun () ->
    match Data_encoding.Binary.read encoding buf pos len with
    | Error re ->
        fail (P2p_errors.Decoding_error re)
    | Ok (next_pos, message) ->
        if next_pos <> pos + len then
          fail (P2p_errors.Decoding_error Data_encoding.Binary.Extra_bytes)
        else return (message, buf)
end

module Metadata = struct
  let write ~canceler metadata_config cryptobox_data fd message =
    let encoded_message_len =
      Data_encoding.Binary.length
        metadata_config.P2p_params.conn_meta_encoding
        message
    in
    let buf = Bytes.create encoded_message_len in
    match
      Data_encoding.Binary.write
        metadata_config.conn_meta_encoding
        message
        buf
        0
        encoded_message_len
    with
    | Error we ->
        fail (Tezos_base.Data_encoding_wrapper.Encoding_error we)
    | Ok last ->
        fail_unless
          (last = encoded_message_len)
          Tezos_base.Data_encoding_wrapper.Unexpected_size_of_encoded_value
        >>=? fun () -> Crypto.write_chunk ~canceler cryptobox_data fd buf

  let read ~canceler metadata_config fd cryptobox_data =
    Crypto.read_chunk ~canceler fd cryptobox_data
    >>=? fun buf ->
    let length = Bytes.length buf in
    let encoding = metadata_config.P2p_params.conn_meta_encoding in
    match Data_encoding.Binary.read encoding buf 0 length with
    | Error re ->
        fail (P2p_errors.Decoding_error re)
    | Ok (read_len, message) ->
        if read_len <> length then
          fail (P2p_errors.Decoding_error Data_encoding.Binary.Extra_bytes)
        else return message
end

module Ack = struct
  type t =
    | Ack
    | Nack_v_0
    | Nack of {
        motive : P2p_rejection.t;
        potential_peers_to_connect : P2p_point.Id.t list;
      }

  let encoding =
    let open Data_encoding in
    let ack_encoding = obj1 (req "ack" empty) in
    let nack_v_0_encoding = obj1 (req "nack_v_0" empty) in
    let nack_encoding =
      obj2
        (req "nack_motive" P2p_rejection.encoding)
        (req
           "nack_list"
           (Data_encoding.list ~max_length:100 P2p_point.Id.encoding))
    in
    let ack_case tag =
      case
        tag
        ack_encoding
        ~title:"Ack"
        (function Ack -> Some () | _ -> None)
        (fun () -> Ack)
    in
    let nack_case tag =
      case
        tag
        nack_encoding
        ~title:"Nack"
        (function
          | Nack {motive; potential_peers_to_connect} ->
              Some (motive, potential_peers_to_connect)
          | _ ->
              None)
        (fun (motive, lst) -> Nack {motive; potential_peers_to_connect = lst})
    in
    let nack_v_0_case tag =
      case
        tag
        nack_v_0_encoding
        ~title:"Nack_v_0"
        (function Nack_v_0 -> Some () | _ -> None)
        (fun () -> Nack_v_0)
    in
    union [ack_case (Tag 0); nack_v_0_case (Tag 255); nack_case (Tag 1)]

  let write ?canceler fd cryptobox_data message =
    let encoded_message_len = Data_encoding.Binary.length encoding message in
    let buf = Bytes.create encoded_message_len in
    match
      Data_encoding.Binary.write encoding message buf 0 encoded_message_len
    with
    | Error we ->
        fail (Tezos_base.Data_encoding_wrapper.Encoding_error we)
    | Ok last ->
        fail_unless
          (last = encoded_message_len)
          Tezos_base.Data_encoding_wrapper.Unexpected_size_of_encoded_value
        >>=? fun () -> Crypto.write_chunk ?canceler fd cryptobox_data buf

  let read ?canceler fd cryptobox_data =
    Crypto.read_chunk ?canceler fd cryptobox_data
    >>=? fun buf ->
    let length = Bytes.length buf in
    match Data_encoding.Binary.read encoding buf 0 length with
    | Error re ->
        fail (P2p_errors.Decoding_error re)
    | Ok (read_len, message) ->
        if read_len <> length then
          fail (P2p_errors.Decoding_error Data_encoding.Binary.Extra_bytes)
        else return message
end

type 'meta authenticated_connection = {
  fd : P2p_io_scheduler.connection;
  info : 'meta P2p_connection.Info.t;
  cryptobox_data : Crypto.data;
}

let nack {fd; cryptobox_data; info} motive potential_peers_to_connect =
  let nack =
    if
      P2p_version.feature_available
        P2p_version.Nack_with_list
        info.announced_version.p2p_version
    then (
      debug
        "Nack point %a with point list %a.@."
        P2p_connection.Id.pp
        info.id_point
        P2p_point.Id.pp_list
        potential_peers_to_connect ;
      Ack.Nack {motive; potential_peers_to_connect} )
    else (
      debug
        "Nack point %a (no point list due to p2p version)@."
        P2p_connection.Id.pp
        info.id_point ;
      Ack.Nack_v_0 )
  in
  Ack.write fd cryptobox_data nack
  >>= fun _ -> P2p_io_scheduler.close fd >>= fun _ -> Lwt.return_unit

(* First step: write and read credentials, makes no difference
   whether we're trying to connect to a peer or checking an incoming
   connection, both parties must first introduce themselves. *)
let authenticate ~canceler ~proof_of_work_target ~incoming fd
    ((remote_addr, remote_socket_port) as point) ?listening_port identity
    announced_version metadata_config =
  let local_nonce_seed = Crypto_box.random_nonce () in
  lwt_debug "Sending authentication to %a" P2p_point.Id.pp point
  >>= fun () ->
  Connection_message.write
    ~canceler
    fd
    {
      public_key = identity.P2p_identity.public_key;
      proof_of_work_stamp = identity.proof_of_work_stamp;
      message_nonce = local_nonce_seed;
      port = listening_port;
      version = announced_version;
    }
  >>=? fun sent_msg ->
  Connection_message.read ~canceler fd
  >>=? fun (msg, recv_msg) ->
  let remote_listening_port =
    if incoming then msg.port else Some remote_socket_port
  in
  let id_point = (remote_addr, remote_listening_port) in
  let remote_peer_id = Crypto_box.hash msg.public_key in
  fail_unless
    (remote_peer_id <> identity.P2p_identity.peer_id)
    (P2p_errors.Myself id_point)
  >>=? fun () ->
  fail_unless
    (Crypto_box.check_proof_of_work
       msg.public_key
       msg.proof_of_work_stamp
       proof_of_work_target)
    (P2p_errors.Not_enough_proof_of_work remote_peer_id)
  >>=? fun () ->
  let channel_key =
    Crypto_box.precompute identity.P2p_identity.secret_key msg.public_key
  in
  let (local_nonce, remote_nonce) =
    Crypto_box.generate_nonces ~incoming ~sent_msg ~recv_msg
  in
  let cryptobox_data = {Crypto.channel_key; local_nonce; remote_nonce} in
  let local_metadata = metadata_config.P2p_params.conn_meta_value () in
  Metadata.write ~canceler metadata_config fd cryptobox_data local_metadata
  >>=? fun () ->
  Metadata.read ~canceler metadata_config fd cryptobox_data
  >>=? fun remote_metadata ->
  let info =
    {
      P2p_connection.Info.peer_id = remote_peer_id;
      announced_version = msg.version;
      incoming;
      id_point;
      remote_socket_port;
      private_node = metadata_config.private_node remote_metadata;
      local_metadata;
      remote_metadata;
    }
  in
  return (info, {fd; info; cryptobox_data})

module Reader = struct
  type ('msg, 'meta) t = {
    canceler : Lwt_canceler.t;
    conn : 'meta authenticated_connection;
    encoding : 'msg Data_encoding.t;
    messages : (int * 'msg) tzresult Lwt_pipe.t;
    mutable worker : unit Lwt.t;
  }

  let read_message st init =
    let rec loop status =
      Lwt_unix.yield ()
      >>= fun () ->
      let open Data_encoding.Binary in
      match status with
      | Success {result; size; stream} ->
          return (result, size, stream)
      | Error err ->
          lwt_debug "[read_message] incremental decoding error"
          >>= fun () -> fail (P2p_errors.Decoding_error err)
      | Await decode_next_buf ->
          Crypto.read_chunk
            ~canceler:st.canceler
            st.conn.fd
            st.conn.cryptobox_data
          >>=? fun buf ->
          lwt_debug
            "reading %d bytes from %a"
            (Bytes.length buf)
            P2p_peer.Id.pp
            st.conn.info.peer_id
          >>= fun () -> loop (decode_next_buf buf)
    in
    loop (Data_encoding.Binary.read_stream ?init st.encoding)

  let rec worker_loop st stream =
    read_message st stream
    >>=? (fun (msg, size, stream) ->
           protect ~canceler:st.canceler (fun () ->
               Lwt_pipe.push st.messages (Ok (size, msg))
               >>= fun () -> return_some stream))
    >>= function
    | Ok (Some stream) ->
        worker_loop st (Some stream)
    | Ok None ->
        Lwt_canceler.cancel st.canceler
    | Error (Canceled :: _) | Error (Exn Lwt_pipe.Closed :: _) ->
        lwt_debug "connection closed to %a" P2p_peer.Id.pp st.conn.info.peer_id
    | Error _ as err ->
        if Lwt_pipe.is_closed st.messages then ()
        else
          (* best-effort push to the messages, we ignore failures *)
          (ignore : bool -> unit) @@ Lwt_pipe.push_now st.messages err ;
        Lwt_canceler.cancel st.canceler

  let run ?size conn encoding canceler =
    let compute_size = function
      | Ok (size, _) ->
          (Sys.word_size / 8 * 11) + size + Lwt_pipe.push_overhead
      | Error _ ->
          0
      (* we push Error only when we close the socket,
                        we don't fear memory leaks in that case... *)
    in
    let size = Option.map (fun max -> (max, compute_size)) size in
    let st =
      {
        canceler;
        conn;
        encoding;
        messages = Lwt_pipe.create ?size ();
        worker = Lwt.return_unit;
      }
    in
    Lwt_canceler.on_cancel st.canceler (fun () ->
        Lwt_pipe.close st.messages ; Lwt.return_unit) ;
    st.worker <-
      Lwt_utils.worker
        "reader"
        ~on_event:Internal_event.Lwt_worker_event.on_event
        ~run:(fun () -> worker_loop st None)
        ~cancel:(fun () -> Lwt_canceler.cancel st.canceler) ;
    st

  let shutdown st = Lwt_canceler.cancel st.canceler >>= fun () -> st.worker
end

module Writer = struct
  type ('msg, 'meta) t = {
    canceler : Lwt_canceler.t;
    conn : 'meta authenticated_connection;
    encoding : 'msg Data_encoding.t;
    messages : (Bytes.t list * unit tzresult Lwt.u option) Lwt_pipe.t;
    mutable worker : unit Lwt.t;
    binary_chunks_size : int; (* in bytes *)
  }

  let send_message st buf =
    let rec loop = function
      | [] ->
          return_unit
      | buf :: l ->
          Crypto.write_chunk
            ~canceler:st.canceler
            st.conn.fd
            st.conn.cryptobox_data
            buf
          >>=? fun () ->
          lwt_debug
            "writing %d bytes to %a"
            (Bytes.length buf)
            P2p_peer.Id.pp
            st.conn.info.peer_id
          >>= fun () -> loop l
    in
    loop buf

  let encode_message st msg =
    match Data_encoding.Binary.to_bytes st.encoding msg with
    | Error we ->
        error (Tezos_base.Data_encoding_wrapper.Encoding_error we)
    | Ok bytes ->
        ok (Utils.cut st.binary_chunks_size bytes)

  let rec worker_loop st =
    Lwt_unix.yield ()
    >>= fun () ->
    protect ~canceler:st.canceler (fun () ->
        Lwt_pipe.pop st.messages >>= return)
    >>= function
    | Error (Canceled :: _) | Error (Exn Lwt_pipe.Closed :: _) ->
        lwt_debug "connection closed to %a" P2p_peer.Id.pp st.conn.info.peer_id
    | Error err ->
        lwt_log_error
          "@[<v 2>error writing to %a@ %a@]"
          P2p_peer.Id.pp
          st.conn.info.peer_id
          pp_print_error
          err
        >>= fun () -> Lwt_canceler.cancel st.canceler
    | Ok (buf, wakener) -> (
        send_message st buf
        >>= fun res ->
        match res with
        | Ok () ->
            Option.iter (fun u -> Lwt.wakeup_later u res) wakener ;
            worker_loop st
        | Error err -> (
            Option.iter
              (fun u ->
                Lwt.wakeup_later u (error P2p_errors.Connection_closed))
              wakener ;
            match err with
            | (Canceled | Exn Lwt_pipe.Closed) :: _ ->
                lwt_debug
                  "connection closed to %a"
                  P2p_peer.Id.pp
                  st.conn.info.peer_id
            | P2p_errors.Connection_closed :: _ ->
                lwt_debug
                  "connection closed to %a"
                  P2p_peer.Id.pp
                  st.conn.info.peer_id
                >>= fun () -> Lwt_canceler.cancel st.canceler
            | err ->
                lwt_log_error
                  "@[<v 2>error writing to %a@ %a@]"
                  P2p_peer.Id.pp
                  st.conn.info.peer_id
                  pp_print_error
                  err
                >>= fun () -> Lwt_canceler.cancel st.canceler ) )

  let run ?size ?binary_chunks_size conn encoding canceler =
    let binary_chunks_size =
      match binary_chunks_size with
      | None ->
          Crypto.max_content_length
      | Some size ->
          let size = size - Crypto.extrabytes in
          assert (size > 0) ;
          assert (size <= Crypto.max_content_length) ;
          size
    in
    let compute_size =
      let buf_list_size =
        List.fold_left
          (fun sz buf -> sz + Bytes.length buf + (2 * Sys.word_size))
          0
      in
      function
      | (buf_l, None) ->
          Sys.word_size + buf_list_size buf_l + Lwt_pipe.push_overhead
      | (buf_l, Some _) ->
          (2 * Sys.word_size) + buf_list_size buf_l + Lwt_pipe.push_overhead
    in
    let size = Option.map (fun max -> (max, compute_size)) size in
    let st =
      {
        canceler;
        conn;
        encoding;
        messages = Lwt_pipe.create ?size ();
        worker = Lwt.return_unit;
        binary_chunks_size;
      }
    in
    Lwt_canceler.on_cancel st.canceler (fun () ->
        Lwt_pipe.close st.messages ;
        let rec loop () =
          match Lwt_pipe.pop_now st.messages with
          | exception Lwt_pipe.Closed ->
              ()
          | None ->
              ()
          | Some (_, None) ->
              loop ()
          | Some (_, Some w) ->
              Lwt.wakeup_later w (error (Exn Lwt_pipe.Closed)) ;
              loop ()
        in
        loop () ; Lwt.return_unit) ;
    st.worker <-
      Lwt_utils.worker
        "writer"
        ~on_event:Internal_event.Lwt_worker_event.on_event
        ~run:(fun () -> worker_loop st)
        ~cancel:(fun () -> Lwt_canceler.cancel st.canceler) ;
    st

  let shutdown st = Lwt_canceler.cancel st.canceler >>= fun () -> st.worker
end

type ('msg, 'meta) t = {
  conn : 'meta authenticated_connection;
  reader : ('msg, 'meta) Reader.t;
  writer : ('msg, 'meta) Writer.t;
}

let equal {conn = {fd = fd2; _}; _} {conn = {fd = fd1; _}; _} =
  P2p_io_scheduler.id fd1 = P2p_io_scheduler.id fd2

let pp ppf {conn; _} = P2p_connection.Info.pp (fun _ _ -> ()) ppf conn.info

let info {conn; _} = conn.info

let local_metadata {conn; _} = conn.info.local_metadata

let remote_metadata {conn; _} = conn.info.remote_metadata

let private_node {conn; _} = conn.info.private_node

let accept ?incoming_message_queue_size ?outgoing_message_queue_size
    ?binary_chunks_size ~canceler conn encoding =
  protect
    (fun () ->
      Ack.write ~canceler conn.fd conn.cryptobox_data Ack
      >>=? fun () -> Ack.read ~canceler conn.fd conn.cryptobox_data)
    ~on_error:(fun err ->
      P2p_io_scheduler.close conn.fd
      >>= fun _ ->
      match err with
      | [P2p_errors.Connection_closed] ->
          fail P2p_errors.Rejected_socket_connection
      | [P2p_errors.Decipher_error] ->
          fail P2p_errors.Invalid_auth
      | err ->
          Lwt.return_error err)
  >>=? function
  | Ack ->
      let canceler = Lwt_canceler.create () in
      let reader =
        Reader.run ?size:incoming_message_queue_size conn encoding canceler
      and writer =
        Writer.run
          ?size:outgoing_message_queue_size
          ?binary_chunks_size
          conn
          encoding
          canceler
      in
      let conn = {conn; reader; writer} in
      Lwt_canceler.on_cancel canceler (fun () ->
          P2p_io_scheduler.close conn.conn.fd >>= fun _ -> Lwt.return_unit) ;
      return conn
  | Nack_v_0 ->
      fail
        (P2p_errors.Rejected_by_nack
           {motive = P2p_rejection.No_motive; alternative_points = None})
  | Nack {motive; potential_peers_to_connect} ->
      fail
        (P2p_errors.Rejected_by_nack
           {motive; alternative_points = Some potential_peers_to_connect})

let catch_closed_pipe f =
  Lwt.catch f (function
      | Lwt_pipe.Closed ->
          fail P2p_errors.Connection_closed
      | exn ->
          fail (Exn exn))
  >>= function
  | Error (Exn Lwt_pipe.Closed :: _) ->
      fail P2p_errors.Connection_closed
  | (Error _ | Ok _) as v ->
      Lwt.return v

let pp_json encoding ppf msg =
  Data_encoding.Json.pp ppf (Data_encoding.Json.construct encoding msg)

let write {writer; conn; _} msg =
  catch_closed_pipe (fun () ->
      debug
        "Sending message to %a: %a"
        P2p_peer.Id.pp_short
        conn.info.peer_id
        (pp_json writer.encoding)
        msg ;
      Lwt.return (Writer.encode_message writer msg)
      >>=? fun buf ->
      Lwt_pipe.push writer.messages (buf, None) >>= fun () -> return_unit)

let write_sync {writer; conn; _} msg =
  catch_closed_pipe (fun () ->
      let (waiter, wakener) = Lwt.wait () in
      debug
        "Sending message to %a: %a"
        P2p_peer.Id.pp_short
        conn.info.peer_id
        (pp_json writer.encoding)
        msg ;
      Lwt.return (Writer.encode_message writer msg)
      >>=? fun buf ->
      Lwt_pipe.push writer.messages (buf, Some wakener) >>= fun () -> waiter)

let write_now {writer; conn; _} msg =
  debug
    "Try sending message to %a: %a"
    P2p_peer.Id.pp_short
    conn.info.peer_id
    (pp_json writer.encoding)
    msg ;
  Writer.encode_message writer msg
  >>? fun buf ->
  try Ok (Lwt_pipe.push_now writer.messages (buf, None))
  with Lwt_pipe.Closed -> error P2p_errors.Connection_closed

let rec split_bytes size bytes =
  if Bytes.length bytes <= size then [bytes]
  else
    Bytes.sub bytes 0 size
    :: split_bytes size (Bytes.sub bytes size (Bytes.length bytes - size))

let raw_write_sync {writer; _} bytes =
  let bytes = split_bytes writer.binary_chunks_size bytes in
  catch_closed_pipe (fun () ->
      let (waiter, wakener) = Lwt.wait () in
      Lwt_pipe.push writer.messages (bytes, Some wakener) >>= fun () -> waiter)

let read {reader; _} =
  catch_closed_pipe (fun () -> Lwt_pipe.pop reader.messages)

let read_now {reader; _} =
  try Lwt_pipe.pop_now reader.messages
  with Lwt_pipe.Closed -> Some (error P2p_errors.Connection_closed)

let stat {conn = {fd; _}; _} = P2p_io_scheduler.stat fd

let close ?(wait = false) st =
  ( if not wait then Lwt.return_unit
  else (
    Lwt_pipe.close st.reader.messages ;
    Lwt_pipe.close st.writer.messages ;
    st.writer.worker ) )
  >>= fun () ->
  Reader.shutdown st.reader
  >>= fun () ->
  Writer.shutdown st.writer
  >>= fun () -> P2p_io_scheduler.close st.conn.fd >>= fun _ -> Lwt.return_unit
