open Flextesa
open Internal_pervasives

let default_attempts = 5

let starting_level = 10

let number_of_lonely_bakes = 100

let run state ~node_exec ~client_exec ~primary_history_mode
    ~secondary_history_mode ~should_synch () =
  Helpers.clear_root state
  >>= fun () ->
  Interactive_test.Pauser.generic
    state
    EF.[af "Ready to start"; af "Root path deleted."]
  >>= fun () ->
  let block_interval = 1 in
  let default_protocol = Tezos_protocol.default () in
  let baker_list = default_protocol.bootstrap_accounts in
  let protocol =
    {
      default_protocol with
      timestamp_delay = Some (-3600);
      expected_pow = 0;
      time_between_blocks = [block_interval; 0];
    }
  in
  let primary_node =
    Tezos_node.make
      ~protocol
      ~exec:node_exec
      "primary_node"
      ~history_mode:primary_history_mode
      ~expected_connections:2
      ~rpc_port:15001
      ~p2p_port:15002
      [15004]
  in
  let secondary_node =
    Tezos_node.make
      ~protocol
      ~exec:node_exec
      ~history_mode:secondary_history_mode
      "secondary_node"
      ~expected_connections:2
      ~rpc_port:15003
      ~p2p_port:15004
      [15002]
  in
  let all_nodes = [primary_node; secondary_node] in
  Helpers.dump_connections state all_nodes
  >>= fun () ->
  Interactive_test.Pauser.add_commands
    state
    Interactive_test.Commands.(
      all_defaults state ~nodes:all_nodes
      @ [secret_keys state ~protocol; Log_recorder.Operations.show_all state]) ;
  let primary_client = Tezos_client.of_node ~exec:client_exec primary_node in
  let pp_hm = function
    | Some `Archive ->
        "archive"
    | Some `Full ->
        "full"
    | Some `Rolling ->
        "rolling"
    | None ->
        "full"
  in
  Interactive_test.Pauser.generic
    state
    EF.
      [ af "Starting primary node in %s" (pp_hm primary_node.history_mode);
        af "Starting secondary node in %s" (pp_hm secondary_node.history_mode);
        af "Expecting nodes to synch after lonely baking run: %b" should_synch
      ]
  >>= fun () ->
  Test_scenario.Network.(start_up state ~client_exec (make all_nodes))
  >>= fun _ ->
  let (baker_account, _) = List.hd_exn baker_list in
  let baker =
    Tezos_client.Keyed.make
      primary_client
      ~key_name:(Tezos_protocol.Account.name baker_account)
      ~secret_key:(Tezos_protocol.Account.private_key baker_account)
  in
  Tezos_client.Keyed.initialize state baker
  >>= fun _ ->
  Loop.n_times (starting_level - 1) (fun i ->
      Tezos_client.Keyed.bake
        state
        baker
        (sprintf "bakery run: [%d/%d]" i starting_level))
  >>= fun () ->
  Test_scenario.Queries.wait_for_all_levels_to_be
    state
    ~attempts:default_attempts
    ~seconds:8.
    all_nodes
    (`Equal_to starting_level)
  >>= fun () ->
  Helpers.kill_node state secondary_node
  >>= fun () ->
  Loop.n_times number_of_lonely_bakes (fun i ->
      Tezos_client.Keyed.bake
        state
        baker
        (sprintf "lonely bakery run: [%d/%d]" i number_of_lonely_bakes))
  >>= fun () ->
  Tezos_client.rpc
    state
    ~client:primary_client
    `Get
    ~path:"/chains/main/checkpoint"
  >>= fun json ->
  ( match primary_history_mode with
  | `Archive ->
      return ()
  | `Rolling ->
      let caboose_level = Jqo.(get_int @@ field ~k:"caboose" json) in
      if not (caboose_level > starting_level) then
        fail
          (`Scenario_error
            "Caboose level is lower or equal to the starting level")
      else return ()
  | `Full ->
      let save_point_level = Jqo.(get_int @@ field ~k:"save_point" json) in
      if not (save_point_level > starting_level) then
        fail
          (`Scenario_error
            "Save point level is lower or equal to the starting level")
      else return () )
  >>= fun () ->
  Helpers.restart_node ~client_exec state secondary_node
  >>= fun () ->
  Lwt.bind
    (Test_scenario.Queries.wait_for_all_levels_to_be
       state
       ~attempts:default_attempts
       ~seconds:8.
       all_nodes
       (`Equal_to (starting_level + number_of_lonely_bakes)))
    (function
      | {result = Ok _; _} when should_synch ->
          return true
      | {result = Error (`Waiting_for (_, `Time_out)); _} when not should_synch
        ->
          return false
      | _ ->
          fail
            (`Scenario_error
              "Unexpected answer when waiting for nodes synchronization"))
  >>= fun are_synch ->
  ( match (should_synch, are_synch) with
  | (false, true) ->
      fail (`Scenario_error "Nodes are not expected to be synchronized")
  | (true, false) ->
      fail (`Scenario_error "Nodes are expected to be synchronized")
  | _ ->
      return () )
  >>= fun () ->
  let identity_file = Tezos_node.identity_file state primary_node in
  System.read_file state identity_file
  >>= fun identity_contents ->
  let identity_json = Ezjsonm.from_string identity_contents in
  let primary_node_peer_id =
    Ezjsonm.value_to_string @@ Jqo.field ~k:"peer_id" identity_json
  in
  let secondary_client =
    Tezos_client.of_node ~exec:client_exec secondary_node
  in
  Tezos_client.rpc
    state
    ~client:secondary_client
    `Get
    ~path:"/network/connections/"
  >>= fun connections_json ->
  let are_nodes_connected =
    Jqo.list_exists
      ~f:(fun connection ->
        let peer_id =
          Ezjsonm.value_to_string @@ Jqo.field ~k:"peer_id" connection
        in
        String.equal primary_node_peer_id peer_id)
      connections_json
  in
  ( match (should_synch, are_nodes_connected) with
  | (true, false) ->
      fail (`Scenario_error "Expecting nodes to be connected")
  | (false, true) ->
      fail (`Scenario_error "Expecting nodes to not be connected")
  | _ ->
      return () )
  >>= fun () ->
  Stdlib.Scanf.sscanf primary_node_peer_id "%S" (fun primary_node_peer_id ->
      Tezos_client.rpc
        state
        ~client:secondary_client
        `Get
        ~path:(sprintf "/network/peers/%s/banned" primary_node_peer_id))
  >>= fun json ->
  let is_banned = Ezjsonm.get_bool json in
  if is_banned then fail (`Scenario_error "Node should not be banned")
  else return ()

let cmd () =
  let open Cmdliner in
  let open Term in
  let pp_error = Test_command_line.Common_errors.pp in
  let hm_arg =
    Arg.enum [("archive", `Archive); ("full", `Full); ("rolling", `Rolling)]
  in
  let base_state =
    Test_command_line.Command_making_state.make
      ~application_name:"Flextesa"
      ~command_name:"node-synchronization"
      ()
  in
  Test_command_line.Run_command.make
    ~pp_error
    ( pure
        (fun node_exec
             client_exec
             primary_history_mode
             secondary_history_mode
             should_synch
             state
             ->
          ( state,
            Interactive_test.Pauser.run_test
              ~pp_error
              state
              (run
                 state
                 ~node_exec
                 ~client_exec
                 ~primary_history_mode
                 ~secondary_history_mode
                 ~should_synch) ))
    $ Tezos_executable.cli_term base_state `Node "tezos"
    $ Tezos_executable.cli_term base_state `Client "tezos"
    $ Arg.(
        value
        & opt hm_arg `Full
        & info
            ["primary-history-mode"]
            ~docv:"STRING"
            ~doc:
              (sprintf
                 "History mode of the primary node. This one lonely bakes %d \
                  blocks."
                 number_of_lonely_bakes))
    $ Arg.(
        value
        & opt hm_arg `Full
        & info
            ["secondary-history-mode"]
            ~docv:"STRING"
            ~doc:
              (sprintf
                 "History mode of the secondary node. This one tries to \
                  bootstrap after the primary node lonely bakes %d blocks."
                 number_of_lonely_bakes))
    $ Arg.(
        value & opt bool true
        & info
            ["should-synch"]
            ~docv:"BOOL"
            ~doc:
              "Specify if the nodes should be synchronized after the lonely \
               baking run.")
    $ Test_command_line.cli_state ~name:"history_mode_synchronization" () )
    (let doc =
       sprintf
         "Synchronization of two sandboxed nodes after a lonely baking run of \
          %d blocks."
         number_of_lonely_bakes
     in
     let man : Manpage.block list =
       [ `S "NODE SYNCHRONIZATION";
         `P
           (sprintf
              "This command builds a network of two interconnected nodes N1 \
               and N2. The test first waits for synchronization of both nodes \
               after N1 bakes %d blocks, it then kills N2, makes N1 lonely \
               bake %d blocks and restarts N2. Finally, the test verifies if \
               N2 is bootstrapped, and that N1 is not considered as a banned \
               peer by N2. Depending on the specified history modes, N1 may \
               or not bootstrap N2, the expected result is provided by the \
               'should-synch' command argument."
              starting_level
              number_of_lonely_bakes) ]
     in
     info ~man ~doc "node-synchronization")
