(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(* Testing
   -------
   Component:    Data-availability layer
   Invocation:   dune exec tezt/tests/main.exe -- --file dal.ml
   Subject: Integration tests related to the data-availability layer
*)

let hooks = Tezos_regression.hooks

(* DAL/FIXME: https://gitlab.com/tezos/tezos/-/issues/3173
   The functions below are duplicated from sc_rollup.ml.
   They should be moved to a common submodule. *)
let make_int_parameter name = function
  | None -> []
  | Some value -> [(name, `Int value)]

let make_bool_parameter name = function
  | None -> []
  | Some value -> [(name, `Bool value)]

let test ~__FILE__ ?(tags = []) title f =
  let tags = "dal" :: tags in
  Protocol.register_test ~__FILE__ ~title ~tags f

let regression_test ~__FILE__ ?(tags = []) title f =
  let tags = "dal" :: tags in
  Protocol.register_regression_test ~__FILE__ ~title ~tags f

let dal_enable_param dal_enable =
  make_bool_parameter ["dal_parametric"; "feature_enable"] dal_enable

let setup ?commitment_period ?challenge_window ?dal_enable f ~protocol =
  let parameters =
    make_int_parameter
      ["sc_rollup_commitment_period_in_blocks"]
      commitment_period
    @ make_int_parameter
        ["sc_rollup_challenge_window_in_blocks"]
        challenge_window
    (* this will produce the empty list if dal_enable is not passed to the function invocation,
       hence the value from the protocol constants will be used. *)
    @ dal_enable_param dal_enable
    @ [(["sc_rollup_enable"], `Bool true)]
  in
  let base = Either.right (protocol, None) in
  let* parameter_file = Protocol.write_parameter_file ~base parameters in
  let nodes_args =
    Node.
      [
        Synchronisation_threshold 0; History_mode (Full None); No_bootstrap_peers;
      ]
  in
  let* client = Client.init_mockup ~parameter_file ~protocol () in
  let* parameters = Rollup.Dal.Parameters.from_client client in
  let cryptobox = Rollup.Dal.make parameters in
  let node = Node.create nodes_args in
  let* () = Node.config_init node [] in
  Node.Config_file.update node (fun json ->
      let value =
        JSON.annotate
          ~origin:"dal_initialisation"
          (`O
            [
              ("srs_size", `Float (float_of_int parameters.slot_size));
              ("activated", `Bool true);
            ])
      in
      let json = JSON.put ("dal", value) json in
      json) ;
  let* () = Node.run node [] in
  let* () = Node.wait_for_ready node in
  let* client = Client.init ~endpoint:(Node node) () in
  let* () =
    Client.activate_protocol_and_wait ~parameter_file ~protocol client
  in
  let bootstrap1_key = Constant.bootstrap1.public_key_hash in
  f parameters cryptobox node client bootstrap1_key

type test = {variant : string; tags : string list; description : string}

let with_fresh_rollup ?dal_node f tezos_node tezos_client bootstrap1_key =
  let* rollup_address =
    Client.Sc_rollup.originate
      ~hooks
      ~burn_cap:Tez.(of_int 9999999)
      ~src:bootstrap1_key
      ~kind:"arith"
      ~boot_sector:""
      ~parameters_ty:"unit"
      tezos_client
  in
  let sc_rollup_node =
    Sc_rollup_node.create
      ?dal_node
      Operator
      tezos_node
      tezos_client
      ~default_operator:bootstrap1_key
  in
  let* configuration_filename =
    Sc_rollup_node.config_init sc_rollup_node rollup_address
  in
  let* () = Client.bake_for tezos_client in
  f rollup_address sc_rollup_node configuration_filename

let with_dal_node tezos_node f key =
  let dal_node = Dal_node.create ~node:tezos_node () in
  let* _dir = Dal_node.init_config dal_node in
  f key dal_node

let test_scenario_rollup_dal_node ?commitment_period ?challenge_window
    ?dal_enable {variant; tags; description} scenario =
  let tags = tags @ [variant] in
  regression_test
    ~__FILE__
    ~tags
    (Printf.sprintf "%s (%s)" description variant)
    (fun protocol ->
      setup ?commitment_period ?challenge_window ~protocol ?dal_enable
      @@ fun _parameters _cryptobox node client ->
      with_dal_node node @@ fun key dal_node ->
      ( with_fresh_rollup ~dal_node
      @@ fun sc_rollup_address sc_rollup_node _filename ->
        scenario protocol dal_node sc_rollup_node sc_rollup_address node client
      )
        node
        client
        key)

let test_scenario ?commitment_period ?challenge_window ?dal_enable
    {variant; tags; description} scenario =
  let tags = tags @ [variant] in
  regression_test
    ~__FILE__
    ~tags
    (Printf.sprintf "%s (%s)" description variant)
    (fun protocol ->
      setup ?commitment_period ?challenge_window ~protocol ?dal_enable
      @@ fun _parameters _cryptobox node client ->
      ( with_fresh_rollup @@ fun sc_rollup_address sc_rollup_node _filename ->
        scenario protocol sc_rollup_node sc_rollup_address node client )
        node
        client)

let test_dal_rollup_scenario ?dal_enable variant =
  test_scenario_rollup_dal_node
    ?dal_enable
    {
      tags = ["dal"; "dal_node"];
      variant;
      description = "Testing rollup and Data availability layer node";
    }

let test_dal_scenario ?dal_enable variant =
  test_scenario
    ?dal_enable
    {
      tags = ["dal"];
      variant;
      description = "Testing data availability layer functionality ";
    }

let subscribe_to_dal_slot client ~sc_rollup_address ~slot_index =
  let* op_hash =
    Operation.Manager.(
      inject
        ~force:true
        [
          make
          @@ sc_rollup_dal_slot_subscribe ~rollup:sc_rollup_address ~slot_index;
        ]
        client)
  in
  let* () = Client.bake_for_and_wait client in
  return op_hash

let test_feature_flag _protocol _sc_rollup_node sc_rollup_address node client =
  (* This test ensures the feature flag works:

     - 1. It checks the feature flag is not enabled by default

     - 2. It checks the new operations added by the feature flag
     cannot be propagated by checking their classification in the
     mempool. *)
  let* protocol_parameters =
    RPC.Client.call client @@ RPC.get_chain_block_context_constants ()
  in
  let feature_flag =
    JSON.(
      protocol_parameters |-> "dal_parametric" |-> "feature_enable" |> as_bool)
  in
  let number_of_slots =
    JSON.(
      protocol_parameters |-> "dal_parametric" |-> "number_of_slots" |> as_int)
  in
  let* parameters = Rollup.Dal.Parameters.from_client client in
  let cryptobox = Rollup.Dal.make parameters in
  let commitment =
    Rollup.Dal.Commitment.dummy_commitment parameters cryptobox "coucou"
  in
  Check.(
    (feature_flag = false)
      bool
      ~error_msg:"Feature flag for the DAL should be disabled") ;
  let* (`OpHash oph1) =
    Operation.Consensus.(
      inject
        ~force:true
        ~signer:Constant.bootstrap1
        (slot_availability ~endorsement:(Array.make number_of_slots false))
        client)
  in
  let* (`OpHash oph2) =
    Operation.Manager.(
      inject
        ~force:true
        [make @@ dal_publish_slot_header ~index:0 ~level:1 ~commitment]
        client)
  in
  let* (`OpHash oph3) =
    subscribe_to_dal_slot client ~sc_rollup_address ~slot_index:0
  in
  let* mempool = Mempool.get_mempool client in
  let expected_mempool = Mempool.{empty with refused = [oph1; oph2; oph3]} in
  Check.(
    (mempool = expected_mempool)
      Mempool.classified_typ
      ~error_msg:"Expected mempool: %R. Got: %L. (Order does not matter)") ;
  let* () = Client.bake_for_and_wait client in
  let* block_metadata = RPC.(call node @@ get_chain_block_metadata ()) in
  if block_metadata.dal_slot_availability <> None then
    Test.fail "Did not expect to find \"dal_slot_availibility\"" ;
  let* bytes = RPC_legacy.raw_bytes client in
  if not JSON.(bytes |-> "dal" |> is_null) then
    Test.fail "Unexpected entry dal in the context when DAL is disabled" ;
  unit

let publish_slot ~source ?fee ~index ~commitment node client =
  let level = Node.get_level node in
  Operation.Manager.(
    inject
      [make ~source ?fee @@ dal_publish_slot_header ~index ~level ~commitment]
      client)

let publish_dummy_slot ~source ?fee ~index ~message parameters cryptobox =
  let commitment =
    Rollup.Dal.Commitment.dummy_commitment parameters cryptobox message
  in
  publish_slot ~source ?fee ~index ~commitment

let publish_slot_header ~source ?(fee = 1200) ~index ~commitment node client =
  let level = Node.get_level node in
  let commitment =
    Tezos_crypto_dal.Cryptobox.Commitment.of_b58check_opt commitment
  in
  match commitment with
  | None -> assert false
  | Some commitment ->
      Operation.Manager.(
        inject
          [
            make ~source ~fee
            @@ dal_publish_slot_header ~index ~level ~commitment;
          ]
          client)

let slot_availability ~signer availability client =
  (* FIXME/DAL: fetch the constant from protocol parameters. *)
  let default_size = 256 in
  let endorsement = Array.make default_size false in
  List.iter (fun i -> endorsement.(i) <- true) availability ;
  Operation.Consensus.(inject ~signer (slot_availability ~endorsement) client)

type status = Applied | Failed of {error_id : string}

let pp fmt = function
  | Applied -> Format.fprintf fmt "applied"
  | Failed {error_id} -> Format.fprintf fmt "failed: %s" error_id

let status_typ = Check.equalable pp ( = )

let check_manager_operation_status result expected_status oph =
  let manager_operations = JSON.(result |=> 3 |> as_list) in
  let op =
    try
      List.find
        (fun op -> JSON.(op |-> "hash" |> as_string) = oph)
        manager_operations
    with Not_found ->
      Test.fail
        "Test expecting operation %s to be included into the last block."
        oph
  in
  let op_result =
    JSON.(op |-> "contents" |=> 0 |-> "metadata" |-> "operation_result")
  in
  let status_kind = JSON.(op_result |-> "status" |> as_string) in
  let status =
    match status_kind with
    | "applied" -> Applied
    | "failed" ->
        let error_id =
          JSON.(op_result |-> "errors" |=> 0 |-> "id" |> as_string)
        in
        Failed {error_id}
    | s -> Test.fail "Unexpected status: %s" s
  in
  let prefix_msg = sf "Unexpected operation result for %s." oph in
  Check.(expected_status = status)
    status_typ
    ~error_msg:(prefix_msg ^ " Expected: %L. Got: %R.")

let check_dal_raw_context node =
  let* dal_raw_json =
    RPC.call node @@ RPC.get_chain_block_context_raw_json ~path:["dal"] ()
  in
  if JSON.is_null dal_raw_json then
    Test.fail "Expected the context to contain information under /dal key."
  else
    let json_to_string j =
      JSON.unannotate j |> Ezjsonm.wrap |> Ezjsonm.to_string
    in
    let* confirmed_slots_opt =
      RPC.call
        node
        (RPC.get_chain_block_context_dal_confirmed_slot_headers_history ())
    in
    if JSON.is_null confirmed_slots_opt then
      Test.fail
        "confirmed_slots_history RPC is not expected to return None if DAL is \
         enabled" ;
    let confirmed_slots = json_to_string confirmed_slots_opt in
    let confirmed_slots_from_ctxt =
      json_to_string @@ JSON.(dal_raw_json |-> "slot_headers_history")
    in
    if not (String.equal confirmed_slots confirmed_slots_from_ctxt) then
      Test.fail "Confirmed slots history mismatch." ;
    unit

let test_slot_management_logic =
  Protocol.register_test
    ~__FILE__
    ~title:"dal basic logic"
    ~tags:["dal"]
    ~supports:Protocol.(From_protocol (Protocol.number Alpha))
  @@ fun protocol ->
  setup ~dal_enable:true ~protocol
  @@ fun parameters cryptobox node client _bootstrap ->
  let* (`OpHash oph1) =
    publish_dummy_slot
      ~source:Constant.bootstrap1
      ~fee:1_000
      ~index:0
      ~message:"a"
      parameters
      cryptobox
      node
      client
  in
  let* (`OpHash oph2) =
    publish_dummy_slot
      ~source:Constant.bootstrap2
      ~fee:1_500
      ~index:1
      ~message:"b"
      parameters
      cryptobox
      node
      client
  in
  let* (`OpHash oph3) =
    publish_dummy_slot
      ~source:Constant.bootstrap3
      ~fee:2_000
      ~index:0
      ~message:"c"
      parameters
      cryptobox
      node
      client
  in
  let* (`OpHash oph4) =
    publish_dummy_slot
      ~source:Constant.bootstrap4
      ~fee:1_200
      ~index:1
      ~message:"d"
      parameters
      cryptobox
      node
      client
  in
  let* mempool = Mempool.get_mempool client in
  let expected_mempool =
    Mempool.{empty with applied = [oph1; oph2; oph3; oph4]}
  in
  Check.(
    (mempool = expected_mempool)
      Mempool.classified_typ
      ~error_msg:"Expected all the operations to be applied. Got %L") ;
  let* () = Client.bake_for_and_wait client in
  let* bytes = RPC_legacy.raw_bytes client in
  if JSON.(bytes |-> "dal" |> is_null) then
    Test.fail "Expected the context to contain some information about the DAL" ;
  let* operations_result =
    RPC.Client.call client @@ RPC.get_chain_block_operations ()
  in
  let fees_error =
    Failed {error_id = "proto.alpha.dal_publish_slot_heade_duplicate"}
  in
  (* The baker sorts operations fee wise. Consequently order of
     application for the operations will be: oph3 > oph2 > oph4 > oph1

     For slot 0, oph3 is applied first.

     Flor slot1, oph2 is applied first. *)
  check_manager_operation_status operations_result fees_error oph1 ;
  check_manager_operation_status operations_result fees_error oph4 ;
  check_manager_operation_status operations_result Applied oph3 ;
  check_manager_operation_status operations_result Applied oph2 ;
  let* _ = slot_availability ~signer:Constant.bootstrap1 [1; 0] client in
  let* _ = slot_availability ~signer:Constant.bootstrap2 [1; 0] client in
  let* _ = slot_availability ~signer:Constant.bootstrap3 [1] client in
  let* _ = slot_availability ~signer:Constant.bootstrap4 [1] client in
  let* _ = slot_availability ~signer:Constant.bootstrap5 [1] client in
  let* () = Client.bake_for_and_wait client in
  let* metadata = RPC.call node (RPC.get_chain_block_metadata ()) in
  let dal_slot_availability =
    match metadata.dal_slot_availability with
    | None ->
        assert false
        (* Field is part of the encoding when the feature flag is true *)
    | Some x -> x
  in
  Check.(
    (dal_slot_availability.(0) = false)
      bool
      ~error_msg:"Expected slot 0 to be unavailable") ;
  Check.(
    (dal_slot_availability.(1) = true)
      bool
      ~error_msg:"Expected slot 1 to be available") ;
  check_dal_raw_context node

(* Tests for integration between Dal and Scoru *)
let rollup_node_subscribes_to_dal_slots _protocol sc_rollup_node
    sc_rollup_address _node client =
  (* Steps in this integration test:

     1. Run rollup node for an originated rollup
     2. Fetch the list of subscribed slots, determine that it's empty
     3. Execute a client command to subscribe the rollup to dal slot 0, bake one level
     4. Fetch the list of subscribed slots, determine that it contains slot 0
     5. Execute a client command to subscribe the rollup to dal slot 1, bake one level
     6. Fetch the list of subscribed slots, determine that it contains slots 0 and 1
  *)
  let* genesis_info =
    RPC.Client.call ~hooks client
    @@ RPC.get_chain_block_context_sc_rollup_genesis_info sc_rollup_address
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in
  let* () = Sc_rollup_node.run sc_rollup_node in
  let sc_rollup_client = Sc_rollup_client.create sc_rollup_node in
  let* level = Sc_rollup_node.wait_for_level sc_rollup_node init_level in
  Check.(level = init_level)
    Check.int
    ~error_msg:"Current level has moved past origination level (%L = %R)" ;
  let* subscribed_slots =
    Sc_rollup_client.dal_slot_subscriptions ~hooks sc_rollup_client
  in
  Check.(subscribed_slots = [])
    (Check.list Check.int)
    ~error_msg:"Unexpected list of slot subscriptions (%L = %R)" ;
  let* (`OpHash _) =
    subscribe_to_dal_slot client ~sc_rollup_address ~slot_index:0
  in
  let* first_subscription_level =
    Sc_rollup_node.wait_for_level sc_rollup_node (init_level + 1)
  in
  let* subscribed_slots =
    Sc_rollup_client.dal_slot_subscriptions ~hooks sc_rollup_client
  in
  Check.(subscribed_slots = [0])
    (Check.list Check.int)
    ~error_msg:"Unexpected list of slot subscriptions (%L = %R)" ;
  let* (`OpHash _) =
    subscribe_to_dal_slot client ~sc_rollup_address ~slot_index:1
  in
  let* _second_subscription_level =
    Sc_rollup_node.wait_for_level sc_rollup_node (first_subscription_level + 1)
  in
  let* subscribed_slots =
    Sc_rollup_client.dal_slot_subscriptions ~hooks sc_rollup_client
  in
  Check.(subscribed_slots = [0; 1])
    (Check.list Check.int)
    ~error_msg:"Unexpected list of slot subscriptions (%L = %R)" ;
  return ()

let init_dal_node protocol =
  let* node, client =
    let* parameter_file = Rollup.Dal.Parameters.parameter_file protocol in
    let nodes_args = Node.[Synchronisation_threshold 0] in
    Client.init_with_protocol `Client ~parameter_file ~protocol ~nodes_args ()
  in
  let dal_node = Dal_node.create ~node () in
  let* _dir = Dal_node.init_config dal_node in
  let* () = Dal_node.run dal_node in
  return (node, client, dal_node)

let test_dal_node_slot_management =
  Protocol.register_test
    ~__FILE__
    ~title:"dal node slot management"
    ~tags:["dal"; "dal_node"]
    ~supports:Protocol.(From_protocol (Protocol.number Alpha))
  @@ fun protocol ->
  let* _node, _client, dal_node = init_dal_node protocol in
  let slot_content = "test" in
  let* slot_header =
    RPC.call dal_node (Rollup.Dal.RPC.split_slot slot_content)
  in
  let* received_slot_content =
    RPC.call dal_node (Rollup.Dal.RPC.slot_content slot_header)
  in
  (* Only check that the function to retrieve pages succeeds, actual
     contents are checked in the test `rollup_node_stores_dal_slots`. *)
  let* _slots_as_pages =
    RPC.call dal_node (Rollup.Dal.RPC.slot_pages slot_header)
  in
  assert (slot_content = received_slot_content) ;
  return ()

let publish_and_store_slot node client dal_node source index content =
  let* slot_header = RPC.call dal_node (Rollup.Dal.RPC.split_slot content) in
  let commitment =
    Tezos_crypto_dal.Cryptobox.Commitment.of_b58check_opt slot_header
    |> mandatory "The b58check-encoded slot header is not valid"
  in
  let* _ = publish_slot ~source ~fee:1_200 ~index ~commitment node client in
  return (index, slot_header)

let test_dal_node_slots_headers_tracking =
  Protocol.register_test
    ~__FILE__
    ~title:"dal node slot headers tracking"
    ~tags:["dal"; "dal_node"]
    ~supports:Protocol.(From_protocol (Protocol.number Alpha))
  @@ fun protocol ->
  let* node, client, dal_node = init_dal_node protocol in
  let publish = publish_and_store_slot node client dal_node in
  let* slot0 = publish Constant.bootstrap1 0 "test0" in
  let* slot1 = publish Constant.bootstrap2 1 "test1" in
  let* slot2 = publish Constant.bootstrap3 4 "test4" in
  let* () = Client.bake_for_and_wait client in
  let* _level = Node.wait_for_level node 1 in
  let* block = RPC.call node (RPC.get_chain_block_hash ()) in
  let* slot_headers =
    RPC.call dal_node (Rollup.Dal.RPC.stored_slot_headers block)
  in
  Check.([slot0; slot1; slot2] = slot_headers)
    Check.(list (tuple2 int string))
    ~error_msg:"Published header is different from stored header (%L = %R)" ;
  return ()

let generate_dummy_slot slot_size =
  String.init slot_size (fun i ->
      match i mod 3 with 0 -> 'a' | 1 -> 'b' | _ -> 'c')

let test_dal_node_rebuild_from_shards =
  (* Steps in this integration test:
     1. Run a dal node
     2. Generate and publish a full slot, then bake
     3. Download exactly 1/16 shards from this slot (it would work with more)
     4. Ensure we can rebuild the original data using the above shards
  *)
  Protocol.register_test
    ~__FILE__
    ~title:"dal node shard fetching and slot reconstruction"
    ~tags:["dal"; "dal_node"]
    ~supports:Protocol.(From_protocol (Protocol.number Alpha))
  @@ fun protocol ->
  let open Tezos_crypto_dal in
  let* node, client, dal_node = init_dal_node protocol in
  let* parameters = Rollup.Dal.Parameters.from_client client in
  let slot_content = generate_dummy_slot parameters.slot_size in
  let publish = publish_and_store_slot node client dal_node in
  let* _slot_index, slot_header = publish Constant.bootstrap1 0 slot_content in
  let* () = Client.bake_for_and_wait client in
  let* _level = Node.wait_for_level node 1 in
  let number_of_shards =
    (parameters.number_of_shards / parameters.redundancy_factor) - 1
  in
  let downloaded_shard_ids =
    range 0 number_of_shards
    |> List.map (fun i -> i * parameters.redundancy_factor)
  in
  let* shards =
    Lwt_list.fold_left_s
      (fun acc shard_id ->
        let* shard =
          RPC.call dal_node (Rollup.Dal.RPC.shard ~slot_header ~shard_id)
        in
        let shard =
          match Data_encoding.Json.from_string shard with
          | Ok s -> s
          | Error _ -> Test.fail "shard RPC sent invalid json"
        in
        let shard =
          Data_encoding.Json.destruct Cryptobox.shard_encoding shard
        in
        return @@ Cryptobox.IntMap.add shard.index shard.share acc)
      Cryptobox.IntMap.empty
      downloaded_shard_ids
  in
  let cryptobox = Rollup.Dal.make parameters in
  let reformed_slot =
    match Cryptobox.polynomial_from_shards cryptobox shards with
    | Ok p -> Cryptobox.polynomial_to_bytes cryptobox p |> Bytes.to_string
    | Error _ -> Test.fail "Fail to build polynomial from shards"
  in
  Check.(reformed_slot = slot_content)
    Check.(string)
    ~error_msg:"Reconstructed slot is different from original slot (%L = %R)" ;
  return ()

let test_dal_node_startup =
  Protocol.register_test
    ~__FILE__
    ~title:"dal node startup"
    ~tags:["dal"; "dal_node"]
    ~supports:Protocol.(From_protocol (Protocol.number Alpha))
  @@ fun protocol ->
  let run_dal = Dal_node.run ~wait_ready:false in
  let nodes_args = Node.[Synchronisation_threshold 0] in
  let previous_protocol =
    match Protocol.previous_protocol protocol with
    | Some p -> p
    | None -> assert false
  in
  let* node, client =
    Client.init_with_protocol `Client ~protocol:previous_protocol ~nodes_args ()
  in
  let dal_node = Dal_node.create ~node () in
  let* _dir = Dal_node.init_config dal_node in
  let* () = run_dal dal_node in
  let* () =
    Dal_node.wait_for dal_node "dal_node_layer_1_start_tracking.v0" (fun _ ->
        Some ())
  in
  assert (Dal_node.is_running_not_ready dal_node) ;
  let* () = Dal_node.terminate dal_node in
  let* () = Node.terminate node in
  Node.Config_file.update
    node
    (Node.Config_file.set_sandbox_network_with_user_activated_overrides
       [(Protocol.hash previous_protocol, Protocol.hash Alpha)]) ;
  let* () = Node.run node nodes_args in
  let* () = Node.wait_for_ready node in
  let* () = run_dal dal_node in
  let* () =
    Lwt.join
      [
        Dal_node.wait_for dal_node "dal_node_plugin_resolved.v0" (fun _ ->
            Some ());
        Client.bake_for_and_wait client;
      ]
  in
  let* () = Dal_node.terminate dal_node in
  return ()

let rollup_node_stores_dal_slots _protocol dal_node sc_rollup_node
    sc_rollup_address node client =
  (* Check that the rollup node stores the slots published in a block, along with slot headers:
     0. Run dal node
     1. Send three slots to dal node and obtain corresponding headers
     2. Run rollup node for an originated rollup
     3. Subscribe rollup node to slots 0 and 1
     4. Publish the three slot headers for slots 0, 1, 2
     5. Check that the rollup node fetched the slot headers from L1
     6. After lag levels, endorse only slots 1 and 2
     7. Wait for the rollup node to download the slots
     8. Verify that rollup node has downloaded slot 1, slot 0 is
        unconfirmed, and slot 2 has not been downloaded
  *)

  (* 0. run dl node. *)
  let* () = Dal_node.run dal_node in

  (* 1. Send three slots to dal node and obtain corresponding headers. *)
  let slot_contents_0 = "DEADC0DE" in
  let* commitment_0 =
    RPC.call dal_node (Rollup.Dal.RPC.split_slot slot_contents_0)
  in
  let slot_contents_1 = "CAFEDEAD" in
  let* commitment_1 =
    RPC.call dal_node (Rollup.Dal.RPC.split_slot slot_contents_1)
  in
  let slot_contents_2 = "C0FFEE" in
  let* commitment_2 =
    RPC.call dal_node (Rollup.Dal.RPC.split_slot slot_contents_2)
  in
  (* 2. Run rollup node for an originated rollup. *)
  let* genesis_info =
    RPC.Client.call ~hooks client
    @@ RPC.get_chain_block_context_sc_rollup_genesis_info sc_rollup_address
  in
  let init_level = JSON.(genesis_info |-> "level" |> as_int) in
  let* () = Sc_rollup_node.run sc_rollup_node in
  let sc_rollup_client = Sc_rollup_client.create sc_rollup_node in
  let* level = Sc_rollup_node.wait_for_level sc_rollup_node init_level in
  Check.(level = init_level)
    Check.int
    ~error_msg:"Current level has moved past origination level (%L = %R)" ;
  let* (`OpHash _) =
    subscribe_to_dal_slot client ~sc_rollup_address ~slot_index:0
  in
  (* 3. Subscribe rollup node to slots 0 and 1. *)
  let* first_subscription_level =
    Sc_rollup_node.wait_for_level sc_rollup_node (init_level + 1)
  in
  let* (`OpHash _) =
    subscribe_to_dal_slot client ~sc_rollup_address ~slot_index:1
  in
  let* second_subscription_level =
    Sc_rollup_node.wait_for_level sc_rollup_node (first_subscription_level + 1)
  in
  (* 4. Publish the three slot headers for slots with indexes 0, 1 and 2. *)
  let* _op_hash =
    publish_slot_header
      ~source:Constant.bootstrap1
      ~index:0
      ~commitment:commitment_0
      node
      client
  in
  let* _op_hash =
    publish_slot_header
      ~source:Constant.bootstrap2
      ~index:1
      ~commitment:commitment_1
      node
      client
  in
  let* _op_hash =
    publish_slot_header
      ~source:Constant.bootstrap3
      ~index:2
      ~commitment:commitment_2
      node
      client
  in
  (* 5. Check that the slot_headers are fetched by the rollup node. *)
  let* () = Client.bake_for_and_wait client in
  let* slots_published_level =
    Sc_rollup_node.wait_for_level sc_rollup_node (second_subscription_level + 1)
  in
  let* slots_headers =
    Sc_rollup_client.dal_slot_headers ~hooks sc_rollup_client
  in
  let commitments =
    slots_headers
    |> List.map (fun Sc_rollup_client.{commitment; _} -> commitment)
  in
  let expected_commitments = [commitment_0; commitment_1; commitment_2] in
  Check.(commitments = expected_commitments)
    (Check.list Check.string)
    ~error_msg:"Unexpected list of slot headers (%L = %R)" ;
  (* 6. endorse only slots 1 and 2. *)
  let* _op_hash =
    slot_availability ~signer:Constant.bootstrap1 [2; 1; 0] client
  in
  let* _op_hash =
    slot_availability ~signer:Constant.bootstrap2 [2; 1; 0] client
  in
  let* _op_hash = slot_availability ~signer:Constant.bootstrap3 [2; 1] client in
  let* _op_hash = slot_availability ~signer:Constant.bootstrap4 [2; 1] client in
  let* _op_hash = slot_availability ~signer:Constant.bootstrap5 [2; 1] client in
  let* () = Client.bake_for_and_wait client in
  let* level =
    Sc_rollup_node.wait_for_level sc_rollup_node (slots_published_level + 1)
  in
  Check.(level = slots_published_level + 1)
    Check.int
    ~error_msg:"Current level has moved past slot endorsement level (%L = %R)" ;
  (* 7. Wait for the rollup node to download the endorsed slots. *)
  let* downloaded_slots =
    Sc_rollup_client.dal_downloaded_slots ~hooks sc_rollup_client
  in
  (* 8. Verify that rollup node has downloaded slot 1, slot 0 is
        unconfirmed, and slot 2 has not been downloaded *)
  let expected_number_of_downloaded_or_unconfirmed_slots = 2 in
  Check.(
    List.length downloaded_slots
    = expected_number_of_downloaded_or_unconfirmed_slots)
    Check.int
    ~error_msg:
      "Unexpected number of slots that have been either downloaded or \
       unconfirmed (%L = %R)" ;
  let slot_0_index, slot_0_pages = List.nth downloaded_slots 0 in
  Check.(slot_0_index = 0)
    Check.int
    ~error_msg:"Slot is not as expected(%L = %R)" ;

  List.iter
    (fun page ->
      Check.(page = None)
        (Check.option @@ Check.string)
        ~error_msg:"Contents of slot 0 are not as expected (%L = %R)")
    slot_0_pages ;
  let confirmed_slot_index, confirmed_slot_contents =
    List.nth downloaded_slots 1
  in
  Check.(confirmed_slot_index = 1)
    Check.int
    ~error_msg:"Index of confirmed slot is not as expected (%L = %R)" ;
  let relevant_slot = Option.get @@ List.nth confirmed_slot_contents 0 in
  let message = String.sub relevant_slot 0 (String.length slot_contents_1) in
  Check.(message = slot_contents_1)
    Check.string
    ~error_msg:"unexpected message in slot (%L = %R)" ;
  return ()

let register ~protocols =
  test_dal_scenario "feature_flag_is_disabled" test_feature_flag protocols ;
  test_dal_scenario
    ~dal_enable:true
    "rollup_node_dal_subscriptions"
    rollup_node_subscribes_to_dal_slots
    protocols ;
  test_slot_management_logic protocols ;
  test_dal_node_slot_management protocols ;
  test_dal_node_slots_headers_tracking protocols ;
  test_dal_node_rebuild_from_shards protocols ;
  test_dal_node_startup protocols ;
  test_dal_rollup_scenario
    ~dal_enable:true
    "rollup_node_downloads_slots"
    rollup_node_stores_dal_slots
    protocols
