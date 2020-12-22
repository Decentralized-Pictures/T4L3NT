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

(* TODO Test cancellation of a (pending) connection *)

(* TODO do not recompute list_known_points at each requests... but
        only once in a while, e.g. every minutes or when a point
        or the associated peer_id is blacklisted. *)

(* TODO allow to track "requested peer_ids" when we reconnect to a point. *)

include Internal_event.Legacy_logging.Make (struct
  let name = "p2p.pool"
end)

type config = {
  identity : P2p_identity.t;
  trusted_points : P2p_point.Id.t list;
  peers_file : string;
  private_mode : bool;
  max_known_points : (int * int) option;
  max_known_peer_ids : (int * int) option;
}

type ('msg, 'peer, 'conn) t = {
  config : config;
  peer_meta_config : 'peer P2p_params.peer_meta_config;
  (* Set of points corresponding to this peer *)
  my_id_points : unit P2p_point.Table.t;
  known_peer_ids :
    (('msg, 'peer, 'conn) P2p_conn.t, 'peer, 'conn) P2p_peer_state.Info.t
    P2p_peer.Table.t;
  connected_peer_ids :
    (('msg, 'peer, 'conn) P2p_conn.t, 'peer, 'conn) P2p_peer_state.Info.t
    P2p_peer.Table.t;
  known_points :
    ('msg, 'peer, 'conn) P2p_conn.t P2p_point_state.Info.t P2p_point.Table.t;
  connected_points :
    ('msg, 'peer, 'conn) P2p_conn.t P2p_point_state.Info.t P2p_point.Table.t;
  triggers : P2p_trigger.t;
  log : P2p_connection.P2p_event.t -> unit;
  acl : P2p_acl.t;
}

module Gc_point_set = List.Bounded (struct
  type t = Time.System.t * P2p_point.Id.t

  let compare (x, _) (y, _) = -Time.System.compare x y
end)

let gc_points {config = {max_known_points; _}; known_points; log; _} =
  match max_known_points with
  | None ->
      ()
  | Some (_, target) ->
      let current_size = P2p_point.Table.length known_points in
      if current_size > target then (
        let to_remove_target = current_size - target in
        let now = Systime_os.now () in
        (* TODO: maybe time of discovery? *)
        let table = Gc_point_set.create to_remove_target in
        P2p_point.Table.iter
          (fun p point_info ->
            if P2p_point_state.is_disconnected point_info then
              let time =
                match P2p_point_state.Info.last_miss point_info with
                | None ->
                    now
                | Some t ->
                    t
              in
              Gc_point_set.insert (time, p) table)
          known_points ;
        let to_remove = Gc_point_set.get table in
        ListLabels.iter to_remove ~f:(fun (_, p) ->
            P2p_point.Table.remove known_points p) ;
        log Gc_points )

let register_point ?trusted pool ((addr, port) as point) =
  match P2p_point.Table.find pool.known_points point with
  | None ->
      let point_info = P2p_point_state.Info.create ?trusted addr port in
      Option.iter
        (fun (max, _) ->
          if P2p_point.Table.length pool.known_points >= max then
            gc_points pool)
        pool.config.max_known_points ;
      P2p_point.Table.add pool.known_points point point_info ;
      P2p_trigger.broadcast_new_point pool.triggers ;
      pool.log (New_point point) ;
      point_info
  | Some point_info ->
      ( match trusted with
      | Some true ->
          P2p_point_state.Info.set_trusted point_info
      | Some false ->
          P2p_point_state.Info.unset_trusted point_info
      | None ->
          () ) ;
      point_info

let unregister_point pool point =
  P2p_point.Table.remove pool.known_points point

let register_new_point ?trusted t point =
  if not (P2p_point.Table.mem t.my_id_points point) then
    Some (register_point ?trusted t point)
  else None

let register_list_of_new_points ?trusted ~medium ~source t point_list =
  debug
    "Getting points from %s of %a: %a"
    medium
    P2p_peer.Id.pp
    source
    P2p_point.Id.pp_list
    point_list ;
  let f point = register_new_point ?trusted t point |> ignore in
  List.iter f point_list

(* Bounded table used to garbage collect peer_id infos when needed. The
   strategy used is to remove the info of the peer_id with the lowest
   score first. In case of equality, the info of the most recent added
   peer_id is removed. The rationale behind this choice is that in the
   case of a flood attack, the newly added infos will probably belong
   to peer_ids with the same (low) score and removing the most recent ones
   ensure that older (and probably legit) peer_id infos are kept. *)
module Gc_peer_set = List.Bounded (struct
  type t = float * Time.System.t * P2p_peer.Id.t

  let compare (s, t, _) (s', t', _) =
    let score_cmp = Stdlib.compare s s' in
    if score_cmp = 0 then Time.System.compare t t' else -score_cmp
end)

let gc_peer_ids
    { peer_meta_config = {score; _};
      config = {max_known_peer_ids; _};
      known_peer_ids;
      log;
      _ } =
  match max_known_peer_ids with
  | None ->
      ()
  | Some (_, target) ->
      let current_size = P2p_peer.Table.length known_peer_ids in
      if current_size > target then (
        let to_remove_target = current_size - target in
        let table = Gc_peer_set.create to_remove_target in
        P2p_peer.Table.iter
          (fun peer_id peer_info ->
            let created = P2p_peer_state.Info.created peer_info in
            let score = score @@ P2p_peer_state.Info.peer_metadata peer_info in
            if P2p_peer_state.is_disconnected peer_info then
              Gc_peer_set.insert (score, created, peer_id) table)
          known_peer_ids ;
        let to_remove = Gc_peer_set.get table in
        ListLabels.iter to_remove ~f:(fun (_, _, peer_id) ->
            P2p_peer.Table.remove known_peer_ids peer_id) ;
        log Gc_peer_ids )

let register_peer pool peer_id =
  match P2p_peer.Table.find pool.known_peer_ids peer_id with
  | None ->
      P2p_trigger.broadcast_new_peer pool.triggers ;
      let created = Systime_os.now () in
      let peer =
        P2p_peer_state.Info.create
          ~created
          peer_id
          ~peer_metadata:(pool.peer_meta_config.peer_meta_initial ())
      in
      Option.iter
        (fun (max, _) ->
          if P2p_peer.Table.length pool.known_peer_ids >= max then
            gc_peer_ids pool)
        pool.config.max_known_peer_ids ;
      P2p_peer.Table.add pool.known_peer_ids peer_id peer ;
      pool.log (New_peer peer_id) ;
      peer
  | Some peer ->
      peer

(* this function duplicates bit of code from the modules below to avoid
   creating mutually recursive modules *)
let connection_of_peer_id pool peer_id =
  Option.bind (P2p_peer.Table.find pool.known_peer_ids peer_id) (fun p ->
      match P2p_peer_state.get p with
      | Running {data; _} ->
          Some data
      | _ ->
          None)

(* Every running connection matching the point's ip address is returned. *)
let connections_of_addr pool addr =
  P2p_point.Table.to_seq pool.connected_points
  |> Seq.filter_map (fun ((addr', _), p) ->
         if Ipaddr.V6.compare addr addr' = 0 then
           match P2p_point_state.get p with
           | P2p_point_state.Running {data; _} ->
               Some data
           | _ ->
               None
         else None)

let get_addr pool peer_id =
  Option.map
    (fun ci -> (P2p_conn.info ci).id_point)
    (connection_of_peer_id pool peer_id)

module Points = struct
  type ('msg, 'peer, 'conn) info =
    ('msg, 'peer, 'conn) P2p_conn.t P2p_point_state.Info.t

  let info {known_points; _} point = P2p_point.Table.find known_points point

  let get_trusted pool point =
    Option.fold
      ~none:false
      ~some:P2p_point_state.Info.trusted
      (P2p_point.Table.find pool.known_points point)

  let set_trusted pool point =
    ignore @@ register_point ~trusted:true pool point

  let unset_trusted pool point =
    Option.iter
      P2p_point_state.Info.unset_trusted
      (P2p_point.Table.find pool.known_points point)

  let fold_known pool ~init ~f = P2p_point.Table.fold f pool.known_points init

  let fold_connected pool ~init ~f =
    P2p_point.Table.fold f pool.connected_points init

  let add_connected t point point_info =
    P2p_point.Table.add t.connected_points point point_info

  let remove_connected t point_info =
    P2p_point.Table.remove
      t.connected_points
      (P2p_point_state.Info.point point_info)

  let banned pool (addr, _port) = P2p_acl.banned_addr pool.acl addr

  let ban pool (addr, _port) =
    P2p_acl.IPBlacklist.add pool.acl addr ;
    (* Kick [addr]:* if it is in `Running` state. *)
    Seq.iter_p
      (fun conn -> P2p_conn.disconnect conn)
      (connections_of_addr pool addr)

  let unban pool (addr, _port) = P2p_acl.unban_addr pool.acl addr

  let trust pool point = unban pool point ; set_trusted pool point

  let untrust pool point = unset_trusted pool point
end

module Peers = struct
  type ('msg, 'peer, 'conn) info =
    (('msg, 'peer, 'conn) P2p_conn.t, 'peer, 'conn) P2p_peer_state.Info.t

  let info {known_peer_ids; _} peer_id =
    P2p_peer.Table.find known_peer_ids peer_id

  let get_peer_metadata pool peer_id =
    match P2p_peer.Table.find pool.known_peer_ids peer_id with
    | Some peer ->
        P2p_peer_state.Info.peer_metadata peer
    | None ->
        pool.peer_meta_config.peer_meta_initial ()

  let get_score pool peer_id =
    pool.peer_meta_config.score (get_peer_metadata pool peer_id)

  let set_peer_metadata pool peer_id data =
    P2p_peer_state.Info.set_peer_metadata (register_peer pool peer_id) data

  let get_trusted pool peer_id =
    Option.fold
      (P2p_peer.Table.find pool.known_peer_ids peer_id)
      ~some:P2p_peer_state.Info.trusted
      ~none:false

  let set_trusted pool peer_id =
    P2p_peer_state.Info.set_trusted (register_peer pool peer_id)

  let unset_trusted pool peer_id =
    Option.iter
      P2p_peer_state.Info.unset_trusted
      (P2p_peer.Table.find pool.known_peer_ids peer_id)

  let fold_known pool ~init ~f = P2p_peer.Table.fold f pool.known_peer_ids init

  let fold_connected pool ~init ~f =
    P2p_peer.Table.fold f pool.connected_peer_ids init

  let add_connected pool peer_id peer_info =
    P2p_peer.Table.add pool.connected_peer_ids peer_id peer_info

  let remove_connected t peer_id =
    P2p_peer.Table.remove t.connected_peer_ids peer_id

  let ban pool peer =
    P2p_acl.PeerBlacklist.add pool.acl peer ;
    (* Kick [peer] if it is in `Running` state. *)
    match connection_of_peer_id pool peer with
    | Some conn ->
        P2p_conn.disconnect conn
    | None ->
        Lwt.return_unit

  let unban pool peer = P2p_acl.unban_peer pool.acl peer

  let trust pool peer = unban pool peer ; set_trusted pool peer

  let untrust pool peer = unset_trusted pool peer

  let banned pool peer = P2p_acl.banned_peer pool.acl peer
end

module Connection = struct
  let fold pool ~init ~f =
    Peers.fold_connected pool ~init ~f:(fun peer_id peer_info acc ->
        match P2p_peer_state.get peer_info with
        | Running {data; _} ->
            f peer_id data acc
        | _ ->
            acc)

  let list pool =
    fold pool ~init:[] ~f:(fun peer_id c acc -> (peer_id, c) :: acc)

  let random_elt l =
    let n = List.length l in
    let r = Random.int n in
    List.nth l r

  let random_addr ?different_than ~no_private pool =
    let candidates =
      fold pool ~init:[] ~f:(fun _peer conn acc ->
          if no_private && P2p_conn.private_node conn then acc
          else
            match different_than with
            | Some excluded_conn when P2p_conn.equal_sock conn excluded_conn ->
                acc
            | Some _ | None -> (
                let ci = P2p_conn.info conn in
                match ci.id_point with
                | (_, None) ->
                    acc
                | (addr, Some port) ->
                    ((addr, port), ci.peer_id) :: acc ))
    in
    match candidates with [] -> None | _ -> Some (random_elt candidates)

  (** [random_connection ?conn no_private t] returns a random connection from
      the pool of connections. It ignores:
      - connections to private peers if [no_private] is set to [true]
      - connection [conn]
      Unlike [random_addr], it may return a connection to a peer who didn't
      provide a listening port *)
  let random_connection ?different_than ~no_private pool =
    let candidates =
      fold pool ~init:[] ~f:(fun _peer conn acc ->
          if no_private && P2p_conn.private_node conn then acc
          else
            match different_than with
            | Some excluded_conn when P2p_conn.equal_sock conn excluded_conn ->
                acc
            | Some _ | None ->
                conn :: acc)
    in
    match candidates with [] -> None | _ -> Some (random_elt candidates)

  let propose_swap_request pool =
    match random_connection ~no_private:true pool with
    | Some recipient -> (
      match random_addr ~different_than:recipient ~no_private:true pool with
      | None ->
          None
      | Some (proposed_point, proposed_peer_id) ->
          Some (proposed_point, proposed_peer_id, recipient) )
    | None ->
        None

  let find_by_peer_id pool peer_id =
    Option.bind (Peers.info pool peer_id) (fun p ->
        match P2p_peer_state.get p with
        | Running {data; _} ->
            Some data
        | _ ->
            None)

  let find_by_point pool point =
    Option.bind (Points.info pool point) (fun p ->
        match P2p_point_state.get p with
        | Running {data; _} ->
            Some data
        | _ ->
            None)
end

let connected_peer_ids pool = pool.connected_peer_ids

let greylist_addr pool addr =
  P2p_acl.IPGreylist.add pool.acl addr (Systime_os.now ())

let greylist_peer pool peer =
  Option.iter
    (fun (addr, _port) ->
      greylist_addr pool addr ;
      P2p_acl.PeerGreylist.add pool.acl peer)
    (get_addr pool peer)

let acl_clear pool = P2p_acl.clear pool.acl

let gc_greylist ~older_than pool =
  P2p_acl.IPGreylist.remove_old ~older_than pool.acl

let config {config; _} = config

let score {peer_meta_config = {score; _}; _} meta = score meta

let active_connections pool = P2p_peer.Table.length pool.connected_peer_ids

let create config peer_meta_config triggers ~log =
  let pool =
    {
      config;
      peer_meta_config;
      my_id_points = P2p_point.Table.create ~random:true 7;
      known_peer_ids = P2p_peer.Table.create ~random:true 53;
      connected_peer_ids = P2p_peer.Table.create ~random:true 53;
      known_points = P2p_point.Table.create ~random:true 53;
      connected_points = P2p_point.Table.create ~random:true 53;
      triggers;
      acl = P2p_acl.create 1023;
      log;
    }
  in
  List.iter (Points.set_trusted pool) config.trusted_points ;
  P2p_peer_state.Info.File.load
    config.peers_file
    peer_meta_config.peer_meta_encoding
  >>= function
  | Ok peer_ids ->
      debug
        "create pool: known points %a"
        (fun ppf known_points ->
          P2p_point.Table.iter
            (fun id _ ->
              P2p_point.Id.pp ppf id ;
              Format.pp_print_string ppf " ")
            known_points)
        pool.known_points ;
      List.iter
        (fun peer_info ->
          let peer_id = P2p_peer_state.Info.peer_id peer_info in
          P2p_peer.Table.add pool.known_peer_ids peer_id peer_info ;
          match P2p_peer_state.Info.last_seen peer_info with
          | None | Some ((_, None) (* no reachable port stored*), _) ->
              ()
          | Some ((addr, Some port), _) ->
              register_point pool (addr, port) |> ignore)
        peer_ids ;
      Lwt.return pool
  | Error err ->
      log_error "@[Failed to parse peers file:@ %a@]" pp_print_error err ;
      Lwt.return pool

let destroy {config; peer_meta_config; known_peer_ids; known_points; _} =
  lwt_log_info "Saving metadata in %s" config.peers_file
  >>= fun () ->
  P2p_peer_state.Info.File.save
    config.peers_file
    peer_meta_config.peer_meta_encoding
    (P2p_peer.Table.fold (fun _ a b -> a :: b) known_peer_ids [])
  >>= (function
        | Error err ->
            log_error "@[Failed to save peers file:@ %a@]" pp_print_error err ;
            Lwt.return_unit
        | Ok () ->
            Lwt.return_unit)
  >>= fun () ->
  P2p_peer.Table.iter_p
    (fun _peer_id peer_info ->
      match P2p_peer_state.get peer_info with
      | Accepted {cancel; _} ->
          Lwt_canceler.cancel cancel
      | Running {data = conn; _} ->
          P2p_conn.disconnect conn
      | Disconnected ->
          Lwt.return_unit)
    known_peer_ids
  >>= fun () ->
  P2p_point.Table.iter_p
    (fun _point point_info ->
      match P2p_point_state.get point_info with
      | Requested {cancel} | Accepted {cancel; _} ->
          Lwt_canceler.cancel cancel
      | Running {data = conn; _} ->
          P2p_conn.disconnect conn
      | Disconnected ->
          Lwt.return_unit)
    known_points

let add_to_id_points t point =
  P2p_point.Table.add t.my_id_points point () ;
  P2p_point.Table.remove t.known_points point

(* [sample best other points] return a list of elements selected in [points].
   The [best] first elements are taken, then [other] elements are chosen
   randomly in the rest of the list.
   Note that it might select fewer elements than [other] if it the same index
   close to the end of the list is picked multiple times. *)
let sample best other points =
  let l = List.length points in
  if l <= best + other then points
  else
    let best_indexes = List.init best (fun i -> i) in
    let other_indexes =
      List.sort compare
      @@ List.init other (fun _ -> best + Random.int (l - best))
    in
    let indexes = best_indexes @ other_indexes in
    (* Note: we are doing a [fold_left_i] by hand, passing [i] manually *)
    (fun (_, _, result) -> result)
    @@ List.fold_left
         (fun (i, indexes, acc) point ->
           match indexes with
           | [] ->
               (0, [], acc) (* TODO: early return *)
           | index :: indexes when i >= index ->
               (* We compare `i >= index` (rather than `i = index`) to avoid a
                corner case whereby two identical `index`es are present in the
                list. In that case, using `>=` makes it so that if `i` overtakes
                `index` we still pick elements. *)
               (succ i, indexes, point :: acc)
           | _ ->
               (succ i, indexes, acc))
         (0, indexes, [])
         points

let compare_known_point_info p1 p2 =
  (* The most-recently disconnected peers are greater. *)
  (* Then come long-standing connected peers. *)
  let disconnected1 = P2p_point_state.is_disconnected p1
  and disconnected2 = P2p_point_state.is_disconnected p2 in
  let compare_last_seen p1 p2 =
    match
      (P2p_point_state.Info.last_seen p1, P2p_point_state.Info.last_seen p2)
    with
    | (None, None) ->
        (Random.int 2 * 2) - 1 (* HACK... *)
    | (Some _, None) ->
        1
    | (None, Some _) ->
        -1
    | (Some (_, time1), Some (_, time2)) -> (
      match compare time1 time2 with
      | 0 ->
          (Random.int 2 * 2) - 1 (* HACK... *)
      | x ->
          x )
  in
  match (disconnected1, disconnected2) with
  | (false, false) ->
      compare_last_seen p1 p2
  | (false, true) ->
      -1
  | (true, false) ->
      1
  | (true, true) ->
      compare_last_seen p2 p1

let list_known_points ~ignore_private ?(size = 50) pool =
  P2p_point.Table.fold
    (fun point_id point_info acc ->
      if
        (ignore_private && not (P2p_point_state.Info.known_public point_info))
        || Points.banned pool point_id
      then acc
      else point_info :: acc)
    pool.known_points
    []
  |> List.sort compare_known_point_info
  |> sample (size * 3 / 5) (size * 2 / 5)
  |> List.map P2p_point_state.Info.point
  |> Lwt.return
