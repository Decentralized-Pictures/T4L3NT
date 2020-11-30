(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

(** An error returned when trying to communicate with a worker that
    has been closed.*)
type worker_name = {base : string; name : string}

type Error_monad.error += Closed of worker_name

let () =
  register_error_kind
    `Permanent
    ~id:"worker.closed"
    ~title:"Worker closed"
    ~description:
      "An operation on a worker could not complete before it was shut down."
    ~pp:(fun ppf w ->
      Format.fprintf ppf "Worker %s[%s] has been shut down." w.base w.name)
    Data_encoding.(
      conv
        (fun {base; name} -> (base, name))
        (fun (name, base) -> {base; name})
        (obj1 (req "worker" (tup2 string string))))
    (function Closed w -> Some w | _ -> None)
    (fun w -> Closed w)

module type T = sig
  module Name : Worker_intf.NAME

  module Event : Worker_intf.EVENT

  module Request : Worker_intf.REQUEST

  module Types : Worker_intf.TYPES

  (** A handle to a specific worker, parameterized by the type of
      internal message buffer. *)
  type 'kind t

  (** A handle to a table of workers. *)
  type 'kind table

  (** Internal buffer kinds used as parameters to {!t}. *)
  type 'a queue

  and bounded

  and infinite

  type dropbox

  (** Supported kinds of internal buffers. *)
  type _ buffer_kind =
    | Queue : infinite queue buffer_kind
    | Bounded : {size : int} -> bounded queue buffer_kind
    | Dropbox : {
        merge :
          dropbox t -> any_request -> any_request option -> any_request option;
      }
        -> dropbox buffer_kind

  and any_request = Any_request : _ Request.t -> any_request

  (** Create a table of workers. *)
  val create_table : 'kind buffer_kind -> 'kind table

  (** The callback handlers specific to each worker instance. *)
  module type HANDLERS = sig
    (** Placeholder replaced with {!t} with the right parameters
        provided by the type of buffer chosen at {!launch}.*)
    type self

    (** Builds the initial internal state of a worker at launch.
        It is possible to initialize the message queue.
        Of course calling {!state} will fail at that point. *)
    val on_launch :
      self -> Name.t -> Types.parameters -> Types.state tzresult Lwt.t

    (** The main request processor, i.e. the body of the event loop. *)
    val on_request : self -> 'a Request.t -> 'a tzresult Lwt.t

    (** Called when no request has been made before the timeout, if
        the parameter has been passed to {!launch}. *)
    val on_no_request : self -> unit tzresult Lwt.t

    (** A function called when terminating a worker. *)
    val on_close : self -> unit Lwt.t

    (** A function called at the end of the worker loop in case of an
        abnormal error. This function can handle the error by
        returning [Ok ()], or leave the default unexpected error
        behaviour by returning its parameter. A possibility is to
        handle the error for ad-hoc logging, and still use
        {!trigger_shutdown} to kill the worker. *)
    val on_error :
      self ->
      Request.view ->
      Worker_types.request_status ->
      error list ->
      unit tzresult Lwt.t

    (** A function called at the end of the worker loop in case of a
        successful treatment of the current request. *)
    val on_completion :
      self -> 'a Request.t -> 'a -> Worker_types.request_status -> unit Lwt.t
  end

  (** Creates a new worker instance.
      Parameter [queue_size] not passed means unlimited queue. *)
  val launch :
    'kind table ->
    ?timeout:Time.System.Span.t ->
    Worker_types.limits ->
    Name.t ->
    Types.parameters ->
    (module HANDLERS with type self = 'kind t) ->
    'kind t tzresult Lwt.t

  (** Triggers a worker termination and waits for its completion.
      Cannot be called from within the handlers.  *)
  val shutdown : _ t -> unit Lwt.t

  module type BOX = sig
    type t

    val put_request : t -> 'a Request.t -> unit

    val put_request_and_wait : t -> 'a Request.t -> 'a tzresult Lwt.t
  end

  module type QUEUE = sig
    type 'a t

    val push_request_and_wait : 'q t -> 'a Request.t -> 'a tzresult Lwt.t

    val push_request : 'q t -> 'a Request.t -> unit Lwt.t

    val pending_requests : 'a t -> (Time.System.t * Request.view) list

    val pending_requests_length : 'a t -> int
  end

  module type BOUNDED_QUEUE = sig
    type t

    val try_push_request_now : t -> 'a Request.t -> bool
  end

  module Dropbox : sig
    include BOX with type t := dropbox t
  end

  module Queue : sig
    include QUEUE with type 'a t := 'a queue t

    include BOUNDED_QUEUE with type t := bounded queue t

    (** Adds a message to the queue immediately. *)
    val push_request_now : infinite queue t -> 'a Request.t -> unit
  end

  (** Detects cancellation from within the request handler to stop
      asynchronous operations. *)
  val protect :
    _ t ->
    ?on_error:(error list -> 'b tzresult Lwt.t) ->
    (unit -> 'b tzresult Lwt.t) ->
    'b tzresult Lwt.t

  (** Exports the canceler to allow cancellation of other tasks when this
      worker is shut down or when it dies. *)
  val canceler : _ t -> Lwt_canceler.t

  (** Triggers a worker termination. *)
  val trigger_shutdown : _ t -> unit

  (** Record an event in the backlog. *)
  val record_event : _ t -> Event.t -> unit

  (** Record an event and make sure it is logged. *)
  val log_event : _ t -> Event.t -> unit Lwt.t

  (** Access the internal state, once initialized. *)
  val state : _ t -> Types.state

  (** Access the event backlog. *)
  val last_events : _ t -> (Internal_event.level * Event.t list) list

  (** Introspect the message queue, gives the times requests were pushed. *)
  val pending_requests : _ queue t -> (Time.System.t * Request.view) list

  (** Get the running status of a worker. *)
  val status : _ t -> Worker_types.worker_status

  (** Get the request being treated by a worker.
      Gives the time the request was pushed, and the time its
      treatment started. *)
  val current_request :
    _ t -> (Time.System.t * Time.System.t * Request.view) option

  val information : _ t -> Worker_types.worker_information

  (** Introspect the state of a worker. *)
  val view : _ t -> Types.view

  (** Lists the running workers in this group. *)
  val list : 'a table -> (Name.t * 'a t) list

  (** [find_opt table n] is [Some worker] if the [worker] is in the [table] and
      has name [n]. *)
  val find_opt : 'a table -> Name.t -> 'a t option
end

module Make
    (Name : Worker_intf.NAME)
    (Event : Worker_intf.EVENT)
    (Request : Worker_intf.REQUEST)
    (Types : Worker_intf.TYPES)
    (Logger : Worker_intf.LOGGER
                with module Event = Event
                 and type Request.view = Request.view) =
struct
  module Name = Name
  module Event = Event
  module Request = Request
  module Types = Types
  module Logger = Logger

  module Nametbl = Hashtbl.MakeSeeded (struct
    type t = Name.t

    let hash = Hashtbl.seeded_hash

    let equal = Name.equal
  end)

  let base_name = String.concat "-" Name.base

  type message = Message : 'a Request.t * 'a tzresult Lwt.u option -> message

  type 'a queue

  and bounded

  and infinite

  type dropbox

  type _ buffer_kind =
    | Queue : infinite queue buffer_kind
    | Bounded : {size : int} -> bounded queue buffer_kind
    | Dropbox : {
        merge :
          dropbox t -> any_request -> any_request option -> any_request option;
      }
        -> dropbox buffer_kind

  and any_request = Any_request : _ Request.t -> any_request

  and _ buffer =
    | Queue_buffer :
        (Time.System.t * message) Lwt_pipe.t
        -> infinite queue buffer
    | Bounded_buffer :
        (Time.System.t * message) Lwt_pipe.t
        -> bounded queue buffer
    | Dropbox_buffer :
        (Time.System.t * message) Lwt_dropbox.t
        -> dropbox buffer

  and 'kind t = {
    limits : Worker_types.limits;
    timeout : Time.System.Span.t option;
    parameters : Types.parameters;
    mutable (* only for init *) worker : unit Lwt.t;
    mutable (* only for init *) state : Types.state option;
    buffer : 'kind buffer;
    event_log : (Internal_event.level * Event.t Ringo.Ring.t) list;
    canceler : Lwt_canceler.t;
    name : Name.t;
    id : int;
    mutable status : Worker_types.worker_status;
    mutable current_request :
      (Time.System.t * Time.System.t * Request.view) option;
    logEvent : (module Internal_event.EVENT with type t = Logger.t);
    table : 'kind table;
  }

  and 'kind table = {
    buffer_kind : 'kind buffer_kind;
    mutable last_id : int;
    instances : 'kind t Nametbl.t;
  }

  let queue_item ?u r = (Systime_os.now (), Message (r, u))

  let drop_request w merge message_box request =
    try
      match
        match Lwt_dropbox.peek message_box with
        | None ->
            merge w (Any_request request) None
        | Some (_, Message (old, _)) ->
            Lwt.ignore_result (Lwt_dropbox.take message_box) ;
            merge w (Any_request request) (Some (Any_request old))
      with
      | None ->
          ()
      | Some (Any_request neu) ->
          Lwt_dropbox.put message_box (Systime_os.now (), Message (neu, None))
    with Lwt_dropbox.Closed -> ()

  let push_request_and_wait w message_queue request =
    let (t, u) = Lwt.wait () in
    Lwt.catch
      (fun () ->
        Lwt_pipe.push message_queue (queue_item ~u request) >>= fun () -> t)
      (function
        | Lwt_pipe.Closed ->
            let name = Format.asprintf "%a" Name.pp w.name in
            fail (Closed {base = base_name; name})
        | exn ->
            fail (Exn exn))

  let drop_request_and_wait w message_box request =
    let (t, u) = Lwt.wait () in
    Lwt.catch
      (fun () ->
        Lwt_dropbox.put message_box (queue_item ~u request) ;
        t)
      (function
        | Lwt_pipe.Closed ->
            let name = Format.asprintf "%a" Name.pp w.name in
            fail (Closed {base = base_name; name})
        | exn ->
            fail (Exn exn))

  module type BOX = sig
    type t

    val put_request : t -> 'a Request.t -> unit

    val put_request_and_wait : t -> 'a Request.t -> 'a tzresult Lwt.t
  end

  module type QUEUE = sig
    type 'a t

    val push_request_and_wait : 'q t -> 'a Request.t -> 'a tzresult Lwt.t

    val push_request : 'q t -> 'a Request.t -> unit Lwt.t

    val pending_requests : 'a t -> (Time.System.t * Request.view) list

    val pending_requests_length : 'a t -> int
  end

  module type BOUNDED_QUEUE = sig
    type t

    val try_push_request_now : t -> 'a Request.t -> bool
  end

  module Dropbox = struct
    let put_request (w : dropbox t) request =
      let (Dropbox {merge}) = w.table.buffer_kind in
      let (Dropbox_buffer message_box) = w.buffer in
      drop_request w merge message_box request

    let put_request_and_wait (w : dropbox t) request =
      let (Dropbox_buffer message_box) = w.buffer in
      drop_request_and_wait w message_box request
  end

  module Queue = struct
    let push_request (type a) (w : a queue t) request =
      match w.buffer with
      | Queue_buffer message_queue ->
          Lwt_pipe.push message_queue (queue_item request)
      | Bounded_buffer message_queue ->
          Lwt_pipe.push message_queue (queue_item request)

    let push_request_now (w : infinite queue t) request =
      let (Queue_buffer message_queue) = w.buffer in
      if Lwt_pipe.is_closed message_queue then ()
      else
        (* Queues are infinite so the push always succeeds *)
        assert (Lwt_pipe.push_now message_queue (queue_item request))

    let try_push_request_now (w : bounded queue t) request =
      let (Bounded_buffer message_queue) = w.buffer in
      Lwt_pipe.push_now message_queue (queue_item request)

    let push_request_and_wait (type a) (w : a queue t) request =
      let message_queue =
        match w.buffer with
        | Queue_buffer message_queue ->
            message_queue
        | Bounded_buffer message_queue ->
            message_queue
      in
      push_request_and_wait w message_queue request

    let pending_requests (type a) (w : a queue t) =
      let message_queue =
        match w.buffer with
        | Queue_buffer message_queue ->
            message_queue
        | Bounded_buffer message_queue ->
            message_queue
      in
      List.map
        (function (t, Message (req, _)) -> (t, Request.view req))
        (Lwt_pipe.peek_all message_queue)

    let pending_requests_length (type a) (w : a queue t) =
      let pipe_length (type a) (q : a buffer) =
        match q with
        | Queue_buffer queue ->
            Lwt_pipe.length queue
        | Bounded_buffer queue ->
            Lwt_pipe.length queue
        | Dropbox_buffer _ ->
            1
      in
      pipe_length w.buffer
  end

  let close (type a) (w : a t) =
    let wakeup = function
      | (_, Message (_, Some u)) ->
          let name = Format.asprintf "%a" Name.pp w.name in
          Lwt.wakeup_later u (error (Closed {base = base_name; name}))
      | (_, Message (_, None)) ->
          ()
    in
    let close_queue message_queue =
      let messages = Lwt_pipe.pop_all_now message_queue in
      List.iter wakeup messages ;
      Lwt_pipe.close message_queue
    in
    match w.buffer with
    | Queue_buffer message_queue ->
        close_queue message_queue
    | Bounded_buffer message_queue ->
        close_queue message_queue
    | Dropbox_buffer message_box ->
        ( try Option.iter wakeup (Lwt_dropbox.peek message_box)
          with Lwt_dropbox.Closed -> () ) ;
        Lwt_dropbox.close message_box

  let pop (type a) (w : a t) =
    let pop_queue message_queue =
      match w.timeout with
      | None ->
          Lwt_pipe.pop message_queue >>= fun m -> return_some m
      | Some timeout ->
          Lwt_pipe.pop_with_timeout (Systime_os.sleep timeout) message_queue
          >>= fun m -> return m
    in
    match w.buffer with
    | Queue_buffer message_queue ->
        pop_queue message_queue
    | Bounded_buffer message_queue ->
        pop_queue message_queue
    | Dropbox_buffer message_box -> (
      match w.timeout with
      | None ->
          Lwt_dropbox.take message_box >>= fun m -> return_some m
      | Some timeout ->
          Lwt_dropbox.take_with_timeout (Systime_os.sleep timeout) message_box
          >>= fun m -> return m )

  let trigger_shutdown w = Lwt.ignore_result (Lwt_canceler.cancel w.canceler)

  let canceler {canceler; _} = canceler

  let lwt_emit w (status : Logger.status) =
    let (module LogEvent) = w.logEvent in
    let time = Systime_os.now () in
    LogEvent.emit
      ~section:(Internal_event.Section.make_sanitized Name.base)
      (fun () -> Time.System.stamp ~time status)
    >>= function
    | Ok () ->
        Lwt.return_unit
    | Error el ->
        Format.kasprintf
          Lwt.fail_with
          "Worker_event.emit: %a"
          pp_print_error
          el

  let log_event w evt =
    lwt_emit w (Logger.WorkerEvent (evt, Event.level evt))
    >>= fun () ->
    if Event.level evt >= w.limits.backlog_level then
      Ringo.Ring.add (List.assoc (Event.level evt) w.event_log) evt ;
    Lwt.return_unit

  let record_event w evt = Lwt.ignore_result (log_event w evt)

  module type HANDLERS = sig
    type self

    val on_launch :
      self -> Name.t -> Types.parameters -> Types.state tzresult Lwt.t

    val on_request : self -> 'a Request.t -> 'a tzresult Lwt.t

    val on_no_request : self -> unit tzresult Lwt.t

    val on_close : self -> unit Lwt.t

    val on_error :
      self ->
      Request.view ->
      Worker_types.request_status ->
      error list ->
      unit tzresult Lwt.t

    val on_completion :
      self -> 'a Request.t -> 'a -> Worker_types.request_status -> unit Lwt.t
  end

  let create_table buffer_kind =
    {buffer_kind; last_id = 0; instances = Nametbl.create ~random:true 10}

  let worker_loop (type kind) handlers (w : kind t) =
    let (module Handlers : HANDLERS with type self = kind t) = handlers in
    let do_close errs =
      let t0 =
        match w.status with
        | Running t0 ->
            t0
        | Launching _ | Closing _ | Closed _ ->
            assert false
      in
      w.status <- Closing (t0, Systime_os.now ()) ;
      close w ;
      Lwt_canceler.cancel w.canceler
      >>= fun () ->
      w.status <- Closed (t0, Systime_os.now (), errs) ;
      Handlers.on_close w
      >>= fun () ->
      Nametbl.remove w.table.instances w.name ;
      w.state <- None ;
      Lwt.ignore_result
        ( List.iter (fun (_, ring) -> Ringo.Ring.clear ring) w.event_log ;
          Lwt.return_unit ) ;
      Lwt.return_unit
    in
    let rec loop () =
      (* The call to [protect] here allows the call to [pop] (responsible
         for fetching the next request) to be canceled by the use of the
         [canceler].

         These cancellations cannot affect the processing of ongoing requests.
         This is due to the limited scope of the argument of [protect]. As a
         result, ongoing requests are never canceled by this mechanism.

         In the case when the [canceler] is canceled whilst a request is being
         processed, the processing eventually resolves, at which point a
         recursive call to this [loop] at which point this call to [protect]
         fails immediately with [Canceled]. *)
      protect ~canceler:w.canceler (fun () -> pop w)
      >>=? (function
             | None ->
                 Handlers.on_no_request w
             | Some (pushed, Message (request, u)) -> (
                 let current_request = Request.view request in
                 let treated_time = Systime_os.now () in
                 w.current_request <-
                   Some (pushed, treated_time, current_request) ;
                 match u with
                 | None ->
                     Handlers.on_request w request
                     >>=? fun res ->
                     let completed_time = Systime_os.now () in
                     let treated = Ptime.diff treated_time pushed in
                     let completed = Ptime.diff completed_time treated_time in
                     w.current_request <- None ;
                     let status = Worker_types.{pushed; treated; completed} in
                     Handlers.on_completion w request res status
                     >>= fun () ->
                     lwt_emit w (Request (current_request, status, None))
                     >>= fun () -> return_unit
                 | Some u ->
                     Handlers.on_request w request
                     >>= fun res ->
                     Lwt.wakeup_later u res ;
                     Lwt.return res
                     >>=? fun res ->
                     let completed_time = Systime_os.now () in
                     let treated = Ptime.diff treated_time pushed in
                     let completed = Ptime.diff completed_time treated_time in
                     let status = Worker_types.{pushed; treated; completed} in
                     w.current_request <- None ;
                     Handlers.on_completion w request res status
                     >>= fun () ->
                     lwt_emit w (Request (current_request, status, None))
                     >>= fun () -> return_unit ))
      >>= function
      | Ok () ->
          loop ()
      | Error (Canceled :: _)
      | Error (Exn Lwt.Canceled :: _)
      | Error (Exn Lwt_pipe.Closed :: _)
      | Error (Exn Lwt_dropbox.Closed :: _) ->
          lwt_emit w Terminated >>= fun () -> do_close None
      | Error errs -> (
          ( match w.current_request with
          | Some (pushed, treated_time, request) ->
              let completed_time = Systime_os.now () in
              let treated = Ptime.diff treated_time pushed in
              let completed = Ptime.diff completed_time treated_time in
              w.current_request <- None ;
              Handlers.on_error
                w
                request
                Worker_types.{pushed; treated; completed}
                errs
          | None ->
              assert false )
          >>= function
          | Ok () ->
              loop ()
          | Error (Timeout :: _ as errs) ->
              lwt_emit w Terminated >>= fun () -> do_close (Some errs)
          | Error errs ->
              lwt_emit w (Crashed errs) >>= fun () -> do_close (Some errs) )
    in
    loop ()

  let launch :
      type kind.
      kind table ->
      ?timeout:Time.System.Span.t ->
      Worker_types.limits ->
      Name.t ->
      Types.parameters ->
      (module HANDLERS with type self = kind t) ->
      kind t tzresult Lwt.t =
   fun table ?timeout limits name parameters (module Handlers) ->
    let name_s = Format.asprintf "%a" Name.pp name in
    let full_name =
      if name_s = "" then base_name
      else Format.asprintf "%s_%s" base_name name_s
    in
    if Nametbl.mem table.instances name then
      invalid_arg
        (Format.asprintf "Worker.launch: duplicate worker %s" full_name)
    else
      let id =
        table.last_id <- table.last_id + 1 ;
        table.last_id
      in
      let id_name =
        if name_s = "" then base_name else Format.asprintf "%s_%d" base_name id
      in
      let canceler = Lwt_canceler.create () in
      let buffer : kind buffer =
        match table.buffer_kind with
        | Queue ->
            Queue_buffer (Lwt_pipe.create ())
        | Bounded {size} ->
            Bounded_buffer (Lwt_pipe.create ~size:(size, fun _ -> 1) ())
        | Dropbox _ ->
            Dropbox_buffer (Lwt_dropbox.create ())
      in
      let event_log =
        let levels =
          Internal_event.[Debug; Info; Notice; Warning; Error; Fatal]
        in
        List.map (fun l -> (l, Ringo.Ring.create limits.backlog_size)) levels
      in
      let w =
        {
          limits;
          parameters;
          name;
          canceler;
          table;
          buffer;
          state = None;
          id;
          worker = Lwt.return_unit;
          event_log;
          timeout;
          current_request = None;
          logEvent = (module Logger.LogEvent);
          status = Launching (Systime_os.now ());
        }
      in
      Nametbl.add table.instances name w ;
      ( if id_name = base_name then lwt_emit w (Started None)
      else lwt_emit w (Started (Some name_s)) )
      >>= fun () ->
      Handlers.on_launch w name parameters
      >>=? fun state ->
      w.status <- Running (Systime_os.now ()) ;
      w.state <- Some state ;
      w.worker <-
        Lwt_utils.worker
          full_name
          ~on_event:Internal_event.Lwt_worker_event.on_event
          ~run:(fun () -> worker_loop (module Handlers) w)
          ~cancel:(fun () -> Lwt_canceler.cancel w.canceler) ;
      return w

  let shutdown w =
    (* The actual cancellation ([Lwt_canceler.cancel w.canceler]) resolves
       immediately because no hooks are registered on the canceler. However, the
       worker ([w.worker]) resolves only once the ongoing request has resolved
       (if any) and some clean-up operations have completed. *)
    lwt_emit w Triggering_shutdown
    >>= fun () -> Lwt_canceler.cancel w.canceler >>= fun () -> w.worker

  let state w =
    match (w.state, w.status) with
    | (None, Launching _) ->
        invalid_arg
          (Format.asprintf
             "Worker.state (%s[%a]): state called before worker was initialized"
             base_name
             Name.pp
             w.name)
    | (None, (Closing _ | Closed _)) ->
        invalid_arg
          (Format.asprintf
             "Worker.state (%s[%a]): state called after worker was terminated"
             base_name
             Name.pp
             w.name)
    | (None, _) ->
        assert false
    | (Some state, _) ->
        state

  let pending_requests q = Queue.pending_requests q

  let last_events w =
    List.map
      (fun (level, ring) -> (level, Ringo.Ring.elements ring))
      w.event_log

  let status {status; _} = status

  let current_request {current_request; _} = current_request

  let information (type a) (w : a t) =
    {
      Worker_types.instances_number = Nametbl.length w.table.instances;
      wstatus = w.status;
      queue_length =
        ( match w.buffer with
        | Queue_buffer pipe ->
            Lwt_pipe.length pipe
        | Bounded_buffer pipe ->
            Lwt_pipe.length pipe
        | Dropbox_buffer _ ->
            1 );
    }

  let view w = Types.view (state w) w.parameters

  let list {instances; _} =
    Nametbl.fold (fun n w acc -> (n, w) :: acc) instances []

  let find_opt {instances; _} = Nametbl.find instances

  (* TODO? add a list of cancelers for nested protection ? *)
  let protect {canceler; _} ?on_error f = protect ?on_error ~canceler f

  let () =
    Internal_event.register_section
      (Internal_event.Section.make_sanitized Name.base)
end
