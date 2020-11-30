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

module type REQUESTER = sig
  type t

  type key

  type value

  type param

  val known : t -> key -> bool Lwt.t

  type error += Missing_data of key

  type error += Canceled of key

  type error += Timeout of key

  val read : t -> key -> value tzresult Lwt.t

  val read_opt : t -> key -> value option Lwt.t

  val fetch :
    t ->
    ?peer:P2p_peer.Id.t ->
    ?timeout:Time.System.Span.t ->
    key ->
    param ->
    value tzresult Lwt.t

  val clear_or_cancel : t -> key -> unit
end

module type FULL_REQUESTER = sig
  include REQUESTER

  type store

  type request_param

  type notified_value

  val pending : t -> key -> bool

  val watch : t -> (key * value) Lwt_stream.t * Lwt_watcher.stopper

  val inject : t -> key -> value -> bool Lwt.t

  val notify : t -> P2p_peer.Id.t -> key -> notified_value -> unit Lwt.t

  val memory_table_length : t -> int

  val pending_requests : t -> int

  val create :
    ?random_table:bool ->
    ?global_input:(key * value) Lwt_watcher.input ->
    request_param ->
    store ->
    t

  val shutdown : t -> unit Lwt.t
end

module type DISK_TABLE = sig
  type store

  type key

  type value

  val known : store -> key -> bool Lwt.t

  val read : store -> key -> value tzresult Lwt.t

  val read_opt : store -> key -> value option Lwt.t
end

module type MEMORY_TABLE = sig
  type 'a t

  type key

  val create : ?random:bool -> int -> 'a t

  val find : 'a t -> key -> 'a option

  val add : 'a t -> key -> 'a -> unit

  val replace : 'a t -> key -> 'a -> unit

  val remove : 'a t -> key -> unit

  val fold : (key -> 'a -> 'b -> 'b) -> 'a t -> 'b -> 'b

  val length : 'a t -> int
end

module type SCHEDULER = sig
  type t

  type key

  type param

  val request : t -> P2p_peer.Id.t option -> key -> unit

  val notify : t -> P2p_peer.Id.t -> key -> unit Lwt.t

  val notify_cancellation : t -> key -> unit

  val notify_unrequested : t -> P2p_peer.Id.t -> key -> unit Lwt.t

  val notify_duplicate : t -> P2p_peer.Id.t -> key -> unit Lwt.t

  val notify_invalid : t -> P2p_peer.Id.t -> key -> unit Lwt.t

  val pending_requests : t -> int

  val create : param -> t

  val shutdown : t -> unit Lwt.t
end

module type PRECHECK = sig
  type key

  type param

  type notified_value

  type value

  val precheck : key -> param -> notified_value -> value option
end

module type REQUEST = sig
  type key

  type param

  val initial_delay : Time.System.Span.t

  val active : param -> P2p_peer.Set.t

  val send : param -> P2p_peer.Id.t -> key list -> unit
end

(** The requester uses a generic scheduler to schedule its requests.
    The [Memory_table] must be shared between the scheduler and the requester
    as it used to store both pending requests and found values. *)

module Make_request_scheduler (Hash : sig
  type t

  val name : string

  val encoding : t Data_encoding.t
end)
(Table : MEMORY_TABLE with type key := Hash.t)
(Request : REQUEST with type key := Hash.t) : sig
  include SCHEDULER with type key := Hash.t and type param := Request.param
end = struct
  module Events = Requester_event.Make (Hash)

  type key = Hash.t

  type t = {
    param : Request.param;
    pending : status Table.t;
    queue : event Lwt_pipe.t;
    mutable events : event list Lwt.t;
    canceler : Lwt_canceler.t;
    mutable worker : unit Lwt.t;
  }

  and status = {
    peers : P2p_peer.Set.t;
    next_request : Time.System.t;
    delay : Time.System.Span.t;
  }

  and event =
    | Request of P2p_peer.Id.t option * key
    | Notify of P2p_peer.Id.t * key
    | Notify_cancellation of key
    | Notify_invalid of P2p_peer.Id.t * key
    | Notify_duplicate of P2p_peer.Id.t * key
    | Notify_unrequested of P2p_peer.Id.t * key

  let request t p k = assert (Lwt_pipe.push_now t.queue (Request (p, k)))

  let notify t p k =
    Events.(emit notify_push) (k, p)
    >>= fun () ->
    assert (Lwt_pipe.push_now t.queue (Notify (p, k))) ;
    Lwt.return ()

  (* [notify_cancellation] is used within non-Lwt context and needs to
     perform logging without yielding. We use
     [emit__dont_wait__use_with_care] to that end. Other events are used
     within Lwt context so we use the recommended [emit] for them. *)
  let notify_cancellation t k =
    Events.(emit__dont_wait__use_with_care notify_push_cancellation) k ;
    assert (Lwt_pipe.push_now t.queue (Notify_cancellation k))

  let notify_invalid t p k =
    Events.(emit notify_push_invalid) (k, p)
    >>= fun () ->
    assert (Lwt_pipe.push_now t.queue (Notify_invalid (p, k))) ;
    Lwt.return ()

  let notify_duplicate t p k =
    Events.(emit notify_push_duplicate) (k, p)
    >>= fun () ->
    assert (Lwt_pipe.push_now t.queue (Notify_duplicate (p, k))) ;
    Lwt.return ()

  let notify_unrequested t p k =
    Events.(emit notify_push_unrequested) (k, p)
    >>= fun () ->
    assert (Lwt_pipe.push_now t.queue (Notify_unrequested (p, k))) ;
    Lwt.return ()

  let compute_timeout state =
    let next =
      Table.fold
        (fun _ {next_request; _} acc ->
          match acc with
          | None ->
              Some next_request
          | Some x ->
              Some (Time.System.min x next_request))
        state.pending
        None
    in
    match next with
    | None ->
        fst @@ Lwt.task ()
    | Some next ->
        let now = Systime_os.now () in
        let delay = Ptime.diff next now in
        if Ptime.Span.compare delay Ptime.Span.zero <= 0 then Lwt.return_unit
        else Systime_os.sleep delay

  let process_event state now = function
    | Request (peer, key) -> (
        Events.(emit registering_request) (key, peer)
        >>= fun () ->
        match Table.find state.pending key with
        | Some data ->
            let peers =
              match peer with
              | None ->
                  data.peers
              | Some peer ->
                  P2p_peer.Set.add peer data.peers
            in
            Table.replace
              state.pending
              key
              {peers; next_request = now; delay = Request.initial_delay} ;
            Events.(emit registering_request_replaced) (key, peer)
        | None ->
            let peers =
              match peer with
              | None ->
                  P2p_peer.Set.empty
              | Some peer ->
                  P2p_peer.Set.singleton peer
            in
            Table.add
              state.pending
              key
              {peers; next_request = now; delay = Request.initial_delay} ;
            Events.(emit registering_request_added) (key, peer) )
    | Notify (peer, key) ->
        Table.remove state.pending key ;
        Events.(emit notify_received) (key, peer)
    | Notify_cancellation key ->
        Table.remove state.pending key ;
        Events.(emit notify_cancelled) key
    | Notify_invalid (peer, key) ->
        (* TODO: Punish peer *)
        Events.(emit notify_invalid) (key, peer)
    | Notify_unrequested (peer, key) ->
        (* TODO: Punish peer *)
        Events.(emit notify_unrequested) (key, peer)
    | Notify_duplicate (peer, key) ->
        (* TODO: Punish peer *)
        Events.(emit notify_duplicate) (key, peer)

  let worker_loop state =
    let shutdown = Lwt_canceler.cancellation state.canceler in
    let rec loop state =
      let timeout = compute_timeout state in
      Lwt.choose [(state.events >|= fun _ -> ()); timeout; shutdown]
      >>= fun () ->
      if Lwt.state shutdown <> Lwt.Sleep then Events.(emit terminated) ()
      else if Lwt.state state.events <> Lwt.Sleep then (
        let now = Systime_os.now () in
        state.events
        >>= fun events ->
        state.events <- Lwt_pipe.pop_all state.queue ;
        Lwt_list.iter_s (process_event state now) events
        >>= fun () -> loop state )
      else
        Events.(emit timeout) ()
        >>= fun () ->
        let now = Systime_os.now () in
        let active_peers = Request.active state.param in
        let requests =
          Table.fold
            (fun key {peers; next_request; delay} acc ->
              if Ptime.is_later next_request ~than:now then acc
              else
                let remaining_peers = P2p_peer.Set.inter peers active_peers in
                if
                  P2p_peer.Set.is_empty remaining_peers
                  && not (P2p_peer.Set.is_empty peers)
                then (
                  Table.remove state.pending key ;
                  acc )
                else
                  let requested_peer =
                    P2p_peer.Id.Set.random_elt
                      ( if P2p_peer.Set.is_empty remaining_peers then
                        active_peers
                      else remaining_peers )
                  in
                  let next_request =
                    Option.value ~default:Ptime.max (Ptime.add_span now delay)
                  in
                  let next =
                    {
                      peers = remaining_peers;
                      next_request;
                      delay = Time.System.Span.multiply_exn 1.5 delay;
                    }
                  in
                  Table.replace state.pending key next ;
                  let requests =
                    key
                    :: Option.value
                         ~default:[]
                         (P2p_peer.Map.find requested_peer acc)
                  in
                  P2p_peer.Map.add requested_peer requests acc)
            state.pending
            P2p_peer.Map.empty
        in
        P2p_peer.Map.iter (Request.send state.param) requests ;
        P2p_peer.Map.iter_s
          (fun peer request ->
            Lwt_list.iter_s
              (fun (key : key) -> Events.(emit requested) (key, peer))
              request)
          requests
        >>= fun () -> loop state
    in
    loop state

  let create param =
    let state =
      {
        param;
        queue = Lwt_pipe.create ();
        pending = Table.create ~random:true 17;
        events = Lwt.return_nil;
        canceler = Lwt_canceler.create ();
        worker = Lwt.return_unit;
      }
    in
    state.worker <-
      Lwt_utils.worker
        "db_request_scheduler"
        ~on_event:Internal_event.Lwt_worker_event.on_event
        ~run:(fun () -> worker_loop state)
        ~cancel:(fun () -> Lwt_canceler.cancel state.canceler) ;
    state

  let shutdown s = Lwt_canceler.cancel s.canceler >>= fun () -> s.worker

  let pending_requests s = Table.length s.pending
end

module Make (Hash : sig
  type t

  val name : string

  val encoding : t Data_encoding.t

  val pp : Format.formatter -> t -> unit
end)
(Disk_table : DISK_TABLE with type key := Hash.t)
(Memory_table : MEMORY_TABLE with type key := Hash.t)
(Request : REQUEST with type key := Hash.t)
(Precheck : PRECHECK with type key := Hash.t and type value := Disk_table.value) : sig
  include
    FULL_REQUESTER
      with type key = Hash.t
       and type value = Disk_table.value
       and type param = Precheck.param
       and type request_param = Request.param
       and type notified_value = Precheck.notified_value
       and type store = Disk_table.store
end = struct
  type key = Hash.t

  type value = Disk_table.value

  type param = Precheck.param

  type request_param = Request.param

  type notified_value = Precheck.notified_value

  type store = Disk_table.store

  module Scheduler = Make_request_scheduler (Hash) (Memory_table) (Request)

  type t = {
    scheduler : Scheduler.t;
    disk : Disk_table.store;
    memory : status Memory_table.t;
    global_input : (key * value) Lwt_watcher.input option;
    input : (key * value) Lwt_watcher.input;
  }

  and status =
    | Pending of {
        waiter : value tzresult Lwt.t;
        wakener : value tzresult Lwt.u;
        mutable waiters : int;
        param : param;
      }
    | Found of value

  let known s k =
    match Memory_table.find s.memory k with
    | None ->
        Disk_table.known s.disk k
    | Some (Pending _) ->
        Lwt.return_false
    | Some (Found _) ->
        Lwt.return_true

  let read_opt s k =
    match Memory_table.find s.memory k with
    | None ->
        Disk_table.read_opt s.disk k
    | Some (Found v) ->
        Lwt.return_some v
    | Some (Pending _) ->
        Lwt.return_none

  type error += Missing_data of key

  type error += Canceled of key

  type error += Timeout of key

  let () =
    (* Missing data key *)
    register_error_kind
      `Permanent
      ~id:("requester." ^ Hash.name ^ ".missing")
      ~title:("Missing " ^ Hash.name)
      ~description:("Some " ^ Hash.name ^ " is missing from the requester")
      ~pp:(fun ppf key ->
        Format.fprintf ppf "Missing %s %a" Hash.name Hash.pp key)
      (Data_encoding.obj1 (Data_encoding.req "key" Hash.encoding))
      (function Missing_data key -> Some key | _ -> None)
      (fun key -> Missing_data key) ;
    (* Canceled key *)
    register_error_kind
      `Permanent
      ~title:("Canceled fetch of a " ^ Hash.name)
      ~description:("The fetch of a " ^ Hash.name ^ " has been canceled")
      ~id:("requester." ^ Hash.name ^ ".fetch_canceled")
      ~pp:(fun ppf key ->
        Format.fprintf ppf "Fetch of %s %a canceled" Hash.name Hash.pp key)
      Data_encoding.(obj1 (req "key" Hash.encoding))
      (function Canceled key -> Some key | _ -> None)
      (fun key -> Canceled key) ;
    (* Timeout key *)
    register_error_kind
      `Permanent
      ~title:("Timed out fetch of a " ^ Hash.name)
      ~description:("The fetch of a " ^ Hash.name ^ " has timed out")
      ~id:("requester." ^ Hash.name ^ ".fetch_timeout")
      ~pp:(fun ppf key ->
        Format.fprintf ppf "Fetch of %s %a timed out" Hash.name Hash.pp key)
      Data_encoding.(obj1 (req "key" Hash.encoding))
      (function Timeout key -> Some key | _ -> None)
      (fun key -> Timeout key)

  let read s k =
    match Memory_table.find s.memory k with
    | None ->
        trace (Missing_data k) @@ Disk_table.read s.disk k
    | Some (Found v) ->
        return v
    | Some (Pending _) ->
        fail (Missing_data k)

  let wrap s k ?timeout t =
    let t = Lwt.protected t in
    Lwt.on_cancel t (fun () ->
        match Memory_table.find s.memory k with
        | None ->
            ()
        | Some (Found _) ->
            ()
        | Some (Pending ({wakener = w; _} as data)) ->
            data.waiters <- data.waiters - 1 ;
            if data.waiters = 0 then (
              Memory_table.remove s.memory k ;
              Scheduler.notify_cancellation s.scheduler k ;
              Lwt.wakeup_later w (error (Canceled k)) )) ;
    match timeout with
    | None ->
        t
    | Some delay ->
        let timeout = Systime_os.sleep delay >>= fun () -> fail (Timeout k) in
        Lwt.pick [t; timeout]

  let fetch s ?peer ?timeout k param =
    match Memory_table.find s.memory k with
    | None -> (
        Disk_table.read_opt s.disk k
        >>= function
        | Some v ->
            return v
        | None -> (
          (* It is necessary to check the memory-table again in case another
            promise has altered it whilst this one was waiting for the
            disk-table query. *)
          match Memory_table.find s.memory k with
          | None ->
              let (waiter, wakener) = Lwt.wait () in
              Memory_table.add
                s.memory
                k
                (Pending {waiter; wakener; waiters = 1; param}) ;
              Scheduler.request s.scheduler peer k ;
              wrap s k ?timeout waiter
          | Some (Pending data) ->
              Scheduler.request s.scheduler peer k ;
              data.waiters <- data.waiters + 1 ;
              wrap s k ?timeout data.waiter
          | Some (Found v) ->
              return v ) )
    | Some (Pending data) ->
        Scheduler.request s.scheduler peer k ;
        data.waiters <- data.waiters + 1 ;
        wrap s k ?timeout data.waiter
    | Some (Found v) ->
        return v

  let notify_when_pending s p k w param v =
    match Precheck.precheck k param v with
    | None ->
        Scheduler.notify_invalid s.scheduler p k
    | Some v ->
        Scheduler.notify s.scheduler p k
        >>= fun () ->
        Memory_table.replace s.memory k (Found v) ;
        Lwt.wakeup_later w (Ok v) ;
        Option.iter
          (fun input -> Lwt_watcher.notify input (k, v))
          s.global_input ;
        Lwt_watcher.notify s.input (k, v) ;
        Lwt.return_unit

  let notify s p k v =
    match Memory_table.find s.memory k with
    | None -> (
        Disk_table.known s.disk k
        >>= function
        | true ->
            Scheduler.notify_duplicate s.scheduler p k
        | false -> (
          (* It is necessary to check the memory-table again in case another
            promise has altered it whilst this one was waiting for the
            disk-table query. *)
          match Memory_table.find s.memory k with
          | None ->
              Scheduler.notify_unrequested s.scheduler p k
          | Some (Pending {wakener = w; param; _}) ->
              notify_when_pending s p k w param v
          | Some (Found _) ->
              Scheduler.notify_duplicate s.scheduler p k ) )
    | Some (Pending {wakener = w; param; _}) ->
        notify_when_pending s p k w param v
    | Some (Found _) ->
        Scheduler.notify_duplicate s.scheduler p k

  let inject s k v =
    match Memory_table.find s.memory k with
    | None -> (
        Disk_table.known s.disk k
        >>= function
        | true ->
            Lwt.return_false
        | false -> (
          (* It is necessary to check the memory-table again in case another
            promise has altered it whilst this one was waiting for the
            disk-table query. *)
          match Memory_table.find s.memory k with
          | None ->
              Memory_table.add s.memory k (Found v) ;
              Lwt.return_true
          | Some (Pending _) | Some (Found _) ->
              Lwt.return_false ) )
    | Some (Pending _) | Some (Found _) ->
        Lwt.return_false

  let clear_or_cancel s k =
    match Memory_table.find s.memory k with
    | None ->
        ()
    | Some (Pending {wakener = w; _}) ->
        Scheduler.notify_cancellation s.scheduler k ;
        Memory_table.remove s.memory k ;
        Lwt.wakeup_later w (error (Canceled k))
    | Some (Found _) ->
        Memory_table.remove s.memory k

  let watch s = Lwt_watcher.create_stream s.input

  let create ?random_table:random ?global_input request_param disk =
    let scheduler = Scheduler.create request_param in
    let memory = Memory_table.create ?random 17 in
    let input = Lwt_watcher.create_input () in
    {scheduler; disk; memory; input; global_input}

  let pending s k =
    match Memory_table.find s.memory k with
    | None ->
        false
    | Some (Found _) ->
        false
    | Some (Pending _) ->
        true

  let memory_table_length s = Memory_table.length s.memory

  let pending_requests s = Scheduler.pending_requests s.scheduler

  let shutdown s = Scheduler.shutdown s.scheduler
end
