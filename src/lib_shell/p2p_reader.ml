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

module Message = Distributed_db_message
module P2p_reader_event = Distributed_db_event.P2p_reader_event

type p2p = (Message.t, Peer_metadata.t, Connection_metadata.t) P2p.net

type connection =
  (Message.t, Peer_metadata.t, Connection_metadata.t) P2p.connection

type callback = {
  notify_branch : P2p_peer.Id.t -> Block_locator.t -> unit;
  notify_head : P2p_peer.Id.t -> Block_header.t -> Mempool.t -> unit;
  disconnection : P2p_peer.Id.t -> unit;
}

type chain_db = {
  chain_state : State.Chain.t;
  operation_db : Distributed_db_requester.Raw_operation.t;
  block_header_db : Distributed_db_requester.Raw_block_header.t;
  operations_db : Distributed_db_requester.Raw_operations.t;
  mutable callback : callback;
  active_peers : P2p_peer.Set.t ref;
  active_connections : connection P2p_peer.Table.t;
}

type t = {
  p2p : p2p;
  gid : P2p_peer.Id.t;  (** remote peer id *)
  conn : connection;
  peer_active_chains : chain_db Chain_id.Table.t;
  disk : State.t;
  canceler : Lwt_canceler.t;
  mutable worker : unit Lwt.t;
  protocol_db : Distributed_db_requester.Raw_protocol.t;
  active_chains : chain_db Chain_id.Table.t;
      (** All chains managed by this peer **)
  unregister : unit -> unit;
}

(* performs [f chain_db] if the chain is active for the remote peer
   and [chain_db] is the chain_db corresponding to this chain id, otherwise
   does nothing (simply update peer metadata). *)
let may_handle state chain_id f =
  match Chain_id.Table.find state.peer_active_chains chain_id with
  | None ->
      let meta = P2p.get_peer_metadata state.p2p state.gid in
      Peer_metadata.incr meta Inactive_chain ;
      Lwt.return_unit
  | Some chain_db ->
      f chain_db

(* performs [f chain_db] if [chain_id] is active and [chain_db] is the
   chain_db corresponding to this chain id. *)
let may_handle_global state chain_id f =
  match Chain_id.Table.find state.active_chains chain_id with
  | None ->
      Lwt.return_unit
  | Some chain_db ->
      f chain_db

let find_pending_operations {peer_active_chains; _} h i =
  Chain_id.Table.to_seq_values peer_active_chains
  |> Seq.find (fun chain_db ->
         Distributed_db_requester.Raw_operations.pending
           chain_db.operations_db
           (h, i))

let find_pending_operation {peer_active_chains; _} h =
  Chain_id.Table.to_seq_values peer_active_chains
  |> Seq.find (fun chain_db ->
         Distributed_db_requester.Raw_operation.pending chain_db.operation_db h)

let read_operation state h =
  (* NOTE: to optimise this into an early-return map-and-search we need either a
     special [Seq.find_map : ('a -> 'b option) -> 'a Seq.t -> 'b option]
     or we need a [Seq.map_s] that is lazy. *)
  Chain_id.Table.fold_s
    (fun chain_id chain_db acc ->
      match acc with
      | Some _ ->
          Lwt.return acc
      | None -> (
          Distributed_db_requester.Raw_operation.read_opt
            chain_db.operation_db
            h
          >>= function
          | None -> Lwt.return_none | Some bh -> Lwt.return_some (chain_id, bh)
          ))
    state.active_chains
    None

let read_block_header {disk; _} h =
  State.read_block disk h
  >>= function
  | Some b ->
      Lwt.return_some (State.Block.chain_id b, State.Block.header b)
  | None ->
      Lwt.return_none

let read_predecessor_header {disk; _} h offset =
  if Compare.Int32.(offset < 0l) then Lwt.return_none
  else
    State.read_block disk h
    >>= function
    | None ->
        Lwt.return_none
    | Some block -> (
        if Compare.Int32.(offset > State.Block.level block) then
          Lwt.return_none
        else
          State.Block.predecessor_n block (Int32.to_int offset)
          >>= function
          | None ->
              Lwt.return_none
          | Some pred_hash -> (
              State.read_block disk pred_hash
              >>= function
              | None ->
                  Lwt.return_none
              | Some b ->
                  Lwt.return_some (State.Block.header b) ) )

let find_pending_block_header {peer_active_chains; _} h =
  Chain_id.Table.to_seq_values peer_active_chains
  |> Seq.find (fun chain_db ->
         Distributed_db_requester.Raw_block_header.pending
           chain_db.block_header_db
           h)

let deactivate gid chain_db =
  chain_db.callback.disconnection gid ;
  chain_db.active_peers := P2p_peer.Set.remove gid !(chain_db.active_peers) ;
  P2p_peer.Table.remove chain_db.active_connections gid

(* Active the chain_id for the remote peer. Is a nop if it is already activated. *)
let activate state chain_id chain_db =
  let meta = P2p.get_peer_metadata state.p2p state.gid in
  match Chain_id.Table.find state.peer_active_chains chain_id with
  | Some _ ->
      ()
  | None ->
      Peer_metadata.update_requests meta Branch
      @@ P2p.try_send state.p2p state.conn
      @@ Get_current_branch chain_id ;
      chain_db.active_peers :=
        P2p_peer.Set.add state.gid !(chain_db.active_peers) ;
      P2p_peer.Table.add chain_db.active_connections state.gid state.conn ;
      Chain_id.Table.add state.peer_active_chains chain_id chain_db

let my_peer_id state = P2p.peer_id state.p2p

let handle_msg state msg =
  let open Message in
  let meta = P2p.get_peer_metadata state.p2p state.gid in
  P2p_reader_event.(emit read_message) (state.gid, P2p_message.Message msg)
  >>= fun () ->
  match msg with
  | Get_current_branch chain_id ->
      Peer_metadata.incr meta @@ Received_request Branch ;
      may_handle_global state chain_id
      @@ fun chain_db ->
      activate state chain_id chain_db ;
      let seed =
        {Block_locator.receiver_id = state.gid; sender_id = my_peer_id state}
      in
      Chain.locator chain_db.chain_state seed
      >>= fun locator ->
      Peer_metadata.update_responses meta Branch
      @@ P2p.try_send state.p2p state.conn
      @@ Current_branch (chain_id, locator) ;
      Lwt.return_unit
  | Current_branch (chain_id, locator) ->
      may_handle state chain_id
      @@ fun chain_db ->
      let (head, hist) = (locator :> Block_header.t * Block_hash.t list) in
      Lwt_list.exists_p
        (State.Block.known_invalid chain_db.chain_state)
        (Block_header.hash head :: hist)
      >>= fun known_invalid ->
      if known_invalid then (
        P2p.disconnect state.p2p state.conn
        >>= fun () ->
        P2p.greylist_peer state.p2p state.gid ;
        Lwt.return_unit )
      else if
        not (Clock_drift.is_not_too_far_in_the_future head.shell.timestamp)
      then (
        Peer_metadata.incr meta Future_block ;
        P2p_reader_event.(emit received_future_block)
          (Block_header.hash head, state.gid) )
      else (
        chain_db.callback.notify_branch state.gid locator ;
        (* TODO discriminate between received advertisements
           and responses? *)
        Peer_metadata.incr meta @@ Received_advertisement Branch ;
        Lwt.return_unit )
  | Deactivate chain_id ->
      may_handle state chain_id
      @@ fun chain_db ->
      deactivate state.gid chain_db ;
      Chain_id.Table.remove state.peer_active_chains chain_id ;
      Lwt.return_unit
  | Get_current_head chain_id ->
      may_handle state chain_id
      @@ fun chain_db ->
      Peer_metadata.incr meta @@ Received_request Head ;
      let {Connection_metadata.disable_mempool; _} =
        P2p.connection_remote_metadata state.p2p state.conn
      in
      ( if disable_mempool then
        Chain.head chain_db.chain_state
        >>= fun head -> Lwt.return (State.Block.header head, Mempool.empty)
      else State.Current_mempool.get chain_db.chain_state )
      >>= fun (head, mempool) ->
      (* TODO bound the sent mempool size *)
      Peer_metadata.update_responses meta Head
      @@ P2p.try_send state.p2p state.conn
      @@ Current_head (chain_id, head, mempool) ;
      Lwt.return_unit
  | Current_head (chain_id, header, mempool) ->
      may_handle state chain_id
      @@ fun chain_db ->
      let head = Block_header.hash header in
      State.Block.known_invalid chain_db.chain_state head
      >>= fun known_invalid ->
      let {Connection_metadata.disable_mempool; _} =
        P2p.connection_local_metadata state.p2p state.conn
      in
      let known_invalid =
        known_invalid || (disable_mempool && mempool <> Mempool.empty)
        (* A non-empty mempool was received while mempool is deactivated,
               so the message is ignored.
               This should probably warrant a reduction of the sender's score. *)
      in
      if known_invalid then (
        P2p.disconnect state.p2p state.conn
        >>= fun () ->
        P2p.greylist_peer state.p2p state.gid ;
        Lwt.return_unit )
      else if
        not (Clock_drift.is_not_too_far_in_the_future header.shell.timestamp)
      then (
        Peer_metadata.incr meta Future_block ;
        P2p_reader_event.(emit received_future_block) (head, state.gid) )
      else (
        chain_db.callback.notify_head state.gid header mempool ;
        (* TODO discriminate between received advertisements
           and responses? *)
        Peer_metadata.incr meta @@ Received_advertisement Head ;
        Lwt.return_unit )
  | Get_block_headers hashes ->
      Peer_metadata.incr meta @@ Received_request Block_header ;
      Lwt_list.iter_p
        (fun hash ->
          read_block_header state hash
          >>= function
          | None ->
              Peer_metadata.incr meta @@ Unadvertised Block ;
              Lwt.return_unit
          | Some (_chain_id, header) ->
              Peer_metadata.update_responses meta Block_header
              @@ P2p.try_send state.p2p state.conn
              @@ Block_header header ;
              Lwt.return_unit)
        hashes
  | Block_header block -> (
      let hash = Block_header.hash block in
      match find_pending_block_header state hash with
      | None ->
          Peer_metadata.incr meta Unexpected_response ;
          Lwt.return_unit
      | Some chain_db ->
          Distributed_db_requester.Raw_block_header.notify
            chain_db.block_header_db
            state.gid
            hash
            block
          >>= fun () ->
          Peer_metadata.incr meta @@ Received_response Block_header ;
          Lwt.return_unit )
  | Get_operations hashes ->
      Peer_metadata.incr meta @@ Received_request Operations ;
      Lwt_list.iter_p
        (fun hash ->
          read_operation state hash
          >>= function
          | None ->
              Peer_metadata.incr meta @@ Unadvertised Operations ;
              Lwt.return_unit
          | Some (_chain_id, op) ->
              Peer_metadata.update_responses meta Operations
              @@ P2p.try_send state.p2p state.conn
              @@ Operation op ;
              Lwt.return_unit)
        hashes
  | Operation operation -> (
      let hash = Operation.hash operation in
      match find_pending_operation state hash with
      | None ->
          Peer_metadata.incr meta Unexpected_response ;
          Lwt.return_unit
      | Some chain_db ->
          Distributed_db_requester.Raw_operation.notify
            chain_db.operation_db
            state.gid
            hash
            operation
          >>= fun () ->
          Peer_metadata.incr meta @@ Received_response Operations ;
          Lwt.return_unit )
  | Get_protocols hashes ->
      Peer_metadata.incr meta @@ Received_request Protocols ;
      Lwt_list.iter_p
        (fun hash ->
          State.Protocol.read_opt state.disk hash
          >>= function
          | None ->
              Peer_metadata.incr meta @@ Unadvertised Protocol ;
              Lwt.return_unit
          | Some p ->
              Peer_metadata.update_responses meta Protocols
              @@ P2p.try_send state.p2p state.conn
              @@ Protocol p ;
              Lwt.return_unit)
        hashes
  | Protocol protocol ->
      let hash = Protocol.hash protocol in
      Distributed_db_requester.Raw_protocol.notify
        state.protocol_db
        state.gid
        hash
        protocol
      >>= fun () ->
      Peer_metadata.incr meta @@ Received_response Protocols ;
      Lwt.return_unit
  | Get_operations_for_blocks blocks ->
      Peer_metadata.incr meta @@ Received_request Operations_for_block ;
      Lwt_list.iter_p
        (fun (hash, ofs) ->
          State.read_block state.disk hash
          >>= function
          | None ->
              Lwt.return_unit
          | Some block ->
              State.Block.operations block ofs
              >>= fun (ops, path) ->
              Peer_metadata.update_responses meta Operations_for_block
              @@ P2p.try_send state.p2p state.conn
              @@ Operations_for_block (hash, ofs, ops, path) ;
              Lwt.return_unit)
        blocks
  | Operations_for_block (block, ofs, ops, path) -> (
    match find_pending_operations state block ofs with
    | None ->
        Peer_metadata.incr meta Unexpected_response ;
        Lwt.return_unit
    | Some chain_db ->
        Distributed_db_requester.Raw_operations.notify
          chain_db.operations_db
          state.gid
          (block, ofs)
          (ops, path)
        >>= fun () ->
        Peer_metadata.incr meta @@ Received_response Operations_for_block ;
        Lwt.return_unit )
  | Get_checkpoint chain_id ->
      Peer_metadata.incr meta @@ Received_request Checkpoint ;
      may_handle_global state chain_id
      @@ fun chain_db ->
      State.Chain.checkpoint chain_db.chain_state
      >>= fun checkpoint ->
      Peer_metadata.update_responses meta Checkpoint
      @@ P2p.try_send state.p2p state.conn
      @@ Checkpoint (chain_id, checkpoint) ;
      Lwt.return_unit
  | Checkpoint _ ->
      (* This message is currently unused: it will be used for future
         bootstrap heuristics. *)
      Peer_metadata.incr meta @@ Received_response Checkpoint ;
      Lwt.return_unit
  | Get_protocol_branch (chain_id, proto_level) -> (
      Peer_metadata.incr meta @@ Received_request Protocol_branch ;
      may_handle_global state chain_id
      @@ fun chain_db ->
      activate state chain_id chain_db ;
      let seed =
        {Block_locator.receiver_id = state.gid; sender_id = my_peer_id state}
      in
      State.compute_protocol_locator chain_db.chain_state ~proto_level seed
      >>= function
      | Some locator ->
          Peer_metadata.update_responses meta Protocol_branch
          @@ P2p.try_send state.p2p state.conn
          @@ Protocol_branch (chain_id, proto_level, locator) ;
          Lwt.return_unit
      | None ->
          Lwt.return_unit )
  | Protocol_branch (_chain, _proto_level, _locator) ->
      (* This message is currently unused: it will be used for future
         multipass. *)
      Peer_metadata.incr meta @@ Received_response Protocol_branch ;
      Lwt.return_unit
  | Get_predecessor_header (block_hash, offset) -> (
      Peer_metadata.incr meta @@ Received_request Predecessor_header ;
      read_predecessor_header state block_hash offset
      >>= function
      | None ->
          (* The peer is not expected to request blocks that are beyond
             our locator. *)
          Peer_metadata.incr meta @@ Unadvertised Block ;
          Lwt.return_unit
      | Some header ->
          Peer_metadata.update_responses meta Predecessor_header
          @@ P2p.try_send state.p2p state.conn
          @@ Predecessor_header (block_hash, offset, header) ;
          Lwt.return_unit )
  | Predecessor_header (_block_hash, _offset, _header) ->
      (* This message is currently unused: it will be used to improve
         bootstrapping. *)
      Peer_metadata.incr meta @@ Received_response Predecessor_header ;
      Lwt.return_unit

let rec worker_loop state =
  protect ~canceler:state.canceler (fun () -> P2p.recv state.p2p state.conn)
  >>= function
  | Ok msg ->
      handle_msg state msg >>= fun () -> worker_loop state
  | Error _ ->
      Chain_id.Table.iter
        (fun _ -> deactivate state.gid)
        state.peer_active_chains ;
      state.unregister () ;
      Lwt.return_unit

let run ~register ~unregister p2p disk protocol_db active_chains gid conn =
  let canceler = Lwt_canceler.create () in
  let state =
    {
      active_chains;
      protocol_db;
      p2p;
      disk;
      conn;
      gid;
      canceler;
      peer_active_chains = Chain_id.Table.create 17;
      worker = Lwt.return_unit;
      unregister;
    }
  in
  Chain_id.Table.iter
    (fun chain_id _chain_db ->
      Error_monad.dont_wait
        (fun exc ->
          Format.eprintf "Uncaught exception: %s\n%!" (Printexc.to_string exc))
        (fun trace ->
          Format.eprintf
            "Uncaught error: %a\n%!"
            Error_monad.pp_print_error
            trace)
        (fun () ->
          let meta = P2p.get_peer_metadata p2p gid in
          Peer_metadata.incr meta (Sent_request Branch) ;
          P2p.send p2p conn (Get_current_branch chain_id)))
    active_chains ;
  state.worker <-
    Lwt_utils.worker
      (Format.asprintf "db_network_reader.%a" P2p_peer.Id.pp_short gid)
      ~on_event:Internal_event.Lwt_worker_event.on_event
      ~run:(fun () -> worker_loop state)
      ~cancel:(fun () -> Lwt_canceler.cancel canceler) ;
  register state

let shutdown s = Lwt_canceler.cancel s.canceler >>= fun () -> s.worker
