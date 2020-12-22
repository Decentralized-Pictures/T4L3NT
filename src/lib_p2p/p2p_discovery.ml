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

module Events = struct
  include Internal_event.Simple

  let section = ["p2p"; "discovery"]

  let create_socket =
    declare_0
      ~section
      ~name:"create_socket"
      ~msg:"Error creating a socket"
      ~level:Debug
      ()

  let message_received =
    declare_0
      ~section
      ~name:"message_received"
      ~msg:"Received discovery message"
      ~level:Debug
      ()

  let parse_error =
    declare_1
      ~section
      ~name:"parse_error"
      ~msg:"Failed to parse ({address})"
      ~level:Debug
      ("address", Data_encoding.string)

  let register_new =
    declare_2
      ~section
      ~name:"too_many_connections"
      ~msg:"Registering new point {address}:{port}"
      ~level:Notice
      ("address", P2p_addr.encoding)
      ("port", Data_encoding.int16)

  let unexpected_error =
    declare_2
      ~section
      ~name:"unexpected_error"
      ~msg:"Unexpected error in {worker} worker: {error}"
      ~level:Error
      ("worker", Data_encoding.string)
      ("error", Error_monad.trace_encoding)

  let unexpected_exit =
    declare_0
      ~section
      ~name:"unexpected_exit"
      ~msg:"Answer worker exited unexpectedly"
      ~level:Error
      ()

  let broadcast_message =
    declare_0
      ~section
      ~name:"broadcast_message"
      ~msg:"Broadcasting discovery message"
      ~level:Debug
      ()

  let broadcast_error =
    declare_0
      ~section
      ~name:"broadcast_error"
      ~msg:"Error broadcasting a discovery request"
      ~level:Debug
      ()
end

type pool = Pool : ('msg, 'meta, 'meta_conn) P2p_pool.t -> pool

module Message = struct
  let encoding =
    Data_encoding.(tup3 (Fixed.string 10) P2p_peer.Id.encoding int16)

  let length = Data_encoding.Binary.fixed_length_exn encoding

  let key = "DISCOMAGIC"

  let make peer_id port =
    Data_encoding.Binary.to_bytes_exn encoding (key, peer_id, port)
end

module Answer = struct
  type t = {
    my_peer_id : P2p_peer.Id.t;
    pool : pool;
    discovery_port : int;
    canceler : Lwt_canceler.t;
    trust_discovered_peers : bool;
    mutable worker : unit Lwt.t;
  }

  let create_socket st =
    Lwt.catch
      (fun () ->
        let socket = Lwt_unix.socket PF_INET SOCK_DGRAM 0 in
        Lwt_canceler.on_cancel st.canceler (fun () ->
            Lwt_utils_unix.safe_close socket
            >>= function
            | Error trace ->
                Format.eprintf "Uncaught error: %a\n%!" pp_print_error trace ;
                Lwt.return_unit
            | Ok () ->
                Lwt.return_unit) ;
        Lwt_unix.setsockopt socket SO_BROADCAST true ;
        Lwt_unix.setsockopt socket SO_REUSEADDR true ;
        let addr =
          Lwt_unix.ADDR_INET (Unix.inet_addr_any, st.discovery_port)
        in
        Lwt_unix.bind socket addr >>= fun () -> Lwt.return socket)
      (fun exn -> Events.(emit create_socket) () >>= fun () -> Lwt.fail exn)

  let loop st =
    protect ~canceler:st.canceler (fun () ->
        create_socket st >>= fun socket -> return socket)
    >>=? fun socket ->
    (* Infinite loop, should never exit. *)
    let rec aux () =
      let buf = Bytes.create Message.length in
      protect ~canceler:st.canceler (fun () ->
          Lwt_unix.recvfrom socket buf 0 Message.length []
          >>= fun content ->
          Events.(emit message_received) () >>= fun () -> return content)
      >>=? function
      | (len, Lwt_unix.ADDR_INET (remote_addr, _))
        when Compare.Int.equal len Message.length -> (
        match Data_encoding.Binary.of_bytes_opt Message.encoding buf with
        | Some (key, remote_peer_id, remote_port)
          when Compare.String.equal key Message.key
               && not (P2p_peer.Id.equal remote_peer_id st.my_peer_id) -> (
            let s_addr = Unix.string_of_inet_addr remote_addr in
            match P2p_addr.of_string_opt s_addr with
            | None ->
                Events.(emit parse_error) s_addr >>= fun () -> aux ()
            | Some addr ->
                let (Pool pool) = st.pool in
                Events.(emit register_new) (addr, remote_port)
                >>= fun () ->
                P2p_pool.register_new_point
                  ~trusted:st.trust_discovered_peers
                  pool
                  (addr, remote_port)
                |> ignore ;
                aux () )
        | _ ->
            aux () )
      | _ ->
          aux ()
    in
    aux ()

  let worker_loop st =
    loop st
    >>= function
    | Error (Canceled :: _) ->
        Lwt.return_unit
    | Error err ->
        Events.(emit unexpected_error) ("answer", err)
        >>= fun () -> Lwt_canceler.cancel st.canceler
    | Ok () ->
        Events.(emit unexpected_exit) ()
        >>= fun () -> Lwt_canceler.cancel st.canceler

  let create my_peer_id pool ~trust_discovered_peers ~discovery_port =
    {
      canceler = Lwt_canceler.create ();
      my_peer_id;
      discovery_port;
      trust_discovered_peers;
      pool = Pool pool;
      worker = Lwt.return_unit;
    }

  let activate st =
    st.worker <-
      Lwt_utils.worker
        "discovery_answer"
        ~on_event:Internal_event.Lwt_worker_event.on_event
        ~run:(fun () -> worker_loop st)
        ~cancel:(fun () -> Lwt_canceler.cancel st.canceler)
end

(* ************************************************************ *)
(* Sender  *)

module Sender = struct
  type t = {
    canceler : Lwt_canceler.t;
    my_peer_id : P2p_peer.Id.t;
    listening_port : int;
    discovery_port : int;
    discovery_addr : Ipaddr.V4.t;
    pool : pool;
    restart_discovery : unit Lwt_condition.t;
    mutable worker : unit Lwt.t;
  }

  module Config = struct
    type t = {delay : float; loop : int}

    let initial = {delay = 0.1; loop = 0}

    let increase_delay config = {config with delay = 2.0 *. config.delay}

    let max_loop = 10
  end

  let broadcast_message st =
    let msg = Message.make st.my_peer_id st.listening_port in
    Lwt.catch
      (fun () ->
        let socket = Lwt_unix.(socket PF_INET SOCK_DGRAM 0) in
        Lwt_canceler.on_cancel st.canceler (fun () ->
            Lwt_utils_unix.safe_close socket
            >>= function
            | Error trace ->
                Format.eprintf "Uncaught error: %a\n%!" pp_print_error trace ;
                Lwt.return_unit
            | Ok () ->
                Lwt.return_unit) ;
        Lwt_unix.setsockopt socket Lwt_unix.SO_BROADCAST true ;
        let broadcast_ipv4 = Ipaddr_unix.V4.to_inet_addr st.discovery_addr in
        let addr = Lwt_unix.ADDR_INET (broadcast_ipv4, st.discovery_port) in
        Lwt_unix.connect socket addr
        >>= fun () ->
        Events.(emit broadcast_message) ()
        >>= fun () ->
        Lwt_unix.sendto socket msg 0 Message.length [] addr
        >>= fun _len ->
        Lwt_utils_unix.safe_close socket
        >>= function
        | Error trace ->
            Format.eprintf "Uncaught error: %a\n%!" pp_print_error trace ;
            Lwt.return_unit
        | Ok () ->
            Lwt.return_unit)
      (fun _exn -> Events.(emit broadcast_error) ())

  let rec worker_loop sender_config st =
    protect ~canceler:st.canceler (fun () ->
        broadcast_message st >>= fun () -> return_unit)
    >>=? (fun () ->
           protect ~canceler:st.canceler (fun () ->
               Lwt.pick
                 [ ( Lwt_condition.wait st.restart_discovery
                   >>= fun () -> return Config.initial );
                   ( Lwt_unix.sleep sender_config.Config.delay
                   >>= fun () ->
                   return
                     {sender_config with Config.loop = succ sender_config.loop}
                   ) ]))
    >>= function
    | Ok config when config.Config.loop = Config.max_loop ->
        let new_sender_config = {config with Config.loop = pred config.loop} in
        worker_loop new_sender_config st
    | Ok config ->
        let new_sender_config = Config.increase_delay config in
        worker_loop new_sender_config st
    | Error (Canceled :: _) ->
        Lwt.return_unit
    | Error err ->
        Events.(emit unexpected_error) ("sender", err)
        >>= fun () -> Lwt_canceler.cancel st.canceler

  let create my_peer_id pool ~listening_port ~discovery_port ~discovery_addr =
    {
      canceler = Lwt_canceler.create ();
      my_peer_id;
      listening_port;
      discovery_port;
      discovery_addr;
      restart_discovery = Lwt_condition.create ();
      pool = Pool pool;
      worker = Lwt.return_unit;
    }

  let activate st =
    st.worker <-
      Lwt_utils.worker
        "discovery_sender"
        ~on_event:Internal_event.Lwt_worker_event.on_event
        ~run:(fun () -> worker_loop Config.initial st)
        ~cancel:(fun () -> Lwt_canceler.cancel st.canceler)
end

(* ********************************************************************** *)

type t = {answer : Answer.t; sender : Sender.t}

let create ~listening_port ~discovery_port ~discovery_addr
    ~trust_discovered_peers pool my_peer_id =
  let answer =
    Answer.create my_peer_id pool ~discovery_port ~trust_discovered_peers
  in
  let sender =
    Sender.create
      my_peer_id
      pool
      ~listening_port
      ~discovery_port
      ~discovery_addr
  in
  {answer; sender}

let activate {answer; sender} = Answer.activate answer ; Sender.activate sender

let wakeup t = Lwt_condition.signal t.sender.restart_discovery ()

let shutdown t =
  Lwt.join
    [ Lwt_canceler.cancel t.answer.canceler;
      Lwt_canceler.cancel t.sender.canceler ]
