(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2020 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

module Request = struct
  type view = Block_hash.t

  let encoding = Block_hash.encoding

  let pp = Block_hash.pp
end

module Event = struct
  type update = Ignored_head | Branch_switch | Head_increment

  type synchronisation_status =
    | Synchronised of {is_chain_stuck : bool}
    | Not_synchronised

  type t =
    | Processed_block of {
        request : Request.view;
        request_status : Worker_types.request_status;
        update : update;
        fitness : Fitness.t;
        level : Int32.t;
        timestamp : Time.Protocol.t;
      }
    | Could_not_switch_testchain of error list
    | Bootstrapped
    | Sync_status of synchronisation_status
    | Bootstrap_active_peers of {active : int; needed : int}
    | Bootstrap_active_peers_heads_time of {
        min_head_time : Time.Protocol.t;
        max_head_time : Time.Protocol.t;
        most_recent_validation : Time.Protocol.t;
      }

  type view = t

  let view t = t

  let level = function
    | Processed_block req -> (
      match req.update with
      | Ignored_head ->
          Internal_event.Info
      | Branch_switch | Head_increment ->
          Internal_event.Notice )
    | Could_not_switch_testchain _ ->
        Internal_event.Error
    | Bootstrapped ->
        Internal_event.Notice
    | Sync_status sync_status -> (
      match sync_status with
      | Synchronised {is_chain_stuck} ->
          if is_chain_stuck then Internal_event.Error
          else Internal_event.Notice
      | Not_synchronised ->
          Internal_event.Warning )
    | Bootstrap_active_peers _ ->
        Internal_event.Debug
    | Bootstrap_active_peers_heads_time _ ->
        Internal_event.Debug

  let sync_status_encoding =
    let open Data_encoding in
    def
      "chain_status"
      ~description:
        "If 'unsynced', the node is not currently synchronized with of its \
         peers (it is probably still bootstrapping and its head is lagging \
         behind the chain's).\n\
         If 'synced', the node considers itself synchronized with its peers \
         and the current head timestamp is recent.\n\
         If 'stuck', the node considers itself synchronized with its peers \
         but the chain seems to be halted from its viewpoint."
      (string_enum
         [ ("synced", Synchronised {is_chain_stuck = false});
           ("unsynced", Not_synchronised);
           ("stuck", Synchronised {is_chain_stuck = true}) ])

  let encoding =
    let open Data_encoding in
    union
      [ case
          (Tag 0)
          ~title:"Processed_block"
          (obj6
             (req "request" Request.encoding)
             (req "status" Worker_types.request_status_encoding)
             (req
                "outcome"
                (string_enum
                   [ ("ignored", Ignored_head);
                     ("branch", Branch_switch);
                     ("increment", Head_increment) ]))
             (req "fitness" Fitness.encoding)
             (req "level" int32)
             (req "timestamp" Time.Protocol.encoding))
          (function
            | Processed_block
                {request; request_status; update; fitness; level; timestamp} ->
                Some
                  (request, request_status, update, fitness, level, timestamp)
            | _ ->
                None)
          (fun (request, request_status, update, fitness, level, timestamp) ->
            Processed_block
              {request; request_status; update; fitness; level; timestamp});
        case
          (Tag 1)
          ~title:"Could_not_switch_testchain"
          RPC_error.encoding
          (function Could_not_switch_testchain err -> Some err | _ -> None)
          (fun err -> Could_not_switch_testchain err);
        case
          (Tag 2)
          ~title:"Bootstrapped"
          unit
          (function Bootstrapped -> Some () | _ -> None)
          (fun () -> Bootstrapped);
        case
          (Tag 3)
          ~title:"Sync_status"
          sync_status_encoding
          (function Sync_status sync_status -> Some sync_status | _ -> None)
          (fun sync_status -> Sync_status sync_status);
        case
          (Tag 4)
          ~title:"Bootstrap_active_peers"
          (obj2 (req "active" int31) (req "needed" int31))
          (function
            | Bootstrap_active_peers {active; needed} ->
                Some (active, needed)
            | _ ->
                None)
          (fun (active, needed) -> Bootstrap_active_peers {active; needed});
        case
          (Tag 5)
          ~title:"Bootstrap_active_peers_heads_time"
          (obj3
             (req "min_head_time" Time.Protocol.encoding)
             (req "max_head_time" Time.Protocol.encoding)
             (req "most_recent_validation" Time.Protocol.encoding))
          (function
            | Bootstrap_active_peers_heads_time
                {min_head_time; max_head_time; most_recent_validation} ->
                Some (min_head_time, max_head_time, most_recent_validation)
            | _ ->
                None)
          (fun (min_head_time, max_head_time, most_recent_validation) ->
            Bootstrap_active_peers_heads_time
              {min_head_time; max_head_time; most_recent_validation}) ]

  let sync_status_to_string = function
    | Synchronised {is_chain_stuck = false} ->
        "sync"
    | Not_synchronised ->
        "unsync"
    | Synchronised {is_chain_stuck = true} ->
        "stuck"

  let pp ppf = function
    | Processed_block req ->
        Format.fprintf ppf "@[<v 0>" ;
        ( match req.update with
        | Ignored_head ->
            Format.fprintf
              ppf
              "Current head is better than %a (level %ld, timestamp %a, \
               fitness %a), we do not switch@,"
        | Branch_switch ->
            Format.fprintf
              ppf
              "Update current head to %a (level %ld, timestamp %a, fitness \
               %a), changing branch@,"
        | Head_increment ->
            Format.fprintf
              ppf
              "Update current head to %a (level %ld, timestamp %a, fitness \
               %a), same branch@," )
          Request.pp
          req.request
          req.level
          Time.Protocol.pp_hum
          req.timestamp
          Fitness.pp
          req.fitness ;
        Format.fprintf ppf "%a@]" Worker_types.pp_status req.request_status
    | Could_not_switch_testchain err ->
        Format.fprintf
          ppf
          "@[<v 0>Error while switching test chain:@ %a@]"
          (Format.pp_print_list Error_monad.pp)
          err
    | Bootstrapped ->
        Format.fprintf ppf "@[<v 0>Chain is bootstrapped@]"
    | Sync_status ss ->
        Format.fprintf
          ppf
          "@[<v 0>Sync_status: %s@]"
          (sync_status_to_string ss)
    | Bootstrap_active_peers {active; needed} ->
        Format.fprintf
          ppf
          "@[<v 0>Bootstrap peers: active %d needed %d@]"
          active
          needed
    | Bootstrap_active_peers_heads_time
        {min_head_time; max_head_time; most_recent_validation} ->
        Format.fprintf
          ppf
          "@[<v 0>Bootstrap peers: least recent head time stamp %a, \
           most_recent_head_timestamp %a, most recent validation %a@]"
          Time.Protocol.pp_hum
          min_head_time
          Time.Protocol.pp_hum
          max_head_time
          Time.Protocol.pp_hum
          most_recent_validation
end

module Worker_state = struct
  type view = {active_peers : P2p_peer.Id.t list; bootstrapped : bool}

  let encoding =
    let open Data_encoding in
    conv
      (fun {bootstrapped; active_peers} -> (bootstrapped, active_peers))
      (fun (bootstrapped, active_peers) -> {bootstrapped; active_peers})
      (obj2
         (req "bootstrapped" bool)
         (req "active_peers" (list P2p_peer.Id.encoding)))

  let pp ppf {bootstrapped; active_peers} =
    Format.fprintf
      ppf
      "@[<v 0>Network is%s bootstrapped.@,@[<v 2>Active peers:%a@]@]"
      (if bootstrapped then "" else " not yet")
      (fun ppf -> List.iter (Format.fprintf ppf "@,- %a" P2p_peer.Id.pp))
      active_peers
end

module Distributed_db_state = struct
  type table_scheduler = {table_length : int; scheduler_length : int}

  type view = {
    p2p_readers_length : int;
    active_chains_length : int;
    operation_db : table_scheduler;
    operations_db : table_scheduler;
    block_header_db : table_scheduler;
    active_connections_length : int;
    active_peers_length : int;
  }

  let table_scheduler_encoding =
    let open Data_encoding in
    conv
      (fun {table_length; scheduler_length} ->
        (table_length, scheduler_length))
      (fun (table_length, scheduler_length) ->
        {table_length; scheduler_length})
      (obj2 (req "table_length" int31) (req "scheduler_length" int31))

  let encoding =
    let open Data_encoding in
    conv
      (fun { p2p_readers_length;
             active_chains_length;
             operation_db;
             operations_db;
             block_header_db;
             active_connections_length;
             active_peers_length } ->
        ( p2p_readers_length,
          active_chains_length,
          operation_db,
          operations_db,
          block_header_db,
          active_connections_length,
          active_peers_length ))
      (fun ( p2p_readers_length,
             active_chains_length,
             operation_db,
             operations_db,
             block_header_db,
             active_connections_length,
             active_peers_length ) ->
        {
          p2p_readers_length;
          active_chains_length;
          operation_db;
          operations_db;
          block_header_db;
          active_connections_length;
          active_peers_length;
        })
      (obj7
         (req "p2p_readers" int31)
         (req "active_chains" int31)
         (req "operation_db" table_scheduler_encoding)
         (req "operations_db" table_scheduler_encoding)
         (req "block_header_db" table_scheduler_encoding)
         (req "active_connections" int31)
         (req "active_peers" int31))
end
