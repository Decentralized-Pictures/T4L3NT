(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2020 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

module Events = P2p_events.P2p_io_scheduler

let alpha = 0.2

module type IO = sig
  val name : string

  type in_param

  type data

  val length : data -> int

  val pop : in_param -> data tzresult Lwt.t

  type out_param

  val push : out_param -> data -> unit tzresult Lwt.t

  val close : out_param -> error list -> unit Lwt.t
end

module Scheduler (IO : IO) = struct
  (* Two labels or constructors of the same name are defined in two mutually
     recursive types: fields canceler, counter and quota *)
  [@@@ocaml.warning "-30"]

  type t = {
    ma_state : Moving_average.state;
    canceler : Lwt_canceler.t;
    mutable worker : unit Lwt.t;
    counter : Moving_average.t;
    max_speed : int option;
    mutable quota : int;
    quota_updated : unit Lwt_condition.t;
    readys : unit Lwt_condition.t;
    readys_high : (connection * IO.data tzresult) Queue.t;
    readys_low : (connection * IO.data tzresult) Queue.t;
  }

  and connection = {
    id : int;
    mutable closed : bool;
    canceler : Lwt_canceler.t;
    in_param : IO.in_param;
    out_param : IO.out_param;
    mutable current_pop : IO.data tzresult Lwt.t;
    mutable current_push : unit tzresult Lwt.t;
    counter : Moving_average.t;
    mutable quota : int;
  }

  [@@@ocaml.warning "+30"]

  let cancel (conn : connection) err =
    if conn.closed then Lwt.return_unit
    else
      Events.(emit connection_closed) ("cancel", conn.id, IO.name)
      >>= fun () ->
      conn.closed <- true ;
      Lwt.catch
        (fun () -> IO.close conn.out_param err)
        (fun _ -> Lwt.return_unit)
      >>= fun () -> Lwt_canceler.cancel conn.canceler

  let waiter st conn =
    assert (Lwt.state conn.current_pop <> Sleep) ;
    conn.current_pop <- IO.pop conn.in_param ;
    Lwt_utils.dont_wait
      (fun exc ->
        Format.eprintf "Uncaught exception: %s\n%!" (Printexc.to_string exc))
      (fun () ->
        (* To ensure that there is no concurrent calls to IO.pop, we
           wait for the promise to be fulfilled. *)
        conn.current_pop
        >>= fun res ->
        conn.current_push
        >>= fun _ ->
        let was_empty =
          Queue.is_empty st.readys_high && Queue.is_empty st.readys_low
        in
        if conn.quota > 0 then Queue.push (conn, res) st.readys_high
        else Queue.push (conn, res) st.readys_low ;
        if was_empty then Lwt_condition.broadcast st.readys () ;
        Lwt.return_unit)

  let wait_data st =
    let is_empty =
      Queue.is_empty st.readys_high && Queue.is_empty st.readys_low
    in
    if is_empty then Lwt_condition.wait st.readys else Lwt.return_unit

  let check_quota st =
    if st.max_speed <> None && st.quota < 0 then
      Events.(emit wait_quota) IO.name
      >>= fun () -> Lwt_condition.wait st.quota_updated
    else Lwt_unix.yield ()

  let rec worker_loop st =
    check_quota st
    >>= fun () ->
    Events.(emit wait) IO.name
    >>= fun () ->
    Lwt.pick [Lwt_canceler.cancellation st.canceler; wait_data st]
    >>= fun () ->
    if Lwt_canceler.canceled st.canceler then Lwt.return_unit
    else
      let (prio, (conn, msg)) =
        if not (Queue.is_empty st.readys_high) then
          (true, Queue.pop st.readys_high)
        else (false, Queue.pop st.readys_low)
      in
      match msg with
      | Error (Canceled :: _) ->
          worker_loop st
      | Error (P2p_errors.Connection_closed :: _ as err)
      | Error (Exn Lwt_pipe.Closed :: _ as err)
      | Error (Exn (Unix.Unix_error ((EBADF | ETIMEDOUT), _, _)) :: _ as err)
        ->
          Events.(emit connection_closed) ("pop", conn.id, IO.name)
          >>= fun () -> cancel conn err >>= fun () -> worker_loop st
      | Error err ->
          Events.(emit unexpected_error) ("pop", conn.id, IO.name, err)
          >>= fun () -> cancel conn err >>= fun () -> worker_loop st
      | Ok msg ->
          conn.current_push <-
            ( IO.push conn.out_param msg
            >>= function
            | Ok () | Error (Canceled :: _) ->
                return_unit
            | Error (P2p_errors.Connection_closed :: _ as err)
            | Error (Exn (Unix.Unix_error (EBADF, _, _)) :: _ as err)
            | Error (Exn Lwt_pipe.Closed :: _ as err) ->
                Events.(emit connection_closed) ("push", conn.id, IO.name)
                >>= fun () -> cancel conn err >>= fun () -> return_unit
            | Error err ->
                Events.(emit unexpected_error) ("push", conn.id, IO.name, err)
                >>= fun () ->
                cancel conn err >>= fun () -> Lwt.return_error err ) ;
          let len = IO.length msg in
          Events.(emit handle_connection) (len, conn.id, IO.name)
          >>= fun () ->
          Moving_average.add st.counter len ;
          st.quota <- st.quota - len ;
          Moving_average.add conn.counter len ;
          if prio then conn.quota <- conn.quota - len ;
          waiter st conn ;
          worker_loop st

  let create ma_state max_speed =
    let st =
      {
        ma_state;
        canceler = Lwt_canceler.create ();
        worker = Lwt.return_unit;
        counter = Moving_average.create ma_state ~init:0 ~alpha;
        max_speed;
        quota = Option.value ~default:0 max_speed;
        quota_updated = Lwt_condition.create ();
        readys = Lwt_condition.create ();
        readys_high = Queue.create ();
        readys_low = Queue.create ();
      }
    in
    st.worker <-
      Lwt_utils.worker
        IO.name
        ~on_event:Internal_event.Lwt_worker_event.on_event
        ~run:(fun () -> worker_loop st)
        ~cancel:(fun () -> Lwt_canceler.cancel st.canceler) ;
    st

  let create_connection st in_param out_param canceler id =
    Events.(emit__dont_wait__use_with_care create_connection (id, IO.name)) ;
    let conn =
      {
        id;
        closed = false;
        canceler;
        in_param;
        out_param;
        current_pop = Lwt.fail Not_found (* dummy *);
        current_push = return_unit;
        counter = Moving_average.create st.ma_state ~init:0 ~alpha;
        quota = 0;
      }
    in
    waiter st conn ; conn

  let update_quota st =
    Events.(emit__dont_wait__use_with_care update_quota IO.name) ;
    Option.iter
      (fun quota ->
        st.quota <- min st.quota 0 + quota ;
        Lwt_condition.broadcast st.quota_updated ())
      st.max_speed ;
    if not (Queue.is_empty st.readys_low) then (
      let tmp = Queue.create () in
      Queue.iter
        (fun (((conn : connection), _) as msg) ->
          if conn.quota > 0 then Queue.push msg st.readys_high
          else Queue.push msg tmp)
        st.readys_low ;
      Queue.clear st.readys_low ;
      Queue.transfer tmp st.readys_low )

  let shutdown st =
    Lwt_canceler.cancel st.canceler
    >>= fun () -> st.worker >>= fun () -> Events.(emit shutdown) IO.name
end

module ReadIO = struct
  let name = "io_scheduler(read)"

  type in_param = {
    fd : P2p_fd.t;
    (* File descriptor from which data are read *)
    maxlen : int;
    (* Length of data we want to read from the file descriptor *)
    read_buffer : Circular_buffer.t; (* Cache where data will be stored *)
  }

  type data = Circular_buffer.data

  let length = Circular_buffer.length

  (* Invariant: Given a connection, there is not concurrent call to
     pop *)
  let pop {fd; maxlen; read_buffer} =
    Lwt.catch
      (fun () ->
        Circular_buffer.write ~maxlen ~fill_using:(P2p_fd.read fd) read_buffer
        >>= fun data ->
        if Circular_buffer.length data = 0 then
          fail P2p_errors.Connection_closed
        else return data)
      (function
        | Unix.Unix_error (Unix.ECONNRESET, _, _) ->
            fail P2p_errors.Connection_closed
        | exn ->
            Lwt.return (error_exn exn))

  type out_param = Circular_buffer.data tzresult Lwt_pipe.t

  let push p msg =
    Lwt.catch
      (fun () -> Lwt_pipe.push p (Ok msg) >>= fun () -> return_unit)
      (fun exn -> fail (Exn exn))

  let close p err =
    Lwt.catch
      (fun () -> Lwt_pipe.push p (Error err))
      (fun _ -> Lwt.return_unit)
end

module ReadScheduler = Scheduler (ReadIO)

module WriteIO = struct
  let name = "io_scheduler(write)"

  type in_param = Bytes.t Lwt_pipe.t

  type data = Bytes.t

  let length = Bytes.length

  let pop p =
    Lwt.catch
      (fun () -> Lwt_pipe.pop p >>= return)
      (function
        | Lwt_pipe.Closed -> fail (Exn Lwt_pipe.Closed) | _ -> assert false)

  type out_param = P2p_fd.t

  let push fd buf =
    Lwt.catch
      (fun () -> P2p_fd.write fd buf >>= return)
      (function
        | Unix.Unix_error (Unix.ECONNRESET, _, _)
        | Unix.Unix_error (Unix.EPIPE, _, _)
        | Lwt.Canceled
        | End_of_file ->
            fail P2p_errors.Connection_closed
        | exn ->
            Lwt.return (error_exn exn))

  let close _p _err = Lwt.return_unit
end

module WriteScheduler = Scheduler (WriteIO)

type connection = {
  fd : P2p_fd.t;
  canceler : Lwt_canceler.t;
  read_conn : ReadScheduler.connection;
  read_buffer : Circular_buffer.t;
  read_queue : Circular_buffer.data tzresult Lwt_pipe.t;
  write_conn : WriteScheduler.connection;
  write_queue : Bytes.t Lwt_pipe.t;
  mutable partial_read : Circular_buffer.data option;
  remove_from_connection_table : unit -> unit;
}

type t = {
  mutable closed : bool;
  ma_state : Moving_average.state;
  connected : connection P2p_fd.Table.t;
  read_scheduler : ReadScheduler.t;
  write_scheduler : WriteScheduler.t;
  max_upload_speed : int option;
  (* bytes per second. *)
  max_download_speed : int option;
  read_buffer_size : int;
  read_queue_size : int option;
  write_queue_size : int option;
}

let reset_quota st =
  Events.(emit__dont_wait__use_with_care reset_quota ()) ;
  let {Moving_average.average = current_inflow; _} =
    Moving_average.stat st.read_scheduler.counter
  and {Moving_average.average = current_outflow; _} =
    Moving_average.stat st.write_scheduler.counter
  in
  let nb_conn = P2p_fd.Table.length st.connected in
  ( if nb_conn > 0 then
    let fair_read_quota = current_inflow / nb_conn
    and fair_write_quota = current_outflow / nb_conn in
    P2p_fd.Table.iter
      (fun _id conn ->
        conn.read_conn.quota <- min conn.read_conn.quota 0 + fair_read_quota ;
        conn.write_conn.quota <- min conn.write_conn.quota 0 + fair_write_quota)
      st.connected ) ;
  ReadScheduler.update_quota st.read_scheduler ;
  WriteScheduler.update_quota st.write_scheduler

let create ?max_upload_speed ?max_download_speed ?read_queue_size
    ?write_queue_size ~read_buffer_size () =
  Events.(emit__dont_wait__use_with_care create ()) ;
  let ma_state =
    Moving_average.fresh_state ~id:"p2p-io-sched" ~refresh_interval:1.0
  in
  let st =
    {
      closed = false;
      ma_state;
      connected = P2p_fd.Table.create 53;
      read_scheduler = ReadScheduler.create ma_state max_download_speed;
      write_scheduler = WriteScheduler.create ma_state max_upload_speed;
      max_upload_speed;
      max_download_speed;
      read_buffer_size;
      read_queue_size;
      write_queue_size;
    }
  in
  Moving_average.on_update ma_state (fun () -> reset_quota st) ;
  st

let ma_state {ma_state; _} = ma_state

exception Closed

let read_size = function
  | Ok data ->
      (Sys.word_size / 8 * 8)
      + Circular_buffer.length data
      + Lwt_pipe.push_overhead
  | Error _ ->
      0

(* we push Error only when we close the socket,
                    we don't fear memory leaks in that case... *)

let write_size bytes =
  (Sys.word_size / 8 * 6) + Bytes.length bytes + Lwt_pipe.push_overhead

let register st fd =
  if st.closed then (
    Error_monad.dont_wait
      (fun exc ->
        Format.eprintf "Uncaught exception: %s\n%!" (Printexc.to_string exc))
      (fun trace ->
        Format.eprintf "Uncaught error: %a\n%!" pp_print_error trace)
      (fun () -> P2p_fd.close fd) ;
    raise Closed )
  else
    let id = P2p_fd.id fd in
    let canceler = Lwt_canceler.create () in
    let read_size = Option.map (fun v -> (v, read_size)) st.read_queue_size in
    let write_size =
      Option.map (fun v -> (v, write_size)) st.write_queue_size
    in
    let read_queue = Lwt_pipe.create ?size:read_size () in
    let write_queue = Lwt_pipe.create ?size:write_size () in
    (* This buffer is allocated once and is reused everytime we read a
       message from the corresponding file descriptor. *)
    let read_buffer =
      Circular_buffer.create ~maxlength:(st.read_buffer_size * 2) ()
    in
    let read_conn =
      ReadScheduler.create_connection
        st.read_scheduler
        {fd; maxlen = st.read_buffer_size; read_buffer}
        read_queue
        canceler
        id
    and write_conn =
      WriteScheduler.create_connection
        st.write_scheduler
        write_queue
        fd
        canceler
        id
    in
    Lwt_canceler.on_cancel canceler (fun () ->
        P2p_fd.Table.remove st.connected fd ;
        Moving_average.destroy st.ma_state read_conn.counter ;
        Moving_average.destroy st.ma_state write_conn.counter ;
        Lwt_pipe.close write_queue ;
        Lwt_pipe.close read_queue ;
        P2p_fd.close fd
        >>= function
        | Error trace ->
            Format.eprintf "Uncaught error: %a\n%!" pp_print_error trace ;
            Lwt.return_unit
        | Ok () ->
            Lwt.return_unit) ;
    let conn =
      {
        fd;
        canceler;
        read_queue;
        read_buffer;
        read_conn;
        write_queue;
        write_conn;
        partial_read = None;
        remove_from_connection_table =
          (fun () -> P2p_fd.Table.remove st.connected fd);
      }
    in
    P2p_fd.Table.add st.connected conn.fd conn ;
    (* Events.(emit register) id) *)
    conn

let write ?canceler {write_queue; _} msg =
  trace P2p_errors.Connection_closed
  @@ protect ?canceler (fun () ->
         Lwt_pipe.push write_queue msg >>= fun () -> return_unit)

let write_now {write_queue; _} msg = Lwt_pipe.push_now write_queue msg

let read_from conn ?pos ?len buf data =
  let maxlen = Bytes.length buf in
  let pos = Option.value ~default:0 pos in
  assert (0 <= pos && pos < maxlen) ;
  let len = Option.value ~default:(maxlen - pos) len in
  assert (len <= maxlen - pos) ;
  match data with
  | Ok data ->
      let read_len = min len (Circular_buffer.length data) in
      Option.iter
        (fun data -> conn.partial_read <- Some data)
        (Circular_buffer.read
           data
           conn.read_buffer
           ~len:read_len
           ~into:buf
           ~offset:pos) ;
      Ok read_len
  | Error _ ->
      error P2p_errors.Connection_closed

let read_now conn ?pos ?len buf =
  match conn.partial_read with
  | Some msg ->
      conn.partial_read <- None ;
      Some (read_from conn ?pos ?len buf (Ok msg))
  | None -> (
    try
      Option.map
        (read_from conn ?pos ?len buf)
        (Lwt_pipe.pop_now conn.read_queue)
    with Lwt_pipe.Closed -> Some (error P2p_errors.Connection_closed) )

let read ?canceler conn ?pos ?len buf =
  match conn.partial_read with
  | Some msg ->
      conn.partial_read <- None ;
      Lwt.return (read_from conn ?pos ?len buf (Ok msg))
  | None ->
      Lwt.catch
        (fun () ->
          protect ?canceler (fun () -> Lwt_pipe.pop conn.read_queue)
          >|= fun msg -> read_from conn ?pos ?len buf msg)
        (fun _ -> fail P2p_errors.Connection_closed)

let read_full ?canceler conn ?pos ?len buf =
  let maxlen = Bytes.length buf in
  let pos = Option.value ~default:0 pos in
  let len = Option.value ~default:(maxlen - pos) len in
  assert (0 <= pos && pos < maxlen) ;
  assert (len <= maxlen - pos) ;
  let rec loop pos len =
    if len = 0 then return_unit
    else
      read ?canceler conn ~pos ~len buf
      >>=? fun read_len -> loop (pos + read_len) (len - read_len)
  in
  loop pos len

let convert ~ws ~rs =
  {
    P2p_stat.total_sent = ws.Moving_average.total;
    total_recv = rs.Moving_average.total;
    current_outflow = ws.average;
    current_inflow = rs.average;
  }

let global_stat {read_scheduler; write_scheduler; _} =
  let rs = Moving_average.stat read_scheduler.counter
  and ws = Moving_average.stat write_scheduler.counter in
  convert ~rs ~ws

let stat {read_conn; write_conn; _} =
  let rs = Moving_average.stat read_conn.counter
  and ws = Moving_average.stat write_conn.counter in
  convert ~rs ~ws

let close ?timeout conn =
  let id = P2p_fd.id conn.fd in
  conn.remove_from_connection_table () ;
  Lwt_pipe.close conn.write_queue ;
  ( match timeout with
  | None ->
      return (Lwt_canceler.cancellation conn.canceler)
  | Some timeout ->
      with_timeout
        ~canceler:conn.canceler
        (Lwt_unix.sleep timeout)
        (fun canceler -> return (Lwt_canceler.cancellation canceler)) )
  >>=? fun _ ->
  conn.write_conn.current_push
  >>= fun res -> Events.(emit close) id >>= fun () -> Lwt.return res

let iter_connection {connected; _} f =
  P2p_fd.Table.iter (fun _ conn -> f conn) connected

let shutdown ?timeout st =
  st.closed <- true ;
  ReadScheduler.shutdown st.read_scheduler
  >>= fun () ->
  P2p_fd.Table.iter_p
    (fun _peer_id conn -> close ?timeout conn >>= fun _ -> Lwt.return_unit)
    st.connected
  >>= fun () ->
  WriteScheduler.shutdown st.write_scheduler
  >>= fun () -> Events.(emit shutdown_scheduler) ()

let id conn = P2p_fd.id conn.fd
