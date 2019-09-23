open Flextesa
open Internal_pervasives
open Console

let failf fmt = ksprintf (fun s -> fail (`Scenario_error s)) fmt

let wait_for_voting_period ?level_within_period state ~client ~attempts period
    =
  let period_name = Tezos_protocol.Voting_period.to_string period in
  let message =
    sprintf
      "Waiting for voting period: `%s`%s"
      period_name
      (Option.value_map
         level_within_period
         ~default:""
         ~f:(sprintf " (and level-within-period ≥ %d)"))
  in
  Console.say state EF.(wf "%s" message)
  >>= fun () ->
  Helpers.wait_for state ~attempts ~seconds:10. (fun nth ->
      Asynchronous_result.map_option level_within_period ~f:(fun lvl ->
          Tezos_client.rpc
            state
            ~client
            `Get
            ~path:"/chains/main/blocks/head/metadata"
          >>= fun json ->
          try
            let voting_period_position =
              Jqo.field ~k:"level" json
              |> Jqo.field ~k:"voting_period_position"
              |> Jqo.get_int
            in
            return (voting_period_position >= lvl)
          with e ->
            failf
              "Cannot get level.voting_period_position: %s"
              (Printexc.to_string e))
      >>= fun lvl_ok ->
      Tezos_client.rpc
        state
        ~client
        `Get
        ~path:"/chains/main/blocks/head/votes/current_period_kind"
      >>= function
      | `String p when p = period_name && (lvl_ok = None || lvl_ok = Some true)
        ->
          return (`Done (nth - 1))
      | other ->
          Tezos_client.successful_client_cmd
            state
            ~client
            ["show"; "voting"; "period"]
          >>= fun res ->
          Console.say
            state
            EF.(
              desc_list
                (wf "Voting period:")
                [markdown_verbatim (String.concat ~sep:"\n" res#out)])
          >>= fun () -> return (`Not_done message))

let run state ~protocol ~size ~base_port ~no_daemons_for ?external_peer_ports
    ?generate_kiln_config ~node_exec ~client_exec ~first_baker_exec
    ~first_endorser_exec ~first_accuser_exec ~second_baker_exec
    ~second_endorser_exec ~second_accuser_exec ~admin_exec ~new_protocol_path
    ~extra_dummy_proposals_batch_size ~extra_dummy_proposals_batch_levels
    ~waiting_attempts test_variant () =
  Helpers.System_dependencies.precheck
    state
    `Or_fail
    ~protocol_paths:[new_protocol_path]
    ~executables:
      [ node_exec;
        client_exec;
        first_baker_exec;
        first_endorser_exec;
        first_accuser_exec;
        second_baker_exec;
        second_endorser_exec;
        second_accuser_exec ]
  >>= fun () ->
  Test_scenario.network_with_protocol
    ?external_peer_ports
    ~protocol
    ~size
    ~base_port
    state
    ~node_exec
    ~client_exec
  >>= fun (nodes, protocol) ->
  Tezos_client.rpc
    state
    ~client:(Tezos_client.of_node (List.hd_exn nodes) ~exec:client_exec)
    `Get
    ~path:"/chains/main/chain_id"
  >>= fun chain_id_json ->
  let network_id =
    match chain_id_json with `String s -> s | _ -> assert false
  in
  let accusers =
    List.concat_map nodes ~f:(fun node ->
        let client = Tezos_client.of_node node ~exec:client_exec in
        [ Tezos_daemon.accuser_of_node
            ~exec:first_accuser_exec
            ~client
            node
            ~name_tag:"first";
          Tezos_daemon.accuser_of_node
            ~exec:second_accuser_exec
            ~client
            node
            ~name_tag:"second" ])
  in
  List_sequential.iter accusers ~f:(fun acc ->
      Running_processes.start state (Tezos_daemon.process acc ~state)
      >>= fun {process; lwt} -> return ())
  >>= fun () ->
  let keys_and_daemons =
    let pick_a_node_and_client idx =
      match List.nth nodes ((1 + idx) mod List.length nodes) with
      | Some node ->
          (node, Tezos_client.of_node node ~exec:client_exec)
      | None ->
          assert false
    in
    Tezos_protocol.bootstrap_accounts protocol
    |> List.filter_mapi ~f:(fun idx acc ->
           let (node, client) = pick_a_node_and_client idx in
           let key = Tezos_protocol.Account.name acc in
           if List.mem ~equal:String.equal no_daemons_for key then None
           else
             Some
               ( acc,
                 client,
                 [ Tezos_daemon.baker_of_node
                     ~exec:first_baker_exec
                     ~client
                     node
                     ~key
                     ~name_tag:"first";
                   Tezos_daemon.baker_of_node
                     ~exec:second_baker_exec
                     ~client
                     ~name_tag:"second"
                     node
                     ~key;
                   Tezos_daemon.endorser_of_node
                     ~exec:first_endorser_exec
                     ~name_tag:"first"
                     ~client
                     node
                     ~key;
                   Tezos_daemon.endorser_of_node
                     ~exec:second_endorser_exec
                     ~name_tag:"second"
                     ~client
                     node
                     ~key ] ))
  in
  List_sequential.iter keys_and_daemons ~f:(fun (acc, client, daemons) ->
      Tezos_client.bootstrapped ~state client
      >>= fun () ->
      let (key, priv) = Tezos_protocol.Account.(name acc, private_key acc) in
      Tezos_client.import_secret_key ~state client key priv
      >>= fun () ->
      say
        state
        EF.(
          desc_list
            (haf "Registration-as-delegate:")
            [ desc (af "Client:") (af "%S" client.Tezos_client.id);
              desc (af "Key:") (af "%S" key) ])
      >>= fun () ->
      Tezos_client.register_as_delegate ~state client key
      >>= fun () ->
      say
        state
        EF.(
          desc_list
            (haf "Starting daemons:")
            [ desc (af "Client:") (af "%S" client.Tezos_client.id);
              desc (af "Key:") (af "%S" key) ])
      >>= fun () ->
      List_sequential.iter daemons ~f:(fun daemon ->
          Running_processes.start state (Tezos_daemon.process daemon ~state)
          >>= fun {process; lwt} -> return ()))
  >>= fun () ->
  let client_0 =
    Tezos_client.of_node (List.nth_exn nodes 0) ~exec:client_exec
  in
  let make_admin = Tezos_admin_client.of_client ~exec:admin_exec in
  Interactive_test.Pauser.add_commands
    state
    Interactive_test.Commands.(
      all_defaults state ~nodes
      @ [ secret_keys state ~protocol;
          arbitrary_command_on_clients
            state
            ~command_names:["all-clients"; "cc"]
            ~make_admin
            ~clients:
              (List.map nodes ~f:(Tezos_client.of_node ~exec:client_exec));
          arbitrary_command_on_clients
            state
            ~command_names:["c0"; "client-0"]
            ~make_admin
            ~clients:[client_0] ]) ;
  (* 
     For each node we try to see if the node knows about the protocol,
     if it does we're good, if not we inject it.
     This is because `inject` fails when the node already knows a protocol.
  *)
  List.fold ~init:(return None) nodes ~f:(fun prevm nod ->
      prevm
      >>= fun _ ->
      System.read_file state (new_protocol_path // "TEZOS_PROTOCOL")
      >>= fun protocol ->
      ( try return Jqo.(of_string protocol |> field ~k:"hash" |> get_string)
        with e ->
          failf
            "Cannot parse %s/TEZOS_PROTOCOL: %s"
            new_protocol_path
            (Printexc.to_string e) )
      >>= fun hash ->
      let client = Tezos_client.of_node ~exec:client_exec nod in
      Tezos_client.rpc state ~client `Get ~path:"/protocols"
      >>= fun protocols ->
      match protocols with
      | `A l
        when List.exists l ~f:(function `String h -> h = hash | _ -> false) ->
          Console.say
            state
            EF.(
              wf
                "Node `%s` already knows protocol `%s`."
                nod.Tezos_node.id
                hash)
          >>= fun () -> return (Some hash)
      | _ ->
          let admin = make_admin client in
          Tezos_admin_client.inject_protocol
            admin
            state
            ~path:new_protocol_path
          >>= fun (_, new_protocol_hash) ->
          ( if new_protocol_hash = hash then
            Console.say
              state
              EF.(
                wf
                  "Injected protocol `%s` in `%s`"
                  new_protocol_hash
                  nod.Tezos_node.id)
          else
            failf
              "Injecting protocol %s failed (≠ %s)"
              new_protocol_hash
              hash )
          >>= fun () -> return (Some hash))
  >>= fun prot_opt ->
  ( match prot_opt with
  | Some s ->
      return s
  | None ->
      failf "protocol injection problem?" )
  >>= fun new_protocol_hash ->
  Asynchronous_result.map_option generate_kiln_config ~f:(fun kiln_config ->
      Kiln.Configuration_directory.generate
        state
        kiln_config
        ~peers:(List.map nodes ~f:(fun {Tezos_node.p2p_port; _} -> p2p_port))
        ~sandbox_json:(Tezos_protocol.sandbox_path ~config:state protocol)
        ~nodes:
          (List.map nodes ~f:(fun {Tezos_node.rpc_port; _} ->
               sprintf "http://localhost:%d" rpc_port))
        ~bakers:
          (List.map
             protocol.Tezos_protocol.bootstrap_accounts
             ~f:(fun (account, _) ->
               Tezos_protocol.Account.(name account, pubkey_hash account)))
        ~network_string:network_id
        ~node_exec
        ~client_exec
        ~protocol_execs:
          [ ( protocol.Tezos_protocol.hash,
              first_baker_exec,
              first_endorser_exec );
            (new_protocol_hash, second_baker_exec, second_endorser_exec) ]
      >>= fun () ->
      let msg =
        EF.(
          desc
            (shout "Kiln-Configuration DONE")
            (wf "Kiln was configured at `%s`" kiln_config.path))
      in
      Console.say state msg >>= fun () -> return msg)
  >>= fun kiln_info_opt ->
  Test_scenario.Queries.wait_for_all_levels_to_be
    state
    ~attempts:waiting_attempts
    ~seconds:10.
    nodes
    (* TODO: wait for /chains/main/blocks/head/votes/listings to be
       non-empty instead of counting blocks *)
    (`At_least protocol.Tezos_protocol.blocks_per_voting_period)
  >>= fun () ->
  Interactive_test.Pauser.generic
    state
    EF.
      [ wf "Test becomes interactive.";
        Option.value kiln_info_opt ~default:(wf "");
        wf "Please type `q` to start a voting/protocol-change period." ]
    ~force:true
  >>= fun () ->
  wait_for_voting_period
    state
    ~client:client_0
    ~attempts:waiting_attempts
    `Proposal
    ~level_within_period:3
  >>= fun _ ->
  let submit_prop acc client hash =
    Tezos_client.successful_client_cmd
      state
      ~client
      [ "submit";
        "proposals";
        "for";
        Tezos_protocol.Account.name acc;
        hash;
        "--force" ]
    >>= fun _ ->
    Console.sayf
      state
      Fmt.(
        fun ppf () ->
          pf ppf "%s voted for %s" (Tezos_protocol.Account.name acc) hash)
  in
  List_sequential.iter keys_and_daemons ~f:(fun (acc, client, _) ->
      submit_prop acc client new_protocol_hash)
  >>= fun () ->
  let make_dummy_protocol_hashes t tag =
    List.map
      (List.init extra_dummy_proposals_batch_size ~f:(fun s ->
           sprintf "proto-%s-%d" tag s))
      ~f:(fun s ->
        (t, Tezos_crypto.Protocol_hash.(hash_string [s] |> to_b58check)))
  in
  let extra_dummy_protocols =
    List.bind extra_dummy_proposals_batch_levels ~f:(fun l ->
        make_dummy_protocol_hashes l (sprintf "%d" l))
  in
  Console.say
    state
    EF.(
      wf
        "Going to also vote for %s"
        (String.concat ~sep:", " (List.map extra_dummy_protocols ~f:snd)))
  >>= fun () ->
  List_sequential.iteri
    extra_dummy_protocols
    ~f:(fun nth (level, proto_hash) ->
      match List.nth keys_and_daemons (nth / 19) with
      | None ->
          failf "Too many dummy protocols Vs available voting power (%d)" nth
      | Some (acc, client, _) ->
          wait_for_voting_period
            state
            ~client:client_0
            ~attempts:waiting_attempts
            `Proposal
            ~level_within_period:level
          >>= fun _ -> submit_prop acc client proto_hash)
  >>= fun () ->
  wait_for_voting_period
    state
    ~client:client_0
    ~attempts:waiting_attempts
    `Testing_vote
  >>= fun _ ->
  List_sequential.iter keys_and_daemons ~f:(fun (acc, client, _) ->
      Tezos_client.successful_client_cmd
        state
        ~client
        [ "submit";
          "ballot";
          "for";
          Tezos_protocol.Account.name acc;
          new_protocol_hash;
          "yea" ]
      >>= fun _ ->
      Console.sayf
        state
        Fmt.(
          fun ppf () ->
            pf
              ppf
              "%s voted Yea to test %s"
              (Tezos_protocol.Account.name acc)
              new_protocol_hash))
  >>= fun () ->
  wait_for_voting_period
    state
    ~client:client_0
    ~attempts:waiting_attempts
    `Promotion_vote
  >>= fun _ ->
  let protocol_switch_will_happen =
    match test_variant with
    | `Full_upgrade ->
        true
    | `Nay_for_promotion ->
        false
  in
  List_sequential.iter keys_and_daemons ~f:(fun (acc, client, _) ->
      Tezos_client.successful_client_cmd
        state
        ~client
        [ "submit";
          "ballot";
          "for";
          Tezos_protocol.Account.name acc;
          new_protocol_hash;
          (if protocol_switch_will_happen then "yea" else "nay") ]
      >>= fun _ ->
      Console.sayf
        state
        Fmt.(
          fun ppf () ->
            pf
              ppf
              "%s voted Yea to promote %s"
              (Tezos_protocol.Account.name acc)
              new_protocol_hash))
  >>= fun () ->
  wait_for_voting_period
    state
    ~client:client_0
    ~attempts:waiting_attempts
    `Proposal
  >>= fun _ ->
  Tezos_client.successful_client_cmd
    state
    ~client:client_0
    ["show"; "voting"; "period"]
  >>= fun res ->
  let protocol_to_wait_for =
    if protocol_switch_will_happen then new_protocol_hash
    else protocol.Tezos_protocol.hash
  in
  Helpers.wait_for state ~attempts:waiting_attempts ~seconds:4. (fun _ ->
      Console.say state EF.(wf "Checking actual protocol transition")
      >>= fun () ->
      Tezos_client.rpc
        state
        ~client:client_0
        `Get
        ~path:"/chains/main/blocks/head/metadata"
      >>= fun json ->
      ( try Jqo.field ~k:"protocol" json |> Jqo.get_string |> return
        with e -> failf "Cannot parse metadata: %s" (Printexc.to_string e) )
      >>= fun proto_hash ->
      if proto_hash <> protocol_to_wait_for then
        return
          (`Not_done
            (sprintf
               "Protocol not done: %s Vs %s"
               proto_hash
               protocol_to_wait_for))
      else return (`Done ()))
  >>= fun () ->
  Interactive_test.Pauser.generic
    state
    EF.
      [ wf
          "Test finished, protocol is now %s, things should keep baking."
          protocol_to_wait_for;
        markdown_verbatim (String.concat ~sep:"\n" res#out) ]
    ~force:true

let cmd ~pp_error () =
  let open Cmdliner in
  let open Term in
  let variants =
    [ ( "full-upgrade",
        `Full_upgrade,
        "Go through the whole voting process and do the protocol change." );
      ( "nay-for-promotion",
        `Nay_for_promotion,
        "Go through the whole voting process but vote Nay at the last period \
         and hence stay on the same protocol." ) ]
  in
  Test_command_line.Run_command.make
    ~pp_error
    ( pure
        (fun size
             base_port
             (`Attempts waiting_attempts)
             (`External_peers external_peer_ports)
             (`No_daemons_for no_daemons_for)
             protocol
             node_exec
             client_exec
             admin_exec
             first_baker_exec
             first_endorser_exec
             first_accuser_exec
             second_baker_exec
             second_endorser_exec
             second_accuser_exec
             (`Protocol_path new_protocol_path)
             (`Extra_dummy_proposals_batch_size
               extra_dummy_proposals_batch_size)
             (`Extra_dummy_proposals_batch_levels
               extra_dummy_proposals_batch_levels)
             generate_kiln_config
             test_variant
             state
             ->
          let actual_test =
            run
              state
              ~size
              ~base_port
              ~protocol
              ~node_exec
              ~client_exec
              ~first_baker_exec
              ~first_endorser_exec
              ~first_accuser_exec
              ~second_baker_exec
              ~second_endorser_exec
              ~second_accuser_exec
              ~admin_exec
              ?generate_kiln_config
              ~external_peer_ports
              ~no_daemons_for
              ~new_protocol_path
              test_variant
              ~waiting_attempts
              ~extra_dummy_proposals_batch_size
              ~extra_dummy_proposals_batch_levels
          in
          (state, Interactive_test.Pauser.run_test ~pp_error state actual_test))
    $ Arg.(
        value & opt int 5
        & info ["size"; "S"] ~doc:"Set the size of the network.")
    $ Arg.(
        value & opt int 20_000
        & info ["base-port"; "P"] ~doc:"Base port number to build upon.")
    $ Arg.(
        pure (fun n -> `Attempts n)
        $ value
            (opt
               int
               60
               (info
                  ["waiting-attempts"]
                  ~doc:
                    "Number of attempts done while waiting for voting periods")))
    $ Arg.(
        pure (fun l -> `External_peers l)
        $ value
            (opt_all
               int
               []
               (info
                  ["add-external-peer-port"]
                  ~docv:"PORT-NUMBER"
                  ~doc:"Add $(docv) to the peers of the network nodes.")))
    $ Arg.(
        pure (fun l -> `No_daemons_for l)
        $ value
            (opt_all
               string
               []
               (info
                  ["no-daemons-for"]
                  ~docv:"ACCOUNT-NAME"
                  ~doc:"Do not start daemons for $(docv).")))
    $ Tezos_protocol.cli_term ()
    $ Tezos_executable.cli_term `Node "tezos"
    $ Tezos_executable.cli_term `Client "tezos"
    $ Tezos_executable.cli_term `Admin "tezos"
    $ Tezos_executable.cli_term `Baker "first"
    $ Tezos_executable.cli_term `Endorser "first"
    $ Tezos_executable.cli_term `Accuser "first"
    $ Tezos_executable.cli_term `Baker "second"
    $ Tezos_executable.cli_term `Endorser "second"
    $ Tezos_executable.cli_term `Accuser "second"
    $ Arg.(
        pure (fun p -> `Protocol_path p)
        $ required
            (pos
               0
               (some string)
               None
               (info
                  []
                  ~doc:"The protocol to inject and vote on."
                  ~docv:"PROTOCOL-PATH")))
    $ Arg.(
        pure (fun l -> `Extra_dummy_proposals_batch_size l)
        $ value
            (opt
               int
               0
               (info
                  ["extra-dummy-proposals-batch-size"]
                  ~docv:"NUMBER"
                  ~doc:"Submit $(docv) extra proposals per batch.")))
    $ Arg.(
        pure (fun x -> `Extra_dummy_proposals_batch_levels x)
        $ value
            (opt
               (list ~sep:',' int)
               []
               (info
                  ["extra-dummy-proposals-batch-levels"]
                  ~docv:"NUMBER"
                  ~doc:
                    "Set the levels within the proposal period where batches \
                     of extra proposals appear, e.g. `3,5,7`.")))
    $ Kiln.Configuration_directory.cli_term ()
    $ Arg.(
        let doc =
          sprintf
            "Which variant of the test to run (one of {%s})"
            ( List.map ~f:(fun (n, _, _) -> n) variants
            |> String.concat ~sep:", " )
        in
        value
          (opt
             (enum (List.map variants ~f:(fun (n, v, _) -> (n, v))))
             `Full_upgrade
             (info ["test-variant"] ~doc)))
    $ Test_command_line.cli_state ~name:"daemons-upgrade" () )
    (let doc =
       "Vote and Protocol-upgrade with bakers, endorsers, and accusers."
     in
     let man : Manpage.block list =
       [ `S "DAEMONS-UPGRADE TEST";
         `P
           "This test builds and runs a sandbox network to do a full voting \
            round followed by a protocol change while all the daemons.";
         `P
           (sprintf
              "There are for now %d variants (see option `--test-variant`):"
              (List.length variants));
         `Blocks
           (List.concat_map variants ~f:(fun (n, _, desc) ->
                [`Noblank; `P (sprintf "* `%s`: %s" n desc)]));
         `P "The test is interactive-only:";
         `Blocks
           (List.concat_mapi
              ~f:(fun i s -> [`Noblank; `P (sprintf "%d) %s" (i + 1) s)])
              [ "It starts a sandbox assuming the protocol of the `--first-*` \
                 executables (use the `--protocol-hash` option to make sure \
                 it matches).";
                "An interactive pause is done to let the user play with the \
                 `first` protocol.";
                "Once the user quits the prompt (`q` or `quit` command), a \
                 full voting round happens with a single proposal: the one at \
                 `PROTOCOL-PATH` (which should be the one understood by the \
                 `--second-*` executables).";
                "Once the potential protocol switch has happened (and been \
                 verified), the test re-enters an interactive prompt to let \
                 the user play with the protocol (the first or second one, \
                 depending on the `--test-variant` option)." ]) ]
     in
     info "daemons-upgrade" ~man ~doc)
