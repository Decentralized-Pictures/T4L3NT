(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(* The functions below could be put in the Tezt library. *)
let get_save_point ?node client =
  let* json = RPC.get_checkpoint ?node client in
  return JSON.(json |-> "save_point" |> as_int)

let get_caboose ?node client =
  let* json = RPC.get_checkpoint ?node client in
  return JSON.(json |-> "caboose" |> as_int)

let is_connected ?node client ~peer_id =
  let* connections = RPC.get_connections ?node client in
  let open JSON in
  return
  @@ List.exists
       (fun peer -> peer |-> "peer_id" |> as_string = peer_id)
       (connections |> as_list)

let wait_for_unknown_ancestor node =
  let filter json =
    match
      JSON.(json |=> 1 |-> "event" |-> "error" |=> 0 |-> "id" |> as_string_opt)
    with
    | None ->
        (* Not all node_peer_validator.v0 events have an "error" field. *)
        None
    | Some id ->
        if id = "node.peer_validator.unknown_ancestor" then Some () else None
  in
  Node.wait_for
    node
    "node_peer_validator.v0"
    ~where:"[1].event.error[0].id is node.peer_validator.unknown_ancestor"
    filter

(* FIXME: this is not robust since we cannot catch the bootstrapped event precisely. *)
let bootstrapped_event =
  let fulfilled = ref false in
  fun resolver Node.{name; value} ->
    let filter json =
      let json = JSON.(json |=> 1 |-> "event") in
      (* We check is_null first otherwise as_object_opt may aslo returns `Some []` for this case *)
      if JSON.is_null json then false
      else match JSON.as_object_opt json with Some [] -> true | _ -> false
    in
    if name = "node_chain_validator.v0" && filter value then
      if not !fulfilled then (
        fulfilled := true ;
        Lwt.wakeup resolver () )

(* This test replicates part of the flextesa test "command_node_synchronization".
   It checks the synchronization of two nodes depending on their history mode.
   The beginning of the scenario is the following:

   1. Node 1 bakes some blocks and Node 2 catches up with Node 1;

   2. Node 2 is killed;

   3. Node 1 bakes many blocks (longer than a cycle).

   What follows depends on the history mode of Node 1.

   a) In rolling mode, synchronization should fail because Node 1 and Node 2 have
   no common ancestor. We check that the caboose for Node 1 is indeed higher than
   when Node 2 was killed.

   b) Otherwise, we check that both nodes synchronize. In full mode, we also check
   that the save_point is higher than when Node 2 was killed. *)
let check_bootstrap_with_history_modes hmode1 hmode2 =
  (* Number of calls to [tezos-client bake for] once the protocol is activated,
     before we kill [node_2]. *)
  let bakes_before_kill = 9 in
  (* Number of calls to [tezos-client bake for] while [node_2] is not
     running. This number is high enough so that it is bigger than the
     Last-Allowed-Fork-Level *)
  let bakes_during_kill = 100 in
  let hmode1s = Node.show_history_mode hmode1 in
  let hmode2s = Node.show_history_mode hmode2 in
  Test.register
    ~__FILE__
    ~title:(Format.sprintf "node synchronization (%s / %s)" hmode1s hmode2s)
    ~tags:
      [ "bootstrap";
        "node";
        "sync";
        "activate";
        "bake";
        "primary_" ^ hmode1s;
        "secondary_" ^ hmode2s ]
  @@ fun () ->
  (* Initialize nodes and client. *)
  let* node_1 =
    Node.init [Synchronisation_threshold 0; Connections 1; History_mode hmode1]
  and* node_2 = Node.init [Connections 1; History_mode hmode2] in
  let* node2_identity = Node.wait_for_identity node_2 in
  let* client = Client.init ~node:node_1 () in
  (* Connect node 1 to node 2 and start baking. *)
  let* () = Client.Admin.connect_address client ~peer:node_2 in
  let* () = Client.activate_protocol client in
  Log.info "Activated protocol." ;
  let* () = repeat bakes_before_kill (fun () -> Client.bake_for client) in
  let* _ = Node.wait_for_level node_1 (bakes_before_kill + 1)
  and* _ = Node.wait_for_level node_2 (bakes_before_kill + 1) in
  Log.info "Both nodes are at level %d." (bakes_before_kill + 1) ;
  (* Kill node 2 and continue baking without it. *)
  let* () = Node.terminate node_2 in
  let* () = repeat bakes_during_kill (fun () -> Client.bake_for client) in
  (* Restart node 2 and let it catch up. *)
  Log.info "Baked %d times with node_2 down, restart node_2." bakes_during_kill ;
  let* () = Node.run node_2 [Synchronisation_threshold 1; Connections 1] in
  let* _ = Node.wait_for_ready node_2 in
  let final_level = 1 + bakes_before_kill + bakes_during_kill in
  let* _ = Node.wait_for_level node_1 final_level in
  (* Register the unknown ancestor event before connecting node 2 to node 1
     to ensure that we don't miss it because of a race condition. *)
  let node_2_catched_up =
    if hmode1 <> Rolling then
      let* _ = Node.wait_for_level node_2 final_level in
      unit
    else
      (* In rolling mode, node 2 cannot catch up. We get an unknown ancestor event instead. *)
      wait_for_unknown_ancestor node_2
  in
  let* () = Client.Admin.connect_address client ~peer:node_2 in
  let* () = node_2_catched_up in
  (* Node 2 has caught up, check its checkpoint level depending on history mode. *)
  let* () =
    match hmode1 with
    | Full ->
        let* save_point = get_save_point ~node:node_1 client in
        if save_point <= bakes_before_kill then
          Test.fail
            "save point level (%d) is lower or equal to the starting level (%d)"
            save_point
            bakes_before_kill ;
        return ()
    | Rolling ->
        let* caboose = get_caboose ~node:node_1 client in
        if caboose <= bakes_before_kill then
          Test.fail
            "caboose level (%d) is lower or equal to the starting level (%d)"
            caboose
            bakes_before_kill ;
        return ()
    | _ ->
        return ()
  in
  (* Check whether the nodes are still connected. *)
  if hmode1 <> Rolling then
    let* b = is_connected client ~peer_id:node2_identity in
    if not b then Test.fail "expected the two nodes to be connected" else unit
  else
    let* b = is_connected client ~peer_id:node2_identity in
    if b then Test.fail "expected the two nodes NOT to be connected" else unit

let check_rpc_force_bootstrapped () =
  Test.register
    ~__FILE__
    ~title:(sf "RPC force bootstrapped")
    ~tags:["rpc"; "bootstrapped"]
  @@ fun () ->
  Log.info "Start a node." ;
  let* node = Node.init [Synchronisation_threshold 255] in
  let* client = Client.init ~node () in
  let (bootstrapped_promise, bootstrapped_resolver) = Lwt.task () in
  Node.on_event node (bootstrapped_event bootstrapped_resolver) ;
  Log.info "Force the node to be bootstrapped." ;
  let* _ = RPC.force_bootstrapped client in
  Log.info "Waiting for the node to be bootstrapped." ;
  let* () = bootstrapped_promise in
  unit

let register () =
  check_bootstrap_with_history_modes Archive Archive ;
  check_bootstrap_with_history_modes Archive Full ;
  check_bootstrap_with_history_modes Archive Rolling ;
  check_bootstrap_with_history_modes Full Archive ;
  check_bootstrap_with_history_modes Full Full ;
  check_bootstrap_with_history_modes Full Rolling ;
  check_bootstrap_with_history_modes Rolling Archive ;
  check_bootstrap_with_history_modes Rolling Rolling ;
  check_bootstrap_with_history_modes Rolling Full ;
  check_rpc_force_bootstrapped ()
