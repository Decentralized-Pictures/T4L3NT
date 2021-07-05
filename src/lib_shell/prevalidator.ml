(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018-2021 Nomadic Labs, <contact@nomadic-labs.com>          *)
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

open Prevalidator_worker_state

type limits = {
  max_refused_operations : int;
  operation_timeout : Time.System.Span.t;
  worker_limits : Worker_types.limits;
  operations_batch_size : int;
}

(* Minimal delay between two mempool advertisements except for
   endorsements for which the branch is unknown. *)
let advertisement_delay = 0.1

module Name = struct
  type t = Chain_id.t * Protocol_hash.t

  let encoding = Data_encoding.tup2 Chain_id.encoding Protocol_hash.encoding

  let base = ["prevalidator"]

  let pp fmt (chain_id, proto_hash) =
    Format.fprintf
      fmt
      "%a:%a"
      Chain_id.pp_short
      chain_id
      Protocol_hash.pp_short
      proto_hash

  let equal (c1, p1) (c2, p2) =
    Chain_id.equal c1 c2 && Protocol_hash.equal p1 p2
end

module Logger =
  Worker_logger.Make (Event) (Request)
    (struct
      let worker_name = "node_prevalidator"
    end)

type parameters = {limits : limits; chain_db : Distributed_db.chain_db}

(* This type is used to represent a finite set of operations. *)
type 'a bounded_map = {
  ring : Operation_hash.t Ringo.Ring.t;
  mutable map : (Operation.t * error list) Operation_hash.Map.t;
}

module type T = sig
  module Proto : Registered_protocol.T

  module Filter : Prevalidator_filters.FILTER with module Proto = Proto

  val name : Name.t

  module Prevalidation : Prevalidation.T

  type types_state = {
    parameters : parameters;
    mutable predecessor : Store.Block.t;
    mutable timestamp : Time.System.t;
    mutable live_blocks : Block_hash.Set.t;
    mutable live_operations : Operation_hash.Set.t;
    refused : [`Refused] bounded_map;
    branch_refused : [`Branch_refused] bounded_map;
    branch_delayed : [`Branch_delayed] bounded_map;
    mutable fetching : Operation_hash.Set.t;
    mutable pending : Operation.t Operation_hash.Map.t;
    mutable mempool : Mempool.t;
    mutable in_mempool : Operation_hash.Set.t;
    mutable applied : (Operation_hash.t * Operation.t) list;
    mutable validation_state : Prevalidation.t tzresult;
    mutable operation_stream :
      ([`Applied | `Refused | `Branch_refused | `Branch_delayed]
      * Operation.shell_header
      * Proto.operation_data)
      Lwt_watcher.input;
    mutable advertisement : [`Pending of Mempool.t | `None];
    mutable rpc_directory : types_state RPC_directory.t lazy_t;
    mutable filter_config : Data_encoding.json Protocol_hash.Map.t;
  }

  module Types : Worker_intf.TYPES with type state = types_state

  module Worker :
    Worker.T
      with type Event.t = Event.t
       and type 'a Request.t = 'a Request.t
       and type Request.view = Request.view
       and type Types.state = types_state

  type worker = Worker.infinite Worker.queue Worker.t

  val validation_result : types_state -> error Preapply_result.t

  val fitness : unit -> Fitness.t Lwt.t

  val initialization_errors : unit tzresult Lwt.t

  val worker : worker Lazy.t
end

module type ARG = sig
  val limits : limits

  val chain_db : Distributed_db.chain_db

  val chain_id : Chain_id.t
end

type t = (module T)

(* General description of the mempool:

   The mempool manages a [validation state] based upon the current
   head chosen by the validation sub-system. Each time the mempool
   receives an operation, it tries to classify it on top of the
   current validation state. If the operation was applied
   successfully, the validation state is updated and the operation can
   be propagated. Otherwise, the handling of the operation depends on
   the error classification which is detailed below. Given an
   operation, its classification may change if the head changes. When
   the validation sub-system switches its head, it notifies the
   mempool with the new [live_blocks] and [live_operations],
   triggering also a [flush] of the mempool: Every classified
   operation which is anchored (i.e, the [block hash] on which the
   operation is based on when it was created) on a [live block] and
   which is not in the [live operations] (operations which are
   included in [live_blocks]) is set [pending], meaning they are
   waiting to be classified again.

   Error classification:

     An operation can be classified as [`Refused; `Branch_refused;
   `Branch_delayed; `Applied; `Outdated].

     - An operation is [`Refused] if the operation cannot be parsed or
   if the protocol rejects this operation with an error classified as
   [Permanent].

     - An operation is [`Branch_refused] if the operation is anchored
   on a block that has not been validated by the node but could be in
   the future or if the protocol rejects this operation with an error
   classified as [Branch].

     - An operation is [`Branch_delayed] if the initialisation of the
   validation state failed (which presumably cannot happen currently)
   or if the protocol rejects this operation with an error classified
   as [Temporary].

     - An operation is [`Applied] if the protocol applied the
   operation on the current validation state. Operations are stored in
   the reverse order of application so that adding a new [`Applied]
   operation can be done at the head of the list.

     - An operation is [`Outdated] if its branch is not in the
   [live_blocks].

   The prevalidator ensures that an operation cannot be at the same
   time in two of the following fields: [Outdated; branch_refused;
   branch_delayed; refused; applied].

   The prevalidator maintains in the [in_mempool] field a set of
   operation hashes corresponding to all the operations currently
   classified by the prevalidator.

   Operations are identified uniquely by their hash. Given an
   operation hash, the status can be either: [`Fetching; `Pending;
   `Classified].

     - An operation is [`Fetching] if we only know its hash but we did
   not receive yet the corresponding operation.

     - An operation is [`Pending] if we know its hash and the
   corresponding operation but this operation is not classified yet.

     - An operation is [`Classified] if we know its hash, the
   corresponding operation and was classified according to the
   classification given above.

     The prevalidator ensures that an operation cannot be at the same
   time in two of the following fields: [fetching; pending;
   in_mempool].

   Propagation of operations:

   An operation is propagated through the [distributed database]
   component (aka [ddb]) which interacts directly with the [p2p]
   network. The prevalidator advertises its mempool (containing only
   operation hashes) through the [ddb]. If a remote peer requests an
   operation, such request will be handled directly by the [ddb]
   without going to the prevalidator. This is why every operation that
   is propagated by the prevalidator should also be in the [ddb]. But
   more important, an operation which we do not want to advertise
   should be removed explicitly from the [ddb] via the
   [Distributed_db.Operation.clear_or_cancel] function.

   It is important that everytime an operation is removed from our
   mempool (the [in_mempool] field), this operation is also cleaned up
   from the [Distributed_db]. This is also true for all the operations
   which were rejected before getting to the [in_mempool] field (for
   example if they have been filtered out).

     The [mempool] field contains only operations which are in the
   [in_mempool] field and that we accept to propagate. In particular,
   we do not propagate operations classified as [`Refused].

     There are two ways to propagate our mempool:

     - Either when we classify operations

     - Either when a peer requests explicitly our mempool

     In the first case, only the newly classified operations are
   propagated. In the second case, current applied operations and
   pending operations are sent to the peer.  Everytime an operation is
   removed from the [in_mempool] field, this operation should be
   cleaned up in the [Distributed_db.Operation] requester.

   There is an [advertisement_delay] to postpone the next mempool
   advertisement if we advertised our mempool not long ago.

     To ensure that [consensus operations] (aka [endorsements]) are
   propagated quickly, we classify [consensus_operation] for which
   their branch is unknown (this may happen if the validation of a
   block takes some time). In that case, we propagate the endorsement
   if it is classified as [`Applied] or [`Branch_delayed]. This is
   simply because the [consensus_operation] may not be valid on the
   current block, but will be once we validate its branch.

     Operations are unclassified everytime there is a [flush], meaning
   the node changed its current head and every classified operation
   which are still live, i.e. anchored on a [live_block] becomes
   [`Pending] again. Classified operations which are not anchored on a
   [live_block] are simply dropped.

     Everytime an operation is classified (except for [`Outdated]),
   this operation is recorded into the [operation_stream]. Such stream
   can be used by an external service to get the classification of an
   operation (such as a baker). This also means an operation can be
   notified several times if it is classified again after a
   [flush]. *)

module Make (Filter : Prevalidator_filters.FILTER) (Arg : ARG) : T = struct
  module Filter = Filter
  module Proto = Filter.Proto

  (* [Tezos_protocol_environment.PROTOCOL] is a subtype of
     [Registered_protocol.T]. The [Prevalidation.Make] expects the
     former. However if we give [Proto] directly we will have a type
     checking error since [with type] constraints of OCaml does not
     allow subtyping. *)

  module Protocol :
    Tezos_protocol_environment.PROTOCOL
      with type operation_data = Proto.P.operation_data
       and type validation_state = Proto.P.validation_state
       and type operation_receipt = Proto.P.operation_receipt =
    Proto

  let name = (Arg.chain_id, Proto.hash)

  module Prevalidation = Prevalidation.Make (Protocol)

  type types_state = {
    parameters : parameters;
    mutable predecessor : Store.Block.t;
    mutable timestamp : Time.System.t;
    mutable live_blocks : Block_hash.Set.t;
    (* just a cache *)
    mutable live_operations : Operation_hash.Set.t;
    (* just a cache *)
    refused : [`Refused] bounded_map;
    branch_refused : [`Branch_refused] bounded_map;
    branch_delayed : [`Branch_delayed] bounded_map;
    mutable fetching : Operation_hash.Set.t;
    mutable pending : Operation.t Operation_hash.Map.t;
    mutable mempool : Mempool.t;
    mutable in_mempool : Operation_hash.Set.t;
    mutable applied : (Operation_hash.t * Operation.t) list;
    mutable validation_state : Prevalidation.t tzresult;
    mutable operation_stream :
      ([`Applied | `Refused | `Branch_refused | `Branch_delayed]
      * Operation.shell_header
      * Proto.operation_data)
      Lwt_watcher.input;
    mutable advertisement : [`Pending of Mempool.t | `None];
    mutable rpc_directory : types_state RPC_directory.t lazy_t;
    mutable filter_config : Data_encoding.json Protocol_hash.Map.t;
  }

  module Types = struct
    type state = types_state

    type parameters = limits * Distributed_db.chain_db

    include Worker_state

    let view (state : state) _ : view =
      let domain map =
        Operation_hash.Map.fold
          (fun elt _ acc -> Operation_hash.Set.add elt acc)
          map
          Operation_hash.Set.empty
      in
      {
        head = Store.Block.hash state.predecessor;
        timestamp = state.timestamp;
        fetching = state.fetching;
        pending = domain state.pending;
        applied = List.rev_map (fun (h, _) -> h) state.applied;
        delayed =
          Operation_hash.Set.union
            (domain state.branch_delayed.map)
            (domain state.branch_refused.map);
      }
  end

  module Worker :
    Worker.T
      with type Name.t = Name.t
       and type Event.t = Event.t
       and type 'a Request.t = 'a Request.t
       and type Request.view = Request.view
       and type Types.state = Types.state
       and type Types.parameters = Types.parameters =
    Worker.Make (Name) (Prevalidator_worker_state.Event)
      (Prevalidator_worker_state.Request)
      (Types)
      (Logger)

  let decode_operation_data proto_bytes =
    try
      Some
        (Data_encoding.Binary.of_bytes_exn
           Proto.operation_data_encoding
           proto_bytes)
    with _ -> None

  (** Centralised operation stream for the RPCs *)
  let notify_operation {operation_stream; _} result {Operation.shell; proto} =
    match decode_operation_data proto with
    | Some protocol_data ->
        Lwt_watcher.notify operation_stream (result, shell, protocol_data)
    | None -> ()

  open Types

  type worker = Worker.infinite Worker.queue Worker.t

  let list_pendings chain_db ~from_block ~to_block ~live_blocks old_mempool =
    let chain_store = Distributed_db.chain_store chain_db in
    let rec pop_blocks ancestor block mempool =
      let hash = Store.Block.hash block in
      if Block_hash.equal hash ancestor then Lwt.return mempool
      else
        let operations = Store.Block.operations block in
        List.fold_left_s
          (List.fold_left_s (fun mempool op ->
               let h = Operation.hash op in
               Distributed_db.inject_operation chain_db h op
               >>= fun (_ : bool) ->
               Lwt.return (Operation_hash.Map.add h op mempool)))
          mempool
          operations
        >>= fun mempool ->
        Store.Block.read_predecessor_opt chain_store block >>= function
        | None -> assert false
        | Some predecessor -> pop_blocks ancestor predecessor mempool
    in
    let push_block mempool block =
      let operations = Store.Block.all_operation_hashes block in
      List.iter
        (List.iter (Distributed_db.Operation.clear_or_cancel chain_db))
        operations ;
      List.fold_left
        (List.fold_left (fun mempool h -> Operation_hash.Map.remove h mempool))
        mempool
        operations
    in
    Store.Chain_traversal.new_blocks chain_store ~from_block ~to_block
    >>= fun (ancestor, path) ->
    pop_blocks (Store.Block.hash ancestor) from_block old_mempool
    >>= fun mempool ->
    let new_mempool = List.fold_left push_block mempool path in
    let (new_mempool, outdated) =
      Operation_hash.Map.partition
        (fun _oph op ->
          Block_hash.Set.mem op.Operation.shell.branch live_blocks)
        new_mempool
    in
    Operation_hash.Map.iter
      (fun oph _op -> Distributed_db.Operation.clear_or_cancel chain_db oph)
      outdated ;
    Lwt.return new_mempool

  let already_handled pv oph =
    Operation_hash.Map.mem oph pv.refused.map
    || Operation_hash.Map.mem oph pv.pending
    || Operation_hash.Set.mem oph pv.fetching
    || Operation_hash.Set.mem oph pv.live_operations
    || Operation_hash.Set.mem oph pv.in_mempool

  let validation_result (state : types_state) =
    {
      Preapply_result.applied = List.rev state.applied;
      branch_delayed = state.branch_delayed.map;
      branch_refused = state.branch_refused.map;
      refused = Operation_hash.Map.empty;
    }

  let advertise (w : worker) pv mempool =
    match pv.advertisement with
    | `Pending {Mempool.known_valid; pending} ->
        pv.advertisement <-
          `Pending
            {
              known_valid = known_valid @ mempool.Mempool.known_valid;
              pending = Operation_hash.Set.union pending mempool.pending;
            }
    | `None ->
        pv.advertisement <- `Pending mempool ;
        Lwt_utils.dont_wait
          (fun exc ->
            Format.eprintf "Uncaught exception: %s\n%!" (Printexc.to_string exc))
          (fun () ->
            Lwt_unix.sleep advertisement_delay >>= fun () ->
            Worker.Queue.push_request_now w Advertise ;
            Lwt.return_unit)

  let is_endorsement (op : Prevalidation.operation) =
    Proto.acceptable_passes
      {shell = op.raw.shell; protocol_data = op.protocol_data}
    = [0]

  let filter_config w pv =
    try
      match Protocol_hash.Map.find Proto.hash pv.filter_config with
      | Some config ->
          Lwt.return
            (Data_encoding.Json.destruct Filter.Mempool.config_encoding config)
      | None -> Lwt.return Filter.Mempool.default_config
    with _ ->
      Worker.log_event w Invalid_mempool_filter_configuration >>= fun () ->
      Lwt.return Filter.Mempool.default_config

  let pre_filter w pv oph op =
    match decode_operation_data op.Operation.proto with
    | None ->
        Worker.log_event w (Unparsable_operation oph) >>= fun () ->
        Lwt.return false
    | Some protocol_data ->
        let op = {Filter.Proto.shell = op.shell; protocol_data} in
        filter_config w pv >>= fun config ->
        let validation_state_before =
          Option.map
            Prevalidation.validation_state
            (Option.of_result pv.validation_state)
        in
        Lwt.return
          (Filter.Mempool.pre_filter
             ?validation_state_before
             config
             op.Filter.Proto.protocol_data)

  let post_filter w pv ~validation_state_before ~validation_state_after op
      receipt =
    filter_config w pv >>= fun config ->
    Filter.Mempool.post_filter
      config
      ~validation_state_before
      ~validation_state_after
      (op, receipt)

  let handle_branch_refused pv op oph errors =
    notify_operation pv `Branch_refused op ;
    Option.iter
      (fun e ->
        pv.branch_refused.map <-
          Operation_hash.Map.remove e pv.branch_refused.map ;
        Distributed_db.Operation.clear_or_cancel pv.parameters.chain_db oph ;
        pv.in_mempool <- Operation_hash.Set.remove e pv.in_mempool)
      (Ringo.Ring.add_and_return_erased pv.branch_refused.ring oph) ;
    pv.in_mempool <- Operation_hash.Set.add oph pv.in_mempool ;
    pv.branch_refused.map <-
      Operation_hash.Map.add oph (op, errors) pv.branch_refused.map

  let handle_branch_delayed pv op oph errors =
    notify_operation pv `Branch_delayed op ;
    Option.iter
      (fun e ->
        pv.branch_delayed.map <-
          Operation_hash.Map.remove e pv.branch_delayed.map ;
        Distributed_db.Operation.clear_or_cancel pv.parameters.chain_db oph ;
        pv.in_mempool <- Operation_hash.Set.remove e pv.in_mempool)
      (Ringo.Ring.add_and_return_erased pv.branch_delayed.ring oph) ;
    pv.in_mempool <- Operation_hash.Set.add oph pv.in_mempool ;
    pv.branch_delayed.map <-
      Operation_hash.Map.add oph (op, errors) pv.branch_delayed.map

  let handle_refused pv op oph errors =
    notify_operation pv `Refused op ;
    Option.iter
      (fun e ->
        pv.refused.map <- Operation_hash.Map.remove e pv.refused.map ;
        (* The line below is not necessary but just to be sure *)
        Distributed_db.Operation.clear_or_cancel pv.parameters.chain_db e ;
        pv.in_mempool <- Operation_hash.Set.remove e pv.in_mempool)
      (Ringo.Ring.add_and_return_erased pv.refused.ring oph) ;
    pv.refused.map <- Operation_hash.Map.add oph (op, errors) pv.refused.map ;
    Distributed_db.Operation.clear_or_cancel pv.parameters.chain_db oph ;
    pv.in_mempool <- Operation_hash.Set.add oph pv.in_mempool

  let handle_applied pv (op : Prevalidation.operation) =
    notify_operation pv `Applied op.raw ;
    pv.applied <- (op.hash, op.raw) :: pv.applied ;
    pv.in_mempool <- Operation_hash.Set.add op.hash pv.in_mempool

  let classify_operation w pv validation_state mempool op oph =
    match Prevalidation.parse op with
    | Error errors ->
        handle_refused pv op oph errors ;
        Lwt.return (validation_state, mempool)
    | Ok op -> (
        Prevalidation.apply_operation validation_state op >>= function
        | Applied (new_validation_state, receipt) ->
            post_filter
              w
              pv
              ~validation_state_before:
                (Prevalidation.validation_state validation_state)
              ~validation_state_after:
                (Prevalidation.validation_state new_validation_state)
              op.protocol_data
              receipt
            >>= fun accept ->
            if accept then (
              handle_applied pv op ;
              let new_mempool =
                Mempool.
                  {mempool with known_valid = op.hash :: mempool.known_valid}
              in
              Lwt.return (new_validation_state, new_mempool))
            else (
              Distributed_db.Operation.clear_or_cancel
                pv.parameters.chain_db
                oph ;
              Lwt.return (validation_state, mempool))
        | Branch_delayed errors ->
            handle_branch_delayed pv op.raw op.hash errors ;
            Lwt.return (validation_state, mempool)
        | Branch_refused errors ->
            handle_branch_refused pv op.raw op.hash errors ;
            Lwt.return (validation_state, mempool)
        | Refused errors ->
            handle_refused pv op.raw op.hash errors ;
            Lwt.return (validation_state, mempool)
        | Outdated ->
            Distributed_db.Operation.clear_or_cancel pv.parameters.chain_db oph ;
            Lwt.return (validation_state, mempool))

  (* Classify pending operations into either: [Refused |
     Branch_delayed | Branch_refused | Applied].  To ensure fairness
     with other worker requests, classification of operations is done
     by batch of [operation_batch_size] operations.

     This function ensures the following invariants:

     - If an operation is classified, it is not part of the [pending]
     map

     - A classified operation is part of the [in_mempool] set

     - A classified operation is part only of one of the following
     maps: [branch_refusals, branch_delays, refused, applied]

     Moreover, this function ensures that only each newly classified
     operations are advertised to the remote peers. However, if a peer
     request our mempool, we advertise all our classified operations and
     all our pending operations. *)

  let classify_pending_operations w (pv : state) state =
    Operation_hash.Map.fold_es
      (fun oph op (acc_validation_state, acc_mempool, limit) ->
        if limit <= 0 then
          (* Using Error as an early-return mechanism *)
          Lwt.return_error (acc_validation_state, acc_mempool)
        else (
          pv.pending <- Operation_hash.Map.remove oph pv.pending ;
          classify_operation w pv acc_validation_state acc_mempool op oph
          >|= fun (new_validation_state, new_mempool) ->
          ok (new_validation_state, new_mempool, limit - 1)))
      pv.pending
      (state, Mempool.empty, pv.parameters.limits.operations_batch_size)
    >>= function
    | Error (state, advertised_mempool) ->
        (* Early return after iteration limit was reached *)
        Worker.Queue.push_request w Request.Leftover >>= fun () ->
        Lwt.return (state, advertised_mempool)
    | Ok (state, advertised_mempool, _) -> Lwt.return (state, advertised_mempool)

  let handle_unprocessed w pv =
    match pv.validation_state with
    | Error err ->
        (* At the time this comment was written (26/05/21), this is dead
           code since [Proto.begin_construction] cannot fail. *)
        Operation_hash.Map.iter
          (fun oph op -> handle_branch_delayed pv op oph err)
          pv.pending ;
        pv.pending <- Operation_hash.Map.empty ;
        Lwt.return_unit
    | Ok state -> (
        match Operation_hash.Map.cardinal pv.pending with
        | 0 -> Lwt.return_unit
        | n ->
            Worker.log_event w (Processing_n_operations n) >>= fun () ->
            classify_pending_operations w pv state
            >>= fun (state, advertised_mempool) ->
            let remaining_pendings =
              Operation_hash.Map.fold
                (fun k _ acc -> Operation_hash.Set.add k acc)
                pv.pending
                Operation_hash.Set.empty
            in
            pv.validation_state <- Ok state ;
            (* We advertise only newly classified operations. *)
            let mempool_to_advertise =
              {
                advertised_mempool with
                known_valid = List.rev advertised_mempool.known_valid;
              }
            in
            advertise w pv mempool_to_advertise ;
            let our_mempool =
              {
                (* Using List.rev_map is ok since the size of pv.applied
                   cannot be too big. *)
                Mempool.known_valid = List.rev_map fst pv.applied;
                pending = remaining_pendings;
              }
            in
            pv.mempool <- our_mempool ;
            let chain_store =
              Distributed_db.chain_store pv.parameters.chain_db
            in
            Store.Chain.set_mempool
              chain_store
              ~head:(Store.Block.hash pv.predecessor)
              pv.mempool
            >>= fun _res -> Lwt_main.yield ())

  (* This function fetches operations through the [distributed_db] and
     ensures that an operation is fetched at most once by adding
     operations being fetched into [pv.fetching]. On errors, the
     operation is simply removed from this set and could be fetched
     again if it is advertised again by a peer. *)
  let fetch_operations w (pv : state) ?peer to_fetch =
    let fetch_operation w pv ?peer oph =
      Worker.log_event w (Fetching_operation oph) >>= fun () ->
      Distributed_db.Operation.fetch
        ~timeout:pv.parameters.limits.operation_timeout
        pv.parameters.chain_db
        ?peer
        oph
        ()
      >>= function
      | Ok op ->
          Worker.Queue.push_request_now w (Arrived (oph, op)) ;
          Lwt.return_unit
      | Error (Distributed_db.Operation.Canceled _ :: _) ->
          Worker.log_event w (Operation_included oph) >>= fun () ->
          Lwt.return_unit
      | Error _ ->
          (* This may happen if the peer timed out for example. *)
          Lwt.return_unit
    in
    pv.fetching <- Operation_hash.Set.union to_fetch pv.fetching ;
    Operation_hash.Set.iter
      (fun oph ->
        let p = fetch_operation w pv ?peer oph in
        (* We ensure that when the fetch is over (successfuly or not),
           we remove the operation from the [pv.fetching] set. *)
        Lwt.on_termination p (fun () ->
            pv.fetching <- Operation_hash.Set.remove oph pv.fetching))
      to_fetch

  let rpc_directory =
    lazy
      (let dir : state RPC_directory.t ref = ref RPC_directory.empty in
       let module Proto_services = Block_services.Make (Proto) (Proto) in
       dir :=
         RPC_directory.register
           !dir
           (Proto_services.S.Mempool.get_filter RPC_path.open_root)
           (fun pv () () ->
             match Protocol_hash.Map.find Proto.hash pv.filter_config with
             | Some obj -> return obj
             | None -> (
                 match Prevalidator_filters.find Proto.hash with
                 | None -> return (`O [])
                 | Some (module Filter) ->
                     let default =
                       Data_encoding.Json.construct
                         Filter.Mempool.config_encoding
                         Filter.Mempool.default_config
                     in
                     return default)) ;
       dir :=
         RPC_directory.register
           !dir
           (Proto_services.S.Mempool.set_filter RPC_path.open_root)
           (fun pv () obj ->
             pv.filter_config <-
               Protocol_hash.Map.add Proto.hash obj pv.filter_config ;
             return ()) ;
       dir :=
         RPC_directory.register
           !dir
           (Proto_services.S.Mempool.pending_operations RPC_path.open_root)
           (fun pv () () ->
             let map_op op =
               match decode_operation_data op.Operation.proto with
               | Some protocol_data ->
                   Some {Proto.shell = op.shell; protocol_data}
               | None -> None
             in
             let map_op_error oph (op, error) acc =
               match map_op op with
               | None -> acc
               | Some res -> Operation_hash.Map.add oph (res, error) acc
             in
             let applied =
               List.rev_filter_map
                 (fun (hash, op) ->
                   match map_op op with
                   | Some op -> Some (hash, op)
                   | None -> None)
                 pv.applied
             in
             let filter f map =
               Operation_hash.Map.fold f map Operation_hash.Map.empty
             in
             let refused = filter map_op_error pv.refused.map in
             let branch_refused = filter map_op_error pv.branch_refused.map in
             let branch_delayed = filter map_op_error pv.branch_delayed.map in
             let unprocessed =
               Operation_hash.Map.fold
                 (fun oph op acc ->
                   match map_op op with
                   | Some op -> Operation_hash.Map.add oph op acc
                   | None -> acc)
                 pv.pending
                 Operation_hash.Map.empty
             in
             return
               {
                 Proto_services.Mempool.applied;
                 refused;
                 branch_refused;
                 branch_delayed;
                 unprocessed;
               }) ;
       dir :=
         RPC_directory.register
           !dir
           (Proto_services.S.Mempool.request_operations RPC_path.open_root)
           (fun pv () () ->
             Distributed_db.Request.current_head pv.parameters.chain_db () ;
             return_unit) ;
       dir :=
         RPC_directory.gen_register
           !dir
           (Proto_services.S.Mempool.monitor_operations RPC_path.open_root)
           (fun
             {
               applied;
               refused;
               branch_refused;
               branch_delayed;
               operation_stream;
               _;
             }
             params
             ()
           ->
             let (op_stream, stopper) =
               Lwt_watcher.create_stream operation_stream
             in
             (* Convert ops *)
             let map_op op =
               match decode_operation_data op.Operation.proto with
               | None -> None
               | Some protocol_data ->
                   Some Proto.{shell = op.shell; protocol_data}
             in
             let fold_op _k (op, _error) acc =
               match map_op op with Some op -> op :: acc | None -> acc
             in
             (* First call : retrieve the current set of op from the mempool *)
             let applied =
               if params#applied then
                 List.filter_map map_op (List.map snd applied)
               else []
             in
             let refused =
               if params#refused then
                 Operation_hash.Map.fold fold_op refused.map []
               else []
             in
             let branch_refused =
               if params#branch_refused then
                 Operation_hash.Map.fold fold_op branch_refused.map []
               else []
             in
             let branch_delayed =
               if params#branch_delayed then
                 Operation_hash.Map.fold fold_op branch_delayed.map []
               else []
             in
             let current_mempool =
               List.concat [applied; refused; branch_refused; branch_delayed]
             in
             let current_mempool = ref (Some current_mempool) in
             let filter_result = function
               | `Applied -> params#applied
               | `Refused -> params#refused
               | `Branch_refused -> params#branch_refused
               | `Branch_delayed -> params#branch_delayed
             in
             let rec next () =
               match !current_mempool with
               | Some mempool ->
                   current_mempool := None ;
                   Lwt.return_some mempool
               | None -> (
                   Lwt_stream.get op_stream >>= function
                   | Some (kind, shell, protocol_data) when filter_result kind
                     -> (
                       (* NOTE: Should the protocol change, a new Prevalidation
                        * context would  be created. Thus, we use the same Proto. *)
                       match
                         Data_encoding.Binary.to_bytes_opt
                           Proto.operation_data_encoding
                           protocol_data
                       with
                       | None -> Lwt.return_none
                       | Some proto_bytes -> (
                           match decode_operation_data proto_bytes with
                           | None -> Lwt.return_none
                           | Some protocol_data ->
                               Lwt.return_some [{Proto.shell; protocol_data}]))
                   | Some _ -> next ()
                   | None -> Lwt.return_none)
             in
             let shutdown () = Lwt_watcher.shutdown stopper in
             RPC_answer.return_stream {next; shutdown}) ;
       !dir)

  module Handlers = struct
    type self = worker

    (* For every consensus operation which arrived before the block
       they are branched on, we try to propagate them if the protocol
       manages to apply the operation on the current validation state
       or if the operation can be applied later on ([branch_delayed]
       classification). *)
    let may_propagate_unknown_branch_operation pv op =
      ( Prevalidation.parse op >>?= fun op ->
        let is_alternative_endorsement () =
          Lwt.return pv.validation_state >>=? fun validation_state ->
          Prevalidation.apply_operation validation_state op >>= function
          | Applied _ | Branch_delayed _ -> return_true
          | _ -> return_false
        in
        if is_endorsement op then is_alternative_endorsement ()
        else return_false )
      >>= function
      | Ok b -> Lwt.return b
      | Error _ -> Lwt.return_false

    let on_operation_arrived w (pv : state) oph op =
      if already_handled pv oph then return_unit
      else
        pre_filter w pv oph op >>= function
        | true ->
            if not (Block_hash.Set.mem op.Operation.shell.branch pv.live_blocks)
            then (
              let error = [Exn (Failure "Unknown branch operation")] in
              handle_branch_refused pv op oph error ;
              may_propagate_unknown_branch_operation pv op >>= function
              | true ->
                  let pending = Operation_hash.Set.singleton oph in
                  advertise w pv {Mempool.empty with pending} ;
                  return_unit
              | false ->
                  Distributed_db.Operation.clear_or_cancel
                    pv.parameters.chain_db
                    oph ;
                  return_unit)
            else (
              (* TODO: should this have an influence on the peer's score ? *)
              pv.pending <- Operation_hash.Map.add oph op pv.pending ;
              return_unit)
        | false ->
            Distributed_db.Operation.clear_or_cancel pv.parameters.chain_db oph ;
            return_unit

    let on_inject _w pv op =
      let oph = Operation.hash op in
      if already_handled pv oph then return_unit
        (* FIXME : is this an error ? *)
      else
        Lwt.return pv.validation_state >>=? fun validation_state ->
        Lwt.return (Prevalidation.parse op) >>=? fun parsed_op ->
        Prevalidation.apply_operation validation_state parsed_op >>= function
        | Applied (_, _result) ->
            Distributed_db.inject_operation pv.parameters.chain_db oph op
            >>= fun (_ : bool) ->
            pv.pending <- Operation_hash.Map.add parsed_op.hash op pv.pending ;
            return_unit
        | res ->
            failwith
              "Error while applying operation %a:@ %a"
              Operation_hash.pp
              oph
              Prevalidation.pp_result
              res

    let on_notify w pv peer mempool =
      let all_ophs =
        List.fold_left
          (fun s oph -> Operation_hash.Set.add oph s)
          mempool.Mempool.pending
          mempool.known_valid
      in
      let to_fetch =
        Operation_hash.Set.filter
          (fun oph -> not (already_handled pv oph))
          all_ophs
      in
      fetch_operations w pv ~peer to_fetch

    let on_flush w pv predecessor live_blocks live_operations =
      Lwt_watcher.shutdown_input pv.operation_stream ;
      let chain_store = Distributed_db.chain_store pv.parameters.chain_db in
      list_pendings
        pv.parameters.chain_db
        ~from_block:pv.predecessor
        ~to_block:predecessor
        ~live_blocks
        (Operation_hash.Map.union
           (fun _key v _ -> Some v)
           (Preapply_result.operations (validation_result pv))
           pv.pending)
      >>= fun pending ->
      let timestamp_system = Tezos_stdlib_unix.Systime_os.now () in
      let timestamp = Time.System.to_protocol timestamp_system in
      Prevalidation.create
        chain_store
        ~predecessor
        ~live_blocks
        ~live_operations
        ~timestamp
        ()
      >>= fun validation_state ->
      Worker.log_event
        w
        (Operations_not_flushed (Operation_hash.Map.cardinal pending))
      >>= fun () ->
      pv.predecessor <- predecessor ;
      pv.live_blocks <- live_blocks ;
      pv.live_operations <- live_operations ;
      pv.timestamp <- timestamp_system ;
      pv.mempool <- {known_valid = []; pending = Operation_hash.Set.empty} ;
      pv.pending <- pending ;
      pv.in_mempool <- Operation_hash.Set.empty ;
      Ringo.Ring.clear pv.branch_delayed.ring ;
      pv.branch_delayed.map <- Operation_hash.Map.empty ;
      Ringo.Ring.clear pv.branch_refused.ring ;
      pv.branch_refused.map <- Operation_hash.Map.empty ;
      pv.applied <- [] ;
      pv.validation_state <- validation_state ;
      pv.operation_stream <- Lwt_watcher.create_input () ;
      return_unit

    let on_advertise pv =
      match pv.advertisement with
      | `None -> () (* should not happen *)
      | `Pending mempool ->
          pv.advertisement <- `None ;
          Distributed_db.Advertise.current_head
            pv.parameters.chain_db
            ~mempool
            pv.predecessor

    let on_request : type r. worker -> r Request.t -> r tzresult Lwt.t =
     fun w request ->
      let pv = Worker.state w in
      (match request with
      | Request.Flush (hash, live_blocks, live_operations) ->
          on_advertise pv ;
          (* TODO: rebase the advertisement instead *)
          let chain_store = Distributed_db.chain_store pv.parameters.chain_db in
          Store.Block.read_block chain_store hash
          >>=? fun block : r tzresult Lwt.t ->
          on_flush w pv block live_blocks live_operations
      | Request.Notify (peer, mempool) ->
          on_notify w pv peer mempool ;
          return_unit
      | Request.Leftover ->
          (* unprocessed ops are handled just below *)
          return_unit
      | Request.Inject op -> on_inject w pv op
      | Request.Arrived (oph, op) -> on_operation_arrived w pv oph op
      | Request.Advertise ->
          on_advertise pv ;
          return_unit)
      >>=? fun r ->
      handle_unprocessed w pv >>= fun () -> return r

    let on_close w =
      let pv = Worker.state w in
      Operation_hash.Set.iter
        (Distributed_db.Operation.clear_or_cancel pv.parameters.chain_db)
        pv.fetching ;
      Lwt.return_unit

    let on_launch w _ (limits, chain_db) =
      let chain_store = Distributed_db.chain_store chain_db in
      Store.Chain.current_head chain_store >>= fun predecessor ->
      Store.Chain.mempool chain_store >>= fun mempool ->
      Store.Chain.live_blocks chain_store
      >>= fun (live_blocks, live_operations) ->
      let timestamp_system = Tezos_stdlib_unix.Systime_os.now () in
      let timestamp = Time.System.to_protocol timestamp_system in
      Prevalidation.create
        chain_store
        ~predecessor
        ~timestamp
        ~live_blocks
        ~live_operations
        ()
      >>= fun validation_state ->
      let fetching =
        List.fold_left
          (fun s h -> Operation_hash.Set.add h s)
          Operation_hash.Set.empty
          mempool.known_valid
      in
      let parameters = {limits; chain_db} in
      let make_bounded_operation_collections () =
        {
          ring = Ringo.Ring.create limits.max_refused_operations;
          map = Operation_hash.Map.empty;
        }
      in
      let pv =
        {
          parameters;
          predecessor;
          timestamp = timestamp_system;
          live_blocks;
          live_operations;
          mempool = {known_valid = []; pending = Operation_hash.Set.empty};
          refused = make_bounded_operation_collections ();
          fetching;
          pending = Operation_hash.Map.empty;
          in_mempool = Operation_hash.Set.empty;
          applied = [];
          branch_refused = make_bounded_operation_collections ();
          branch_delayed = make_bounded_operation_collections ();
          validation_state;
          operation_stream = Lwt_watcher.create_input ();
          advertisement = `None;
          rpc_directory;
          filter_config =
            Protocol_hash.Map.empty (* TODO: initialize from config file *);
        }
      in
      fetch_operations w pv fetching ;
      return pv

    let on_error w r st errs =
      Worker.record_event w (Event.Request (r, st, Some errs)) ;
      match r with
      | Request.(View (Inject _)) -> return_unit
      | _ -> Lwt.return_error errs

    let on_completion w r _ st =
      Worker.record_event w (Event.Request (Request.view r, st, None)) ;
      Lwt.return_unit

    let on_no_request _ = return_unit
  end

  let table = Worker.create_table Queue

  (* NOTE: we register a single worker for each instantiation of this Make
   * functor (and thus a single worker for the single instantiation of Worker).
   * Whilst this is somewhat abusing the intended purpose of worker, it is part
   * of a transition plan to a one-worker-per-peer architecture. *)
  let worker_promise =
    Worker.launch
      table
      Arg.limits.worker_limits
      name
      (Arg.limits, Arg.chain_db)
      (module Handlers)

  (* FIXME https://gitlab.com/tezos/tezos/-/merge_requests/2668

     If the interface of worker would not use tzresult we would
     see that this is not necessary since the function
     [Handlers.on_launch] do not actually raise any error. *)
  let initialization_errors = worker_promise >>=? fun _ -> return_unit

  let worker =
    lazy
      (match Lwt.state worker_promise with
      | Lwt.Return (Ok worker) -> worker
      | Lwt.Return (Error _) | Lwt.Fail _ | Lwt.Sleep -> assert false)

  let fitness () =
    let w = Lazy.force worker in
    let pv = Worker.state w in
    ( Lwt.return pv.validation_state >>=? fun state ->
      Prevalidation.status state >>=? fun status ->
      return status.block_result.fitness )
    >>= function
    | Ok fitness -> Lwt.return fitness
    | Error _ -> Lwt.return (Store.Block.fitness pv.predecessor)
end

module ChainProto_registry = Map.Make (struct
  type t = Chain_id.t * Protocol_hash.t

  let compare (c1, p1) (c2, p2) =
    let pc = Protocol_hash.compare p1 p2 in
    if pc = 0 then Chain_id.compare c1 c2 else pc
end)

let chain_proto_registry : t ChainProto_registry.t ref =
  ref ChainProto_registry.empty

let create limits (module Filter : Prevalidator_filters.FILTER) chain_db =
  let chain_store = Distributed_db.chain_store chain_db in
  let chain_id = Store.Chain.chain_id chain_store in
  match
    ChainProto_registry.find (chain_id, Filter.Proto.hash) !chain_proto_registry
  with
  | None ->
      let module Prevalidator =
        Make
          (Filter)
          (struct
            let limits = limits

            let chain_db = chain_db

            let chain_id = chain_id
          end)
      in
      (* Checking initialization errors before giving a reference to dangerous
       * `worker` value to caller. *)
      Prevalidator.initialization_errors >>=? fun () ->
      chain_proto_registry :=
        ChainProto_registry.add
          Prevalidator.name
          (module Prevalidator : T)
          !chain_proto_registry ;
      return (module Prevalidator : T)
  | Some p -> return p

let shutdown (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  chain_proto_registry :=
    ChainProto_registry.remove Prevalidator.name !chain_proto_registry ;
  Prevalidator.Worker.shutdown w

let flush (t : t) head live_blocks live_operations =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  Prevalidator.Worker.Queue.push_request_and_wait
    w
    (Request.Flush (head, live_blocks, live_operations))

let notify_operations (t : t) peer mempool =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  Prevalidator.Worker.Queue.push_request w (Request.Notify (peer, mempool))

let operations (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  let pv = Prevalidator.Worker.state w in
  ( {(Prevalidator.validation_result pv) with applied = List.rev pv.applied},
    pv.pending )

let pending (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  let pv = Prevalidator.Worker.state w in
  let ops = Preapply_result.operations (Prevalidator.validation_result pv) in
  Lwt.return ops

let timestamp (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  let pv = Prevalidator.Worker.state w in
  pv.timestamp

let fitness (t : t) =
  let module Prevalidator : T = (val t) in
  Prevalidator.fitness ()

let inject_operation (t : t) op =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  Prevalidator.Worker.Queue.push_request_and_wait w (Inject op)

let status (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  Prevalidator.Worker.status w

let running_workers () =
  ChainProto_registry.fold
    (fun (id, proto) t acc -> (id, proto, t) :: acc)
    !chain_proto_registry
    []

let pending_requests (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  Prevalidator.Worker.Queue.pending_requests w

let current_request (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  Prevalidator.Worker.current_request w

let last_events (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  Prevalidator.Worker.last_events w

let protocol_hash (t : t) =
  let module Prevalidator : T = (val t) in
  Prevalidator.Proto.hash

let parameters (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  (Prevalidator.Worker.state w).parameters

let information (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  Prevalidator.Worker.information w

let pipeline_length (t : t) =
  let module Prevalidator : T = (val t) in
  let w = Lazy.force Prevalidator.worker in
  Prevalidator.Worker.Queue.pending_requests_length w

let empty_rpc_directory : unit RPC_directory.t =
  RPC_directory.register
    RPC_directory.empty
    (Block_services.Empty.S.Mempool.pending_operations RPC_path.open_root)
    (fun _pv () () ->
      return
        {
          Block_services.Empty.Mempool.applied = [];
          refused = Operation_hash.Map.empty;
          branch_refused = Operation_hash.Map.empty;
          branch_delayed = Operation_hash.Map.empty;
          unprocessed = Operation_hash.Map.empty;
        })

let rpc_directory : t option RPC_directory.t =
  RPC_directory.register_dynamic_directory
    RPC_directory.empty
    (Block_services.mempool_path RPC_path.open_root)
    (function
      | None ->
          Lwt.return
            (RPC_directory.map (fun _ -> Lwt.return_unit) empty_rpc_directory)
      | Some t -> (
          let module Prevalidator : T = (val t : T) in
          Prevalidator.initialization_errors >>= function
          | Error _ ->
              Lwt.return
                (RPC_directory.map
                   (fun _ -> Lwt.return_unit)
                   empty_rpc_directory)
          | Ok () ->
              let w = Lazy.force Prevalidator.worker in
              let pv = Prevalidator.Worker.state w in
              let pv_rpc_dir = Lazy.force pv.rpc_directory in
              Lwt.return (RPC_directory.map (fun _ -> Lwt.return pv) pv_rpc_dir)
          ))
