(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2019 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

open Protocol
open Alpha_context
open Client_proto_context
open Client_proto_contracts
open Client_proto_rollups
open Client_keys
open Client_proto_args

let save_tx_rollup ~force (cctxt : #Client_context.full) alias_name rollup
    ~origination_level =
  TxRollupAlias.add ~force cctxt alias_name {rollup; origination_level}
  >>=? fun () ->
  cctxt#message "Transaction rollup memorized as %s" alias_name >>= fun () ->
  return_unit

let encrypted_switch =
  Clic.switch ~long:"encrypted" ~doc:"encrypt the key on-disk" ()

let normalize_types_switch =
  Clic.switch
    ~long:"normalize-types"
    ~doc:
      "Whether types should be normalized (annotations removed, combs \
       flattened) or kept as they appeared in the original script."
    ()

let report_michelson_errors ?(no_print_source = false) ~msg
    (cctxt : #Client_context.full) = function
  | Error errs ->
      Michelson_v1_error_reporter.enrich_runtime_errors
        cctxt
        ~chain:cctxt#chain
        ~block:cctxt#block
        ~parsed:None
        errs
      >>= fun errs ->
      cctxt#warning
        "%a"
        (Michelson_v1_error_reporter.report_errors
           ~details:(not no_print_source)
           ~show_source:(not no_print_source)
           ?parsed:None)
        errs
      >>= fun () ->
      cctxt#error "%s" msg >>= fun () -> Lwt.return_none
  | Ok data -> Lwt.return_some data

let block_hash_param =
  Clic.parameter (fun _ s ->
      try return (Block_hash.of_b58check_exn s)
      with _ -> failwith "Parameter '%s' is an invalid block hash" s)

let group =
  {
    Clic.name = "context";
    title = "Block contextual commands (see option -block)";
  }

let alphanet = {Clic.name = "alphanet"; title = "Alphanet only commands"}

let binary_description =
  {Clic.name = "description"; title = "Binary Description"}

let tez_of_string_exn index field s =
  match Tez.of_string s with
  | Some t -> return t
  | None ->
      failwith
        "Invalid \xEA\x9C\xA9 notation at entry %i, field \"%s\": %s"
        index
        field
        s

let tez_of_opt_string_exn index field s =
  match s with
  | None -> return None
  | Some s -> tez_of_string_exn index field s >>=? fun s -> return (Some s)

let commands_ro () =
  let open Clic in
  [
    command
      ~group
      ~desc:"Access the timestamp of the block."
      (args1
         (switch ~doc:"output time in seconds" ~short:'s' ~long:"seconds" ()))
      (fixed ["get"; "timestamp"])
      (fun seconds (cctxt : Protocol_client_context.full) ->
        Shell_services.Blocks.Header.shell_header
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ()
        >>=? fun {timestamp = v; _} ->
        (if seconds then cctxt#message "%Ld" (Time.Protocol.to_seconds v)
        else cctxt#message "%s" (Time.Protocol.to_notation v))
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Lists all non empty contracts of the block."
      no_options
      (fixed ["list"; "contracts"])
      (fun () (cctxt : Protocol_client_context.full) ->
        list_contract_labels cctxt ~chain:cctxt#chain ~block:cctxt#block
        >>=? fun contracts ->
        List.iter_s
          (fun (alias, hash, kind) -> cctxt#message "%s%s%s" hash kind alias)
          contracts
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Lists cached contracts and their age in LRU ordering."
      no_options
      (prefixes ["list"; "cached"; "contracts"] @@ stop)
      (fun () (cctxt : Protocol_client_context.full) ->
        cached_contracts cctxt ~chain:cctxt#chain ~block:cctxt#block
        >>=? fun keys ->
        List.iter_s
          (fun (key, size) -> cctxt#message "%a %d" Contract_hash.pp key size)
          keys
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get the key rank of a cache key."
      no_options
      (prefixes ["get"; "cached"; "contract"; "rank"; "for"]
      @@ OriginatedContractAlias.destination_param ~name:"src" ~desc:"contract"
      @@ stop)
      (fun () contract (cctxt : Protocol_client_context.full) ->
        contract_rank cctxt ~chain:cctxt#chain ~block:cctxt#block contract
        >>=? fun rank ->
        match rank with
        | None ->
            cctxt#error "Invalid contract: %a" Contract_hash.pp contract
            >>= fun () -> return_unit
        | Some rank -> cctxt#message "%d" rank >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get cache contract size."
      no_options
      (prefixes ["get"; "cache"; "contract"; "size"] @@ stop)
      (fun () (cctxt : Protocol_client_context.full) ->
        contract_cache_size cctxt ~chain:cctxt#chain ~block:cctxt#block
        >>=? fun t ->
        cctxt#message "%d" t >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get cache contract size limit."
      no_options
      (prefixes ["get"; "cache"; "contract"; "size"; "limit"] @@ stop)
      (fun () (cctxt : Protocol_client_context.full) ->
        contract_cache_size_limit cctxt ~chain:cctxt#chain ~block:cctxt#block
        >>=? fun t ->
        cctxt#message "%d" t >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get the balance of a contract."
      no_options
      (prefixes ["get"; "balance"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ stop)
      (fun () contract (cctxt : Protocol_client_context.full) ->
        get_balance cctxt ~chain:cctxt#chain ~block:cctxt#block contract
        >>=? fun amount ->
        cctxt#answer "%a %s" Tez.pp amount Operation_result.tez_sym
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get the storage of a contract."
      (args1 (unparsing_mode_arg ~default:"Readable"))
      (prefixes ["get"; "contract"; "storage"; "for"]
      @@ OriginatedContractAlias.destination_param
           ~name:"src"
           ~desc:"source contract"
      @@ stop)
      (fun unparsing_mode contract (cctxt : Protocol_client_context.full) ->
        get_storage
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ~unparsing_mode
          contract
        >>=? function
        | None -> cctxt#error "This is not a smart contract."
        | Some storage ->
            cctxt#answer "%a" Michelson_v1_printer.print_expr_unwrapped storage
            >>= fun () -> return_unit);
    command
      ~group
      ~desc:
        "Get the value associated to a key in the big map storage of a \
         contract (deprecated)."
      no_options
      (prefixes ["get"; "big"; "map"; "value"; "for"]
      @@ Clic.param ~name:"key" ~desc:"the key to look for" data_parameter
      @@ prefixes ["of"; "type"]
      @@ Clic.param ~name:"type" ~desc:"type of the key" data_parameter
      @@ prefix "in"
      @@ OriginatedContractAlias.destination_param
           ~name:"src"
           ~desc:"source contract"
      @@ stop)
      (fun () key key_type contract (cctxt : Protocol_client_context.full) ->
        get_contract_big_map_value
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          contract
          (key.expanded, key_type.expanded)
        >>=? function
        | None -> cctxt#error "No value associated to this key."
        | Some value ->
            cctxt#answer "%a" Michelson_v1_printer.print_expr_unwrapped value
            >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get a value in a big map."
      (args1 (unparsing_mode_arg ~default:"Readable"))
      (prefixes ["get"; "element"]
      @@ Clic.param
           ~name:"key"
           ~desc:"the key to look for"
           (Clic.parameter (fun _ s ->
                return (Script_expr_hash.of_b58check_exn s)))
      @@ prefixes ["of"; "big"; "map"]
      @@ Clic.param
           ~name:"big_map"
           ~desc:"identifier of the big_map"
           int_parameter
      @@ stop)
      (fun unparsing_mode key id (cctxt : Protocol_client_context.full) ->
        get_big_map_value
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ~unparsing_mode
          (Big_map.Id.parse_z (Z.of_int id))
          key
        >>=? fun value ->
        cctxt#answer "%a" Michelson_v1_printer.print_expr_unwrapped value
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get the code of a contract."
      (args2 (unparsing_mode_arg ~default:"Readable") normalize_types_switch)
      (prefixes ["get"; "contract"; "code"; "for"]
      @@ OriginatedContractAlias.destination_param
           ~name:"src"
           ~desc:"source contract"
      @@ stop)
      (fun (unparsing_mode, normalize_types)
           contract
           (cctxt : Protocol_client_context.full) ->
        get_script
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ~unparsing_mode
          ~normalize_types
          contract
        >>=? function
        | None -> cctxt#error "This is not a smart contract."
        | Some {code; storage = _} -> (
            match Script_repr.force_decode code with
            | Error errs ->
                cctxt#error "%a" Environment.Error_monad.pp_trace errs
            | Ok code ->
                let {Michelson_v1_parser.source; _} =
                  Michelson_v1_printer.unparse_toplevel code
                in
                cctxt#answer "%s" source >>= return));
    command
      ~group
      ~desc:"Get the `BLAKE2B` script hash of a contract."
      no_options
      (prefixes ["get"; "contract"; "script"; "hash"; "for"]
      @@ OriginatedContractAlias.destination_param
           ~name:"src"
           ~desc:"source contract"
      @@ stop)
      (fun () contract (cctxt : Protocol_client_context.full) ->
        get_script_hash cctxt ~chain:cctxt#chain ~block:cctxt#block contract
        >>= function
        | Error errs -> cctxt#error "%a" pp_print_trace errs
        | Ok None -> cctxt#error "This is not a smart contract."
        | Ok (Some hash) -> cctxt#answer "%a" Script_expr_hash.pp hash >|= ok);
    command
      ~group
      ~desc:"Get the type of an entrypoint of a contract."
      (args1 normalize_types_switch)
      (prefixes ["get"; "contract"; "entrypoint"; "type"; "of"]
      @@ Clic.param
           ~name:"entrypoint"
           ~desc:"the entrypoint to describe"
           entrypoint_parameter
      @@ prefixes ["for"]
      @@ OriginatedContractAlias.destination_param
           ~name:"src"
           ~desc:"source contract"
      @@ stop)
      (fun normalize_types
           entrypoint
           contract
           (cctxt : Protocol_client_context.full) ->
        Michelson_v1_entrypoints.contract_entrypoint_type
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ~contract
          ~entrypoint
          ~normalize_types
        >>= Michelson_v1_entrypoints.print_entrypoint_type
              cctxt
              ~emacs:false
              ~contract
              ~entrypoint);
    command
      ~group
      ~desc:"Get the entrypoint list of a contract."
      (args1 normalize_types_switch)
      (prefixes ["get"; "contract"; "entrypoints"; "for"]
      @@ OriginatedContractAlias.destination_param
           ~name:"src"
           ~desc:"source contract"
      @@ stop)
      (fun normalize_types contract (cctxt : Protocol_client_context.full) ->
        Michelson_v1_entrypoints.list_contract_entrypoints
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ~contract
          ~normalize_types
        >>= Michelson_v1_entrypoints.print_entrypoints_list
              cctxt
              ~emacs:false
              ~contract);
    command
      ~group
      ~desc:"Get the list of unreachable paths in a contract's parameter type."
      no_options
      (prefixes ["get"; "contract"; "unreachable"; "paths"; "for"]
      @@ OriginatedContractAlias.destination_param
           ~name:"src"
           ~desc:"source contract"
      @@ stop)
      (fun () contract (cctxt : Protocol_client_context.full) ->
        Michelson_v1_entrypoints.list_contract_unreachables
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ~contract
        >>= Michelson_v1_entrypoints.print_unreachables
              cctxt
              ~emacs:false
              ~contract);
    command
      ~group
      ~desc:"Get the delegate of a contract."
      no_options
      (prefixes ["get"; "delegate"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ stop)
      (fun () contract (cctxt : Protocol_client_context.full) ->
        Client_proto_contracts.get_delegate
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          contract
        >>=? function
        | None -> cctxt#message "none" >>= fun () -> return_unit
        | Some delegate ->
            Public_key_hash.rev_find cctxt delegate >>=? fun mn ->
            Public_key_hash.to_source delegate >>=? fun m ->
            cctxt#message
              "%s (%s)"
              m
              (match mn with None -> "unknown" | Some n -> "known as " ^ n)
            >>= fun () -> return_unit);
    command
      ~desc:"Get receipt for past operation"
      (args1
         (default_arg
            ~long:"check-previous"
            ~placeholder:"num_blocks"
            ~doc:"number of previous blocks to check"
            ~default:"10"
            non_negative_parameter))
      (prefixes ["get"; "receipt"; "for"]
      @@ param
           ~name:"operation"
           ~desc:"Operation to be looked up"
           (parameter (fun _ x ->
                match Operation_hash.of_b58check_opt x with
                | None -> Error_monad.failwith "Invalid operation hash: '%s'" x
                | Some hash -> return hash))
      @@ stop)
      (fun predecessors operation_hash (ctxt : Protocol_client_context.full) ->
        display_receipt_for_operation
          ctxt
          ~chain:ctxt#chain
          ~predecessors
          operation_hash
        >>=? fun _ -> return_unit);
    command
      ~group
      ~desc:"Summarize the current voting period"
      no_options
      (fixed ["show"; "voting"; "period"])
      (fun () (cctxt : Protocol_client_context.full) ->
        get_period_info ~chain:cctxt#chain ~block:cctxt#block cctxt
        >>=? fun info ->
        cctxt#message
          "Current period: %a\nBlocks remaining until end of period: %ld"
          Data_encoding.Json.pp
          (Data_encoding.Json.construct
             Alpha_context.Voting_period.kind_encoding
             info.current_period_kind)
          info.remaining
        >>= fun () ->
        Shell_services.Protocol.list cctxt >>=? fun known_protos ->
        get_proposals ~chain:cctxt#chain ~block:cctxt#block cctxt
        >>=? fun props ->
        let ranks =
          Environment.Protocol_hash.Map.bindings props
          |> List.sort (fun (_, v1) (_, v2) -> Int64.(compare v2 v1))
        in
        let print_proposal = function
          | None ->
              cctxt#message "The current proposal has already been cleared."
          (* The proposal is cleared on the last block of adoption period, and
             also on the last block of the exploration and promotion
             periods when the proposal is not approved *)
          | Some proposal ->
              cctxt#message "Current proposal: %a" Protocol_hash.pp proposal
        in
        match info.current_period_kind with
        | Proposal ->
            (* the current proposals are cleared on the last block of the
               proposal period *)
            if info.remaining <> 0l then
              cctxt#answer
                "Current proposals:%t"
                Format.(
                  fun ppf ->
                    pp_print_cut ppf () ;
                    pp_open_vbox ppf 0 ;
                    List.iter
                      (fun (p, w) ->
                        fprintf
                          ppf
                          "* %a %a %s (%sknown by the node)@."
                          Protocol_hash.pp
                          p
                          Tez.pp
                          (Tez.of_mutez_exn w)
                          Operation_result.tez_sym
                          (if List.mem ~equal:Protocol_hash.equal p known_protos
                          then ""
                          else "not "))
                      ranks ;
                    pp_close_box ppf ())
              >>= fun () -> return_unit
            else
              cctxt#message "The proposals have already been cleared."
              >>= fun () -> return_unit
        | Exploration | Promotion ->
            print_proposal info.current_proposal >>= fun () ->
            (* the ballots are cleared on the last block of these periods *)
            if info.remaining <> 0l then
              get_ballots_info ~chain:cctxt#chain ~block:cctxt#block cctxt
              >>=? fun ballots_info ->
              cctxt#answer
                "@[<v>Ballots:@,\
                \  Yay: %a %s@,\
                \  Nay: %a %s@,\
                \  Pass: %a %s@,\
                 Current participation %.2f%%, necessary quorum %.2f%%@,\
                 Current in favor %a %s, needed supermajority %a %s@]"
                Tez.pp
                (Tez.of_mutez_exn ballots_info.ballots.yay)
                Operation_result.tez_sym
                Tez.pp
                (Tez.of_mutez_exn ballots_info.ballots.nay)
                Operation_result.tez_sym
                Tez.pp
                (Tez.of_mutez_exn ballots_info.ballots.pass)
                Operation_result.tez_sym
                (Int32.to_float ballots_info.participation /. 100.)
                (Int32.to_float ballots_info.current_quorum /. 100.)
                Tez.pp
                (Tez.of_mutez_exn ballots_info.ballots.yay)
                Operation_result.tez_sym
                Tez.pp
                (Tez.of_mutez_exn ballots_info.supermajority)
                Operation_result.tez_sym
              >>= fun () -> return_unit
            else
              cctxt#message "The ballots have already been cleared."
              >>= fun () -> return_unit
        | Cooldown ->
            print_proposal info.current_proposal >>= fun () -> return_unit
        | Adoption ->
            print_proposal info.current_proposal >>= fun () -> return_unit);
    command
      ~group:binary_description
      ~desc:"Describe unsigned block header"
      no_options
      (fixed ["describe"; "unsigned"; "block"; "header"])
      (fun () (cctxt : Protocol_client_context.full) ->
        cctxt#message
          "%a"
          Data_encoding.Binary_schema.pp
          (Data_encoding.Binary.describe
             Alpha_context.Block_header.unsigned_encoding)
        >>= fun () -> return_unit);
    command
      ~group:binary_description
      ~desc:"Describe unsigned operation"
      no_options
      (fixed ["describe"; "unsigned"; "operation"])
      (fun () (cctxt : Protocol_client_context.full) ->
        cctxt#message
          "%a"
          Data_encoding.Binary_schema.pp
          (Data_encoding.Binary.describe
             Alpha_context.Operation.unsigned_encoding)
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:"Get the frozen deposits limit of a delegate."
      no_options
      (prefixes ["get"; "deposits"; "limit"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source delegate"
      @@ stop)
      (fun () contract (cctxt : Protocol_client_context.full) ->
        match contract with
        | Originated _ ->
            cctxt#error
              "Cannot change deposits limit on contract %a. This operation is \
               invalid on originated contracts."
              Contract.pp
              contract
        | Implicit delegate -> (
            get_frozen_deposits_limit
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              delegate
            >>=? function
            | None -> cctxt#answer "unlimited" >>= return
            | Some limit ->
                cctxt#answer "%a %s" Tez.pp limit Operation_result.tez_sym
                >>= return));
  ]

(* ----------------------------------------------------------------------------*)
(* After the activation of a new version of the protocol, the older protocols
   are only kept in the code base to replay the history of the chain and to query
   old states.

   The commands that are not useful anymore in the old protocols are removed,
   this is called protocol freezing. The commands below are those that can be
   removed during protocol freezing.

   The rule of thumb to know if a command should be kept at freezing is that all
   commands that modify the state of the chain should be removed and conversely
   all commands that are used to query the context should be kept. For this
   reason, we call read-only (or RO for short) the commands that are kept and
   read-write (or RW for short) the commands that are removed.

   There are some exceptions to this rule however, for example the command
   "octez-client wait for <op> to be included" is classified as RW despite having
   no effect on the context because it has no use case once all RW commands are
   removed.

   Keeping this in mind, the developer should decide where to add a new command.
   At the end of the file, RO and RW commands are concatenated into one list that
   is then exported in the mli file. *)
(* ----------------------------------------------------------------------------*)

let dry_run_switch =
  Clic.switch
    ~long:"dry-run"
    ~short:'D'
    ~doc:"don't inject the operation, just display it"
    ()

let verbose_signing_switch =
  Clic.switch
    ~long:"verbose-signing"
    ~doc:"display extra information before signing the operation"
    ()

let simulate_switch =
  Clic.switch
    ~long:"simulation"
    ~doc:
      "Simulate the execution of the command, without needing any signatures."
    ()

let force_switch =
  Clic.switch
    ~long:"force"
    ~doc:
      "Inject the operation even if the simulation results in a failure. This \
       switch requires --gas-limit, --storage-limit, and --fee."
    ()

let transfer_command amount (source : Contract.t) destination
    (cctxt : #Client_context.printer)
    ( fee,
      dry_run,
      verbose_signing,
      simulation,
      force,
      gas_limit,
      storage_limit,
      counter,
      arg,
      no_print_source,
      fee_parameter,
      entrypoint,
      replace_by_fees,
      successor_level ) =
  (* When --force is used we want to inject the transfer even if it fails.
     In that case we cannot rely on simulation to compute limits and fees
     so we require the corresponding options to be set. *)
  let check_force_dependency name = function
    | None ->
        cctxt#error
          "When the --force switch is used, the %s option is required."
          name
    | _ -> Lwt.return_unit
  in
  (if force && not simulation then
   check_force_dependency "--gas-limit" gas_limit >>= fun () ->
   check_force_dependency "--storage-limit" storage_limit >>= fun () ->
   check_force_dependency "--fee" fee
  else Lwt.return_unit)
  >>= fun () ->
  (match source with
  | Originated contract_hash ->
      let contract = source in
      Managed_contract.get_contract_manager cctxt contract_hash
      >>=? fun source ->
      Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
      Managed_contract.transfer
        cctxt
        ~chain:cctxt#chain
        ~block:cctxt#block
        ?confirmations:cctxt#confirmations
        ~dry_run
        ~verbose_signing
        ~simulation
        ~force
        ~fee_parameter
        ?fee
        ~contract
        ~source
        ~src_pk
        ~src_sk
        ~destination
        ?entrypoint
        ?arg
        ~amount
        ?gas_limit
        ?storage_limit
        ?counter
        ()
  | Implicit source ->
      Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
      transfer
        cctxt
        ~chain:cctxt#chain
        ~block:cctxt#block
        ?confirmations:cctxt#confirmations
        ~dry_run
        ~simulation
        ~force
        ~verbose_signing
        ~fee_parameter
        ~source
        ?fee
        ~src_pk
        ~src_sk
        ~destination
        ?entrypoint
        ?arg
        ~amount
        ?gas_limit
        ?storage_limit
        ?counter
        ~replace_by_fees
        ~successor_level
        ())
  >>= report_michelson_errors
        ~no_print_source
        ~msg:"transfer simulation failed"
        cctxt
  >>= function
  | None -> return_unit
  | Some (_res, _contracts) -> return_unit

let prepare_batch_operation cctxt ?arg ?fee ?gas_limit ?storage_limit
    ?entrypoint (source : Contract.t) index batch =
  Client_proto_contracts.ContractAlias.find_destination cctxt batch.destination
  >>=? fun destination ->
  tez_of_string_exn index "amount" batch.amount >>=? fun amount ->
  tez_of_opt_string_exn index "fee" batch.fee >>=? fun batch_fee ->
  let fee = Option.either batch_fee fee in
  let arg = Option.either batch.arg arg in
  let gas_limit = Option.either batch.gas_limit gas_limit in
  let storage_limit = Option.either batch.storage_limit storage_limit in
  let entrypoint = Option.either batch.entrypoint entrypoint in
  parse_arg_transfer arg >>=? fun parameters ->
  (match source with
  | Originated _ ->
      Managed_contract.build_transaction_operation
        cctxt
        ~chain:cctxt#chain
        ~block:cctxt#block
        ~contract:source
        ~destination
        ?entrypoint
        ?arg
        ~amount
        ?fee
        ?gas_limit
        ?storage_limit
        ()
  | Implicit _ ->
      return
        (build_transaction_operation
           ~amount
           ~parameters
           ?entrypoint
           ?fee
           ?gas_limit
           ?storage_limit
           destination))
  >>=? fun operation ->
  return (Annotated_manager_operation.Annotated_manager_operation operation)

let commands_network network () =
  let open Clic in
  match network with
  | Some `Testnet | None ->
      [
        command
          ~group
          ~desc:"Register and activate an Alphanet/Zeronet faucet account."
          (args2 (Secret_key.force_switch ()) encrypted_switch)
          (prefixes ["activate"; "account"]
          @@ Secret_key.fresh_alias_param @@ prefixes ["with"]
          @@ param
               ~name:"activation_key"
               ~desc:
                 "Activate an Alphanet/Zeronet faucet account from the JSON \
                  (file or directly inlined)."
               json_parameter
          @@ stop)
          (fun (force, encrypted) name activation_json cctxt ->
            Secret_key.of_fresh cctxt force name >>=? fun name ->
            match
              Data_encoding.Json.destruct
                Client_proto_context.activation_key_encoding
                activation_json
            with
            | exception (Data_encoding.Json.Cannot_destruct _ as exn) ->
                Format.kasprintf
                  (fun s -> failwith "%s" s)
                  "Invalid activation file: %a %a"
                  (fun ppf -> Data_encoding.Json.print_error ppf)
                  exn
                  Data_encoding.Json.pp
                  activation_json
            | key ->
                activate_account
                  cctxt
                  ~chain:cctxt#chain
                  ~block:cctxt#block
                  ?confirmations:cctxt#confirmations
                  ~encrypted
                  ~force
                  key
                  name
                >>=? fun _res -> return_unit);
      ]
  | Some `Mainnet ->
      [
        command
          ~group
          ~desc:"Activate a fundraiser account."
          (args1 dry_run_switch)
          (prefixes ["activate"; "fundraiser"; "account"]
          @@ Public_key_hash.alias_param @@ prefixes ["with"]
          @@ param
               ~name:"code"
               (Clic.parameter (fun _ctx code ->
                    match
                      Blinded_public_key_hash.activation_code_of_hex code
                    with
                    | Some c -> return c
                    | None -> failwith "Hexadecimal parsing failure"))
               ~desc:"Activation code obtained from the Tezos foundation."
          @@ stop)
          (fun dry_run (name, _pkh) code cctxt ->
            activate_existing_account
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~dry_run
              name
              code
            >>=? fun _res -> return_unit);
      ]

let commands_rw () =
  let open Client_proto_programs in
  let open Tezos_micheline in
  let open Clic in
  [
    command
      ~group
      ~desc:"Set the delegate of a contract."
      (args5
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args)
      (prefixes ["set"; "delegate"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ prefix "to"
      @@ Public_key_hash.source_param
           ~name:"dlgt"
           ~desc:"new delegate of the contract"
      @@ stop)
      (fun (fee, dry_run, verbose_signing, simulation, fee_parameter)
           contract
           delegate
           (cctxt : Protocol_client_context.full) ->
        match contract with
        | Originated contract ->
            Managed_contract.get_contract_manager cctxt contract
            >>=? fun source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            Managed_contract.set_delegate
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~dry_run
              ~verbose_signing
              ~simulation
              ~fee_parameter
              ?fee
              ~source
              ~src_pk
              ~src_sk
              contract
              (Some delegate)
            >>= fun errors ->
            report_michelson_errors
              ~no_print_source:true
              ~msg:"Setting delegate through entrypoints failed."
              cctxt
              errors
            >>= fun _ -> return_unit
        | Implicit mgr ->
            Client_keys.get_key cctxt mgr >>=? fun (_, src_pk, manager_sk) ->
            set_delegate
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~dry_run
              ~verbose_signing
              ~simulation
              ~fee_parameter
              ?fee
              mgr
              (Some delegate)
              ~src_pk
              ~manager_sk
            >>=? fun _ -> return_unit);
    command
      ~group
      ~desc:"Withdraw the delegate from a contract."
      (args4 fee_arg dry_run_switch verbose_signing_switch fee_parameter_args)
      (prefixes ["withdraw"; "delegate"; "from"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ stop)
      (fun (fee, dry_run, verbose_signing, fee_parameter)
           contract
           (cctxt : Protocol_client_context.full) ->
        match contract with
        | Originated contract ->
            Managed_contract.get_contract_manager cctxt contract
            >>=? fun source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            Managed_contract.set_delegate
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~dry_run
              ~verbose_signing
              ~fee_parameter
              ?fee
              ~source
              ~src_pk
              ~src_sk
              contract
              None
            >>= fun errors ->
            report_michelson_errors
              ~no_print_source:true
              ~msg:"Withdrawing delegate through entrypoints failed."
              cctxt
              errors
            >>= fun _ -> return_unit
        | Implicit mgr ->
            Client_keys.get_key cctxt mgr >>=? fun (_, src_pk, manager_sk) ->
            set_delegate
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~dry_run
              ~verbose_signing
              ~fee_parameter
              mgr
              None
              ?fee
              ~src_pk
              ~manager_sk
            >>= fun _ -> return_unit);
    command
      ~group
      ~desc:"Launch a smart contract on the blockchain."
      (args10
         fee_arg
         dry_run_switch
         verbose_signing_switch
         gas_limit_arg
         storage_limit_arg
         delegate_arg
         (Client_keys.force_switch ())
         init_arg
         no_print_source_flag
         fee_parameter_args)
      (prefixes ["originate"; "contract"]
      @@ RawContractAlias.fresh_alias_param
           ~name:"new"
           ~desc:"name of the new contract"
      @@ prefix "transferring"
      @@ tez_param ~name:"qty" ~desc:"amount taken from source"
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"name of the source contract"
      @@ prefix "running"
      @@ Program.source_param
           ~name:"prg"
           ~desc:
             "script of the account\n\
              Combine with -init if the storage type is not unit."
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             gas_limit,
             storage_limit,
             delegate,
             force,
             initial_storage,
             no_print_source,
             fee_parameter )
           alias_name
           balance
           source
           program
           (cctxt : Protocol_client_context.full) ->
        RawContractAlias.of_fresh cctxt force alias_name >>=? fun alias_name ->
        Lwt.return (Micheline_parser.no_parsing_error program)
        >>=? fun {expanded = code; _} ->
        match source with
        | Originated _ ->
            failwith
              "only implicit accounts can be the source of an origination"
        | Implicit source -> (
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            originate_contract
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~dry_run
              ~verbose_signing
              ?fee
              ?gas_limit
              ?storage_limit
              ~delegate
              ~initial_storage
              ~balance
              ~source
              ~src_pk
              ~src_sk
              ~code
              ~fee_parameter
              ()
            >>= fun errors ->
            report_michelson_errors
              ~no_print_source
              ~msg:"origination simulation failed"
              cctxt
              errors
            >>= function
            | None -> return_unit
            | Some (_res, contract) ->
                if dry_run then return_unit
                else
                  save_contract ~force cctxt alias_name contract >>=? fun () ->
                  return_unit));
    command
      ~group
      ~desc:
        "Execute multiple transfers from a single source account.\n\
         If one of the transfers fails, none of them get executed."
      (args13
         default_fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         force_switch
         default_gas_limit_arg
         default_storage_limit_arg
         counter_arg
         default_arg_arg
         no_print_source_flag
         fee_parameter_args
         default_entrypoint_arg
         replace_by_fees_arg)
      (prefixes ["multiple"; "transfers"; "from"]
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"name of the source contract"
      @@ prefix "using"
      @@ param
           ~name:"transfers.json"
           ~desc:
             "List of operations originating from the source contract in JSON \
              format (from a file or directly inlined). The input JSON must be \
              an array of objects of the form: '[ {\"destination\": dst, \
              \"amount\": qty (, <field>: <val> ...) } (, ...) ]', where an \
              optional <field> can either be \"fee\", \"gas-limit\", \
              \"storage-limit\", \"arg\", or \"entrypoint\"."
           json_parameter
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             force,
             gas_limit,
             storage_limit,
             counter,
             arg,
             no_print_source,
             fee_parameter,
             entrypoint,
             replace_by_fees )
           source
           operations_json
           cctxt ->
        (* When --force is used we want to inject the transfer even if it fails.
           In that case we cannot rely on simulation to compute limits and fees
           so we require the corresponding options to be set. *)
        let check_force_dependency name = function
          | None ->
              cctxt#error
                "When the --force switch is used, the %s option is required."
                name
          | _ -> Lwt.return_unit
        in
        (if force && not simulation then
         check_force_dependency "--gas-limit" gas_limit >>= fun () ->
         check_force_dependency "--storage-limit" storage_limit >>= fun () ->
         check_force_dependency "--fee" fee
        else Lwt.return_unit)
        >>= fun () ->
        let prepare i =
          prepare_batch_operation
            cctxt
            ?arg
            ?fee
            ?gas_limit
            ?storage_limit
            ?entrypoint
            source
            i
        in
        match
          Data_encoding.Json.destruct
            (Data_encoding.list
               Client_proto_context.batch_transfer_operation_encoding)
            operations_json
        with
        | [] -> failwith "Empty operation list"
        | operations ->
            (match source with
            | Originated contract ->
                Managed_contract.get_contract_manager cctxt contract
                >>=? fun source ->
                Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
                return (source, src_pk, src_sk)
            | Implicit source ->
                Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
                return (source, src_pk, src_sk))
            >>=? fun (source, src_pk, src_sk) ->
            List.mapi_ep prepare operations >>=? fun contents ->
            let (Manager_list contents) =
              Annotated_manager_operation.manager_of_list contents
            in
            Injection.inject_manager_operation
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~dry_run
              ~verbose_signing
              ~simulation
              ~force
              ~source
              ~fee:(Limit.of_option fee)
              ~gas_limit:(Limit.of_option gas_limit)
              ~storage_limit:(Limit.of_option storage_limit)
              ?counter
              ~src_pk
              ~src_sk
              ~replace_by_fees
              ~fee_parameter
              contents
            >>= report_michelson_errors
                  ~no_print_source
                  ~msg:"multiple transfers simulation failed"
                  cctxt
            >>= fun _ -> return_unit
        | exception (Data_encoding.Json.Cannot_destruct (path, exn2) as exn)
          -> (
            match (path, operations_json) with
            | [`Index n], `A lj -> (
                match List.nth_opt lj n with
                | Some j ->
                    failwith
                      "Invalid transfer at index %i: %a %a"
                      n
                      (fun ppf -> Data_encoding.Json.print_error ppf)
                      exn2
                      Data_encoding.Json.pp
                      j
                | _ ->
                    failwith
                      "Invalid transfer at index %i: %a"
                      n
                      (fun ppf -> Data_encoding.Json.print_error ppf)
                      exn2)
            | _ ->
                failwith
                  "Invalid transfer file: %a %a"
                  (fun ppf -> Data_encoding.Json.print_error ppf)
                  exn
                  Data_encoding.Json.pp
                  operations_json));
    command
      ~group
      ~desc:"Transfer tokens / call a smart contract."
      (args14
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         force_switch
         gas_limit_arg
         storage_limit_arg
         counter_arg
         arg_arg
         no_print_source_flag
         fee_parameter_args
         entrypoint_arg
         replace_by_fees_arg
         successor_level_arg)
      (prefixes ["transfer"]
      @@ tez_param ~name:"qty" ~desc:"amount taken from source"
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"name of the source contract"
      @@ prefix "to"
      @@ ContractAlias.destination_param
           ~name:"dst"
           ~desc:"name/literal of the destination contract"
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             force,
             gas_limit,
             storage_limit,
             counter,
             arg,
             no_print_source,
             fee_parameter,
             entrypoint,
             replace_by_fees,
             successor_level )
           amount
           source
           destination
           cctxt ->
        transfer_command
          amount
          source
          destination
          cctxt
          ( fee,
            dry_run,
            verbose_signing,
            simulation,
            force,
            gas_limit,
            storage_limit,
            counter,
            arg,
            no_print_source,
            fee_parameter,
            entrypoint,
            replace_by_fees,
            successor_level ));
    command
      ~group
      ~desc:"Register a global constant"
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["register"; "global"; "constant"]
      @@ global_constant_param
           ~name:"expression"
           ~desc:
             "Michelson expression to register. Note the value is not \
              typechecked before registration."
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"name of the account registering the global constant"
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           global_constant_str
           source
           cctxt ->
        match source with
        | Originated _ ->
            failwith "Only implicit accounts can register global constants"
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            register_global_constant
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~constant:global_constant_str
              ()
            >>= fun errors ->
            report_michelson_errors
              ~no_print_source:false
              ~msg:"register global constant simulation failed"
              cctxt
              errors
            >>= fun _ -> return_unit);
    command
      ~group
      ~desc:"Call a smart contract (same as 'transfer 0')."
      (args14
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         force_switch
         gas_limit_arg
         storage_limit_arg
         counter_arg
         arg_arg
         no_print_source_flag
         fee_parameter_args
         entrypoint_arg
         replace_by_fees_arg
         successor_level_arg)
      (prefixes ["call"]
      @@ ContractAlias.destination_param
           ~name:"dst"
           ~desc:"name/literal of the destination contract"
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"name of the source contract"
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             force,
             gas_limit,
             storage_limit,
             counter,
             arg,
             no_print_source,
             fee_parameter,
             entrypoint,
             replace_by_fees,
             successor_level )
           destination
           source
           cctxt ->
        let amount = Tez.zero in
        transfer_command
          amount
          source
          destination
          cctxt
          ( fee,
            dry_run,
            verbose_signing,
            simulation,
            force,
            gas_limit,
            storage_limit,
            counter,
            arg,
            no_print_source,
            fee_parameter,
            entrypoint,
            replace_by_fees,
            successor_level ));
    command
      ~group
      ~desc:"Reveal the public key of the contract manager."
      (args4 fee_arg dry_run_switch verbose_signing_switch fee_parameter_args)
      (prefixes ["reveal"; "key"; "for"]
      @@ ContractAlias.alias_param
           ~name:"src"
           ~desc:"name of the source contract"
      @@ stop)
      (fun (fee, dry_run, verbose_signing, fee_parameter) source cctxt ->
        match source with
        | Originated _ -> failwith "only implicit accounts can be revealed"
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            reveal
              cctxt
              ~dry_run
              ~verbose_signing
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~source
              ?fee
              ~src_pk
              ~src_sk
              ~fee_parameter
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Register the public key hash as a delegate."
      (args4 fee_arg dry_run_switch verbose_signing_switch fee_parameter_args)
      (prefixes ["register"; "key"]
      @@ Public_key_hash.source_param ~name:"mgr" ~desc:"the delegate key"
      @@ prefixes ["as"; "delegate"]
      @@ stop)
      (fun (fee, dry_run, verbose_signing, fee_parameter) src_pkh cctxt ->
        Client_keys.get_key cctxt src_pkh >>=? fun (_, src_pk, src_sk) ->
        register_as_delegate
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ?confirmations:cctxt#confirmations
          ~dry_run
          ~fee_parameter
          ~verbose_signing
          ?fee
          ~manager_sk:src_sk
          src_pk
        >>= function
        | Ok _ -> return_unit
        | Error [Environment.Ecoproto_error Delegate_storage.Active_delegate] ->
            cctxt#message "Delegate already activated." >>= fun () ->
            return_unit
        | Error el -> Lwt.return_error el);
    command
      ~desc:"Wait until an operation is included in a block"
      (args3
         (default_arg
            ~long:"confirmations"
            ~placeholder:"num_blocks"
            ~doc:
              "wait until 'N' additional blocks after the operation appears in \
               the considered chain"
            ~default:"0"
            non_negative_parameter)
         (default_arg
            ~long:"check-previous"
            ~placeholder:"num_blocks"
            ~doc:"number of previous blocks to check"
            ~default:"10"
            non_negative_parameter)
         (arg
            ~long:"branch"
            ~placeholder:"block_hash"
            ~doc:
              "hash of the oldest block where we should look for the operation"
            block_hash_param))
      (prefixes ["wait"; "for"]
      @@ param
           ~name:"operation"
           ~desc:"Operation to be included"
           (parameter (fun _ x ->
                match Operation_hash.of_b58check_opt x with
                | None -> Error_monad.failwith "Invalid operation hash: '%s'" x
                | Some hash -> return hash))
      @@ prefixes ["to"; "be"; "included"]
      @@ stop)
      (fun (confirmations, predecessors, branch)
           operation_hash
           (ctxt : Protocol_client_context.full) ->
        Client_confirmations.wait_for_operation_inclusion
          ctxt
          ~chain:ctxt#chain
          ~confirmations
          ~predecessors
          ?branch
          operation_hash
        >>=? fun _ -> return_unit);
    command
      ~group
      ~desc:"Submit protocol proposals"
      (args3
         dry_run_switch
         verbose_signing_switch
         (switch
            ~doc:
              "Do not fail when the checks that try to prevent the user from \
               shooting themselves in the foot do fail."
            ~long:"force"
            ()))
      (prefixes ["submit"; "proposals"; "for"]
      @@ ContractAlias.destination_param
           ~name:"delegate"
           ~desc:"the delegate who makes the proposal"
      @@ seq_of_param
           (param
              ~name:"proposal"
              ~desc:"the protocol hash proposal to be submitted"
              (parameter (fun _ x ->
                   match Protocol_hash.of_b58check_opt x with
                   | None ->
                       Error_monad.failwith "Invalid proposal hash: '%s'" x
                   | Some hash -> return hash))))
      (fun (dry_run, verbose_signing, force)
           source
           proposals
           (cctxt : Protocol_client_context.full) ->
        match source with
        | Originated _ -> failwith "only implicit accounts can submit proposals"
        | Implicit src_pkh -> (
            Client_keys.get_key cctxt src_pkh
            >>=? fun (src_name, _src_pk, src_sk) ->
            get_period_info
            (* Find period info of the successor, because the operation will
               be injected on the next block at the earliest *)
              ~successor:true
              ~chain:cctxt#chain
              ~block:cctxt#block
              cctxt
            >>=? fun info ->
            (match info.current_period_kind with
            | Proposal -> Lwt.return_unit
            | _ ->
                (if force then cctxt#warning else cctxt#error)
                  "Not in a proposal period")
            >>= fun () ->
            Shell_services.Protocol.list cctxt >>=? fun known_protos ->
            get_proposals ~chain:cctxt#chain ~block:cctxt#block cctxt
            >>=? fun known_proposals ->
            (Alpha_services.Delegate.voting_power
               cctxt
               (cctxt#chain, cctxt#block)
               src_pkh
             >>= function
             | Ok voting_power -> return (voting_power <> 0L)
             | Error
                 (Environment.Ecoproto_error (Delegate_storage.Not_registered _)
                 :: _) ->
                 return false
             | Error _ as err -> Lwt.return err)
            >>=? fun has_voting_power ->
            (* for a proposal to be valid it must either a protocol that was already
               proposed by somebody else or a protocol known by the node, because
               the user is the first proposer and just injected it with
               tezos-admin-client *)
            let check_proposals proposals : bool tzresult Lwt.t =
              let errors = ref [] in
              let error ppf =
                Format.kasprintf (fun s -> errors := s :: !errors) ppf
              in
              if proposals = [] then error "Empty proposal list." ;
              if
                Compare.List_length_with.(
                  proposals > Constants.max_proposals_per_delegate)
              then
                error
                  "Too many proposals: %d > %d."
                  (List.length proposals)
                  Constants.max_proposals_per_delegate ;
              (match
                 Base.List.find_all_dups
                   ~compare:Protocol_hash.compare
                   proposals
               with
              | [] -> ()
              | dups ->
                  error
                    "There %s: %a."
                    (if Compare.List_length_with.(dups = 1) then
                     "is a duplicate proposal"
                    else "are duplicate proposals")
                    Format.(
                      pp_print_list
                        ~pp_sep:(fun ppf () -> pp_print_string ppf ", ")
                        Protocol_hash.pp)
                    dups) ;
              List.iter
                (fun (p : Protocol_hash.t) ->
                  if
                    List.mem ~equal:Protocol_hash.equal p known_protos
                    || Environment.Protocol_hash.Map.mem p known_proposals
                  then ()
                  else
                    error
                      "Protocol %a is not a known proposal."
                      Protocol_hash.pp
                      p)
                proposals ;
              if not has_voting_power then
                error
                  "Public-key-hash `%a` from account `%s` does not appear to \
                   have voting rights."
                  Signature.Public_key_hash.pp
                  src_pkh
                  src_name ;
              if !errors <> [] then
                cctxt#message
                  "There %s with the submission:%t"
                  (if Compare.List_length_with.(!errors = 1) then "is an issue"
                  else "are issues")
                  Format.(
                    fun ppf ->
                      pp_print_cut ppf () ;
                      pp_open_vbox ppf 0 ;
                      List.iter
                        (fun msg ->
                          pp_open_hovbox ppf 2 ;
                          pp_print_string ppf "* " ;
                          pp_print_text ppf msg ;
                          pp_close_box ppf () ;
                          pp_print_cut ppf ())
                        !errors ;
                      pp_close_box ppf ())
                >>= fun () -> return_false
              else return_true
            in
            check_proposals proposals >>=? fun all_valid ->
            (if all_valid then cctxt#message "All proposals are valid."
            else if force then
              cctxt#message
                "Some proposals are not valid, but `--force` was used."
            else cctxt#error "Submission failed because of invalid proposals.")
            >>= fun () ->
            submit_proposals
              ~dry_run
              ~verbose_signing
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~src_sk
              src_pkh
              proposals
            >>= function
            | Ok _res -> return_unit
            | Error errs ->
                (match errs with
                | [
                 Unregistered_error
                   (`O [("kind", `String "generic"); ("error", `String msg)]);
                ] ->
                    cctxt#message
                      "Error:@[<hov>@.%a@]"
                      Format.pp_print_text
                      (String.split_on_char ' ' msg
                      |> List.filter (function "" | "\n" -> false | _ -> true)
                      |> String.concat " "
                      |> String.map (function '\n' | '\t' -> ' ' | c -> c))
                | el -> cctxt#message "Error:@ %a" pp_print_trace el)
                >>= fun () -> failwith "Failed to submit proposals"));
    command
      ~group
      ~desc:"Submit a ballot"
      (args3
         verbose_signing_switch
         dry_run_switch
         (switch
            ~doc:
              "Do not fail when the checks that try to prevent the user from \
               shooting themselves in the foot do fail."
            ~long:"force"
            ()))
      (prefixes ["submit"; "ballot"; "for"]
      @@ ContractAlias.destination_param
           ~name:"delegate"
           ~desc:"the delegate who votes"
      @@ param
           ~name:"proposal"
           ~desc:"the protocol hash proposal to vote for"
           (parameter (fun _ x ->
                match Protocol_hash.of_b58check_opt x with
                | None -> failwith "Invalid proposal hash: '%s'" x
                | Some hash -> return hash))
      @@ param
           ~name:"ballot"
           ~desc:"the ballot value (yea/yay, nay, or pass)"
           (parameter
              ~autocomplete:(fun _ -> return ["yea"; "nay"; "pass"])
              (fun _ s ->
                (* We should have [Vote.of_string]. *)
                match String.lowercase_ascii s with
                | "yay" | "yea" -> return Vote.Yay
                | "nay" -> return Vote.Nay
                | "pass" -> return Vote.Pass
                | s -> failwith "Invalid ballot: '%s'" s))
      @@ stop)
      (fun (verbose_signing, dry_run, force)
           source
           proposal
           ballot
           (cctxt : Protocol_client_context.full) ->
        match source with
        | Originated _ -> failwith "only implicit accounts can submit ballot"
        | Implicit src_pkh ->
            Client_keys.get_key cctxt src_pkh
            >>=? fun (src_name, _src_pk, src_sk) ->
            get_period_info
            (* Find period info of the successor, because the operation will
               be injected on the next block at the earliest *)
              ~successor:true
              ~chain:cctxt#chain
              ~block:cctxt#block
              cctxt
            >>=? fun info ->
            Alpha_services.Voting.current_proposal
              cctxt
              (cctxt#chain, cctxt#block)
            >>=? fun current_proposal ->
            (match (info.current_period_kind, current_proposal) with
            | (Exploration | Promotion), Some current_proposal ->
                if Protocol_hash.equal proposal current_proposal then
                  return_unit
                else
                  (if force then cctxt#warning else cctxt#error)
                    "Unexpected proposal, expected: %a"
                    Protocol_hash.pp
                    current_proposal
                  >>= fun () -> return_unit
            | _ ->
                (if force then cctxt#warning else cctxt#error)
                  "Not in Exploration or Promotion period"
                >>= fun () -> return_unit)
            >>=? fun () ->
            (Alpha_services.Delegate.voting_power
               cctxt
               (cctxt#chain, cctxt#block)
               src_pkh
             >>= function
             | Ok voting_power -> return (voting_power <> 0L)
             | Error
                 (Environment.Ecoproto_error (Delegate_storage.Not_registered _)
                 :: _) ->
                 return false
             | Error _ as err -> Lwt.return err)
            >>=? fun has_voting_power ->
            (if has_voting_power then Lwt.return_unit
            else
              (if force then cctxt#warning else cctxt#error)
                "Public-key-hash `%a` from account `%s` does not appear to \
                 have voting rights."
                Signature.Public_key_hash.pp
                src_pkh
                src_name)
            >>= fun () ->
            submit_ballot
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~src_sk
              src_pkh
              ~verbose_signing
              ~dry_run
              proposal
              ballot
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Set the deposits limit of a registered delegate."
      (args5
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args)
      (prefixes ["set"; "deposits"; "limit"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ prefix "to"
      @@ tez_param
           ~name:"deposits limit"
           ~desc:"the maximum amount of frozen deposits"
      @@ stop)
      (fun (fee, dry_run, verbose_signing, simulation, fee_parameter)
           contract
           limit
           (cctxt : Protocol_client_context.full) ->
        match contract with
        | Originated _ ->
            cctxt#error
              "Cannot change deposits limit on contract %a. This operation is \
               invalid on originated contracts or unregistered delegate \
               contracts."
              Contract.pp
              contract
        | Implicit mgr ->
            Client_keys.get_key cctxt mgr >>=? fun (_, src_pk, manager_sk) ->
            set_deposits_limit
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~dry_run
              ~verbose_signing
              ~simulation
              ~fee_parameter
              ?fee
              mgr
              ~src_pk
              ~manager_sk
              (Some limit)
            >>=? fun _ -> return_unit);
    command
      ~group
      ~desc:"Remove the deposits limit of a registered delegate."
      (args5
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args)
      (prefixes ["unset"; "deposits"; "limit"; "for"]
      @@ ContractAlias.destination_param ~name:"src" ~desc:"source contract"
      @@ stop)
      (fun (fee, dry_run, verbose_signing, simulation, fee_parameter)
           contract
           (cctxt : Protocol_client_context.full) ->
        match contract with
        | Originated _ ->
            cctxt#error
              "Cannot change deposits limit on contract %a. This operation is \
               invalid on originated contracts or unregistered delegate \
               contracts."
              Contract.pp
              contract
        | Implicit mgr ->
            Client_keys.get_key cctxt mgr >>=? fun (_, src_pk, manager_sk) ->
            set_deposits_limit
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ?confirmations:cctxt#confirmations
              ~dry_run
              ~verbose_signing
              ~simulation
              ~fee_parameter
              ?fee
              mgr
              ~src_pk
              ~manager_sk
              None
            >>=? fun _ -> return_unit);
    command
      ~group
      ~desc:"Increase the paid storage of a smart contract."
      (args6
         force_switch
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args)
      (prefixes ["increase"; "the"; "paid"; "storage"; "of"]
      @@ OriginatedContractAlias.destination_param
           ~name:"contract"
           ~desc:"name of the smart contract"
      @@ prefix "by"
      @@ non_negative_z_param ~name:"amount" ~desc:"amount of increase in bytes"
      @@ prefixes ["bytes"; "from"]
      @@ Public_key_hash.source_param
           ~name:"payer"
           ~desc:"payer of the storage increase"
      @@ stop)
      (fun (force, fee, dry_run, verbose_signing, simulation, fee_parameter)
           contract
           amount_in_bytes
           payer
           (cctxt : Protocol_client_context.full) ->
        Client_keys.get_key cctxt payer >>=? fun (_, src_pk, manager_sk) ->
        increase_paid_storage
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ~force
          ~dry_run
          ~verbose_signing
          ?fee
          ?confirmations:cctxt#confirmations
          ~simulation
          ~source:payer
          ~src_pk
          ~manager_sk
          ~destination:contract
          ~fee_parameter
          ~amount_in_bytes
          ()
        >>=? fun _ -> return_unit);
    command
      ~group
      ~desc:"Launch a new transaction rollup."
      (args8
         force_switch
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["originate"; "tx"; "rollup"]
      @@ TxRollupAlias.fresh_alias_param
           ~name:"tx_rollup"
           ~desc:"Fresh name for a transaction rollup"
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"Account originating the transaction rollup."
      @@ stop)
      (fun ( force,
             fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           alias
           source
           cctxt ->
        match source with
        | Originated _ ->
            failwith "Only implicit accounts can originate transaction rollups"
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            Protocol_client_context.Alpha_block_services.Header.shell_header
              cctxt
              ()
            >>=? fun {level = head_level; _} ->
            originate_tx_rollup
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ()
            >>=? fun res ->
            TxRollupAlias.of_fresh cctxt force alias >>=? fun alias_name ->
            (match res with
            | ( _,
                _,
                Apply_results.Manager_operation_result
                  {
                    operation_result =
                      Apply_operation_result.Applied
                        (Apply_results.Tx_rollup_origination_result
                          {originated_tx_rollup; _});
                    _;
                  } ) ->
                ok originated_tx_rollup
            | _ -> error_with "transaction rollup was not correctly originated")
            >>?= fun res ->
            (* Approximate origination level, needs to be <= actual origination
               level *)
            let origination_level = Some head_level in
            save_tx_rollup ~force cctxt alias_name res ~origination_level);
    command
      ~group
      ~desc:"Submit a batch of transaction rollup operations."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["submit"; "tx"; "rollup"; "batch"]
      @@ Clic.param
           ~name:"batch"
           ~desc:
             "Bytes representation (hexadecimal string) of the batch. Must be \
              prefixed by '0x'."
           bytes_parameter
      @@ prefix "to"
      @@ Tx_rollup.tx_rollup_address_param
           ~usage:"Tx rollup receiving the batch."
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"Account submitting the transaction rollup batches."
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           content
           tx_rollup
           source
           cctxt ->
        match source with
        | Originated _ ->
            failwith
              "Only implicit accounts can submit transaction rollup batches"
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            submit_tx_rollup_batch
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~tx_rollup
              ~content:(Bytes.to_string content)
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:
        "Commit to a transaction rollup for an inbox and level.\n\n\
         The provided list of message result hash must be ordered in the same \
         way the messages were ordered in the inbox."
      (args8
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg
         (Tx_rollup.commitment_hash_arg
            ~long:"predecessor-hash"
            ~usage:
              "Predecessor commitment hash, empty for the first commitment."
            ()))
      (prefixes ["commit"; "to"; "tx"; "rollup"]
      @@ Tx_rollup.tx_rollup_address_param
           ~usage:"Transaction rollup address committed to."
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"Account committing to the transaction rollup."
      @@ prefixes ["for"; "level"]
      @@ Tx_rollup.level_param ~usage:"Level used for the commitment."
      @@ prefixes ["with"; "inbox"; "hash"]
      @@ Tx_rollup.inbox_root_hash_param ~usage:"Inbox used for the commitment."
      @@ prefixes ["and"; "messages"; "result"; "hash"]
      @@ seq_of_param
           (Tx_rollup.message_result_hash_param
              ~usage:
                "Message result hash of a message from the inbox being \
                 committed."))
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter,
             predecessor )
           tx_rollup
           source
           level
           inbox_merkle_root
           messages
           cctxt ->
        match source with
        | Originated _ ->
            failwith
              "Only implicit accounts can submit transaction rollup commitments"
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            submit_tx_rollup_commitment
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~tx_rollup
              ~level
              ~inbox_merkle_root
              ~messages
              ~predecessor
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Finalize a commitment of an transaction rollup."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         storage_limit_arg
         fee_parameter_args
         simulate_switch
         counter_arg)
      (prefixes ["finalize"; "commitment"; "of"; "tx"; "rollup"]
      @@ Tx_rollup.tx_rollup_address_param
           ~usage:"Tx rollup that have his commitment finalized."
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"Account finalizing the commitment."
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             storage_limit,
             fee_parameter,
             simulation,
             counter )
           tx_rollup
           source
           cctxt ->
        match source with
        | Originated _ ->
            failwith "Only implicit accounts can finalize commitments"
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            submit_tx_rollup_finalize_commitment
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~tx_rollup
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Recover commitment bond from an transaction rollup."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["recover"; "bond"; "of"]
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"Account that owns the bond."
      @@ prefixes ["for"; "tx"; "rollup"]
      @@ Tx_rollup.tx_rollup_address_param ~usage:"Tx rollup of the bond."
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           source
           tx_rollup
           cctxt ->
        match source with
        | Originated _ ->
            failwith "Only implicit accounts can deposit/recover bonds"
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            submit_tx_rollup_return_bond
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~tx_rollup
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Remove a commitment from an transaction rollup."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["remove"; "commitment"; "of"; "tx"; "rollup"]
      @@ Tx_rollup.tx_rollup_address_param
           ~usage:"Tx rollup that have his commitment removed."
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"name of the account removing the commitment."
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           tx_rollup
           source
           cctxt ->
        match source with
        | Originated _ ->
            failwith "Only implicit accounts can remove commitments."
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            submit_tx_rollup_remove_commitment
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~tx_rollup
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Reject a commitment of an transaction rollup."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["reject"; "commitment"; "of"; "tx"; "rollup"]
      @@ Tx_rollup.tx_rollup_address_param
           ~usage:"Tx rollup that have one of his commitment rejected."
      @@ prefixes ["at"; "level"]
      @@ Tx_rollup.level_param ~usage:"Level of the commitment disputed."
      @@ prefixes ["with"; "result"; "hash"]
      @@ Tx_rollup.message_result_hash_param
           ~usage:"Disputed message result hash."
      @@ prefixes ["and"; "result"; "path"]
      @@ Tx_rollup.message_result_path_param
           ~usage:"Disputed message result path."
      @@ prefixes ["for"; "message"; "at"; "position"]
      @@ Clic.param
           ~name:"message position"
           ~desc:
             "Position of the message in the inbox with the result being \
              disputed."
           non_negative_parameter
      @@ prefixes ["with"; "content"]
      @@ Tx_rollup.message_param
           ~usage:"Message content with the result being disputed."
      @@ prefixes ["and"; "path"]
      @@ Tx_rollup.message_path_param
           ~usage:"Path of the message with the result being disputed."
      @@ prefixes ["with"; "agreed"; "context"; "hash"]
      @@ Tx_rollup.context_hash_param
           ~usage:
             (Format.sprintf
                "@[Context hash of the precedent message result in the \
                 commitment.@,\
                 @[This must be the context hash of the last message result \
                 agreed on.@]@]")
      @@ prefixes ["and"; "withdraw"; "list"; "hash"]
      @@ Tx_rollup.withdraw_list_hash_param
           ~usage:
             (Format.sprintf
                "@[Withdraw list hash of the precedent message result in the \
                 commitment.@,\
                 @[This must be the withdraw list hash of the last message \
                 result agreed on.@]@]")
      @@ prefixes ["and"; "result"; "path"]
      @@ Tx_rollup.message_result_path_param
           ~usage:"Precedent message result path."
      @@ prefixes ["using"; "proof"]
      @@ Tx_rollup.proof_param
           ~usage:
             "Proof that the disputed message result provided is incorrect."
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"Account rejecting the commitment."
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           tx_rollup
           level
           rejected_message_result_hash
           rejected_message_result_path
           conflicting_message_position
           conflicting_message
           conflicting_message_path
           previous_context_hash
           previous_withdraw_list_hash
           previous_message_result_path
           proof
           source
           cctxt ->
        match source with
        | Originated _ ->
            failwith
              "Only implicit accounts can reject transaction rollup \
               commitments."
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            submit_tx_rollup_rejection
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~tx_rollup
              ~level
              ~message:conflicting_message
              ~message_position:conflicting_message_position
              ~message_path:conflicting_message_path
              ~message_result_hash:rejected_message_result_hash
              ~message_result_path:rejected_message_result_path
              ~proof
              ~previous_context_hash
              ~previous_withdraw_list_hash
              ~previous_message_result_path
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:
        "Dispatch tickets withdrawn from a transaction rollup to owners. The \
         withdrawals are part of a finalized commitment of the transaction \
         rollup. Owners are implicit accounts who can then transfer the \
         tickets to smart contracts using the \"transfer tickets\" command. \
         See transaction rollups documentation for more information.\n\n\
         The provided list of ticket information must be ordered as in \
         withdrawal list computed by the application of the message."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["dispatch"; "tickets"; "of"; "tx"; "rollup"]
      @@ Tx_rollup.tx_rollup_address_param
           ~usage:"Tx rollup which have some tickets dispatched."
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"source"
           ~desc:"Account used to dispatch tickets."
      @@ prefixes ["at"; "level"]
      @@ Tx_rollup.level_param
           ~usage:
             "Level of the finalized commitment that includes the message \
              result whose withdrawals will be dispatched."
      @@ prefixes ["for"; "the"; "message"; "at"; "index"]
      @@ Clic.param
           ~name:"message index"
           ~desc:"Index of the message whose withdrawals will be dispatched."
           non_negative_parameter
      @@ prefixes ["with"; "the"; "context"; "hash"]
      @@ Tx_rollup.context_hash_param
           ~usage:
             "Context hash of the message result in the commitment whose \
              withdrawals will be dispatched."
      @@ prefixes ["and"; "path"]
      @@ Tx_rollup.message_result_path_param
           ~usage:
             "Path of the message result whose withdrawals will be dispatched."
      @@ prefixes ["and"; "tickets"; "info"]
      @@ seq_of_param
           (Tx_rollup.tickets_dispatch_info_param
              ~usage:"Information needed to dispatch tickets to its owner."))
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           tx_rollup
           source
           level
           message_position
           context_hash
           message_result_path
           tickets_info
           cctxt ->
        match source with
        | Originated _ ->
            failwith
              "Only implicit account can dispatch tickets for a transaction \
               rollup."
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            tx_rollup_dispatch_tickets
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~level
              ~context_hash
              ~message_position
              ~message_result_path
              ~tickets_info
              ~tx_rollup
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Transfer tickets from an implicit account to a contract."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefix "transfer"
      @@ non_negative_z_param ~name:"qty" ~desc:"Amount of tickets to transfer."
      @@ prefixes ["tickets"; "from"]
      @@ ContractAlias.destination_param
           ~name:"tickets owner"
           ~desc:"Implicit account owning the tickets."
      @@ prefix "to"
      @@ ContractAlias.destination_param
           ~name:"recipient contract"
           ~desc:"Contract receiving the tickets."
      @@ prefixes ["with"; "entrypoint"]
      @@ Clic.param
           ~name:"entrypoint"
           ~desc:"Entrypoint to use on the receiving contract."
           entrypoint_parameter
      @@ prefixes ["and"; "contents"]
      @@ Clic.param
           ~name:"tickets content"
           ~desc:"Content of the tickets."
           Client_proto_args.string_parameter
      @@ prefixes ["and"; "type"]
      @@ Clic.param
           ~name:"tickets type"
           ~desc:"Type of the tickets."
           Client_proto_args.string_parameter
      @@ prefixes ["and"; "ticketer"]
      @@ ContractAlias.destination_param
           ~name:"tickets ticketer"
           ~desc:"Ticketer contract of the tickets."
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           amount
           source
           destination
           entrypoint
           contents
           ty
           ticketer
           cctxt ->
        match source with
        | Originated _ ->
            failwith "Only implicit accounts can transfer tickets."
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            transfer_ticket
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~contents
              ~ty
              ~ticketer
              ~amount
              ~destination
              ~entrypoint
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Originate a new smart-contract rollup."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["originate"; "sc"; "rollup"; "from"]
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"Name of the account originating the smart-contract rollup."
      @@ prefixes ["of"; "kind"]
      @@ param
           ~name:"sc_rollup_kind"
           ~desc:"Kind of the smart-contract rollup to be originated."
           Sc_rollup_params.rollup_kind_parameter
      @@ prefixes ["of"; "type"]
      @@ param
           ~name:"parameters_type"
           ~desc:
             "The type of parameters that the smart-contract rollup accepts."
           data_parameter
      @@ prefixes ["booting"; "with"]
      @@ param
           ~name:"boot_sector"
           ~desc:"The initialization state for the smart-contract rollup."
           Sc_rollup_params.boot_sector_parameter
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           source
           pvm
           parameters_ty
           boot_sector
           cctxt ->
        match source with
        | Originated _ ->
            failwith
              "Only implicit accounts can originate smart-contract rollups"
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            let (module R : Sc_rollup.PVM.S) = pvm in
            let Michelson_v1_parser.{expanded; _} = parameters_ty in
            let parameters_ty = Script.lazy_expr expanded in
            boot_sector pvm >>=? fun boot_sector ->
            sc_rollup_originate
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~kind:(Sc_rollup.Kind.of_pvm pvm)
              ~boot_sector
              ~parameters_ty
              ()
            >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Send one or more messages to a smart-contract rollup."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["send"; "sc"; "rollup"; "message"]
      @@ param
           ~name:"messages"
           ~desc:
             "The message(s) to be sent to the rollup (syntax: \
              bin:<path_to_binary_file>|text:<json list of string \
              messages>|file:<json_file>)."
           Sc_rollup_params.messages_parameter
      @@ prefixes ["from"]
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"Name of the source contract."
      @@ prefixes ["to"]
      @@ param
           ~name:"dst"
           ~desc:"Address of the destination smart-contract rollup."
           Sc_rollup_params.sc_rollup_address_parameter
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           messages
           source
           rollup
           cctxt ->
        (match source with
        | Originated _ ->
            failwith "Only implicit accounts can send messages to rollups"
        | Implicit source -> return source)
        >>=? fun source ->
        (match messages with
        | `Bin message -> return [message]
        | `Json messages -> (
            match Data_encoding.(Json.destruct (list string) messages) with
            | exception _ ->
                failwith
                  "Could not read list of messages (expected list of bytes)"
            | messages -> return messages))
        >>=? fun messages ->
        Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
        sc_rollup_add_messages
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ?dry_run:(Some dry_run)
          ?verbose_signing:(Some verbose_signing)
          ?fee
          ?storage_limit
          ?counter
          ?confirmations:cctxt#confirmations
          ~simulation
          ~source
          ~rollup
          ~messages
          ~src_pk
          ~src_sk
          ~fee_parameter
          ()
        >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Cement a commitment for a sc rollup."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         storage_limit_arg
         counter_arg
         fee_parameter_args)
      (prefixes ["cement"; "commitment"]
      @@ param
           ~name:"commitment"
           ~desc:"The hash of the commitment to be cemented for a sc rollup."
           Sc_rollup_params.commitment_hash_parameter
      @@ prefixes ["from"]
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"Name of the source contract."
      @@ prefixes ["for"; "sc"; "rollup"]
      @@ param
           ~name:"sc_rollup"
           ~desc:
             "The address of the sc rollup where the commitment will be \
              cemented."
           Sc_rollup_params.sc_rollup_address_parameter
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             storage_limit,
             counter,
             fee_parameter )
           commitment
           source
           rollup
           cctxt ->
        (match source with
        | Originated _ ->
            failwith "Only implicit accounts can cement commitments"
        | Implicit source -> return source)
        >>=? fun source ->
        Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
        sc_rollup_cement
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ~dry_run
          ~verbose_signing
          ?fee
          ?storage_limit
          ?counter
          ?confirmations:cctxt#confirmations
          ~simulation
          ~source
          ~rollup
          ~commitment
          ~src_pk
          ~src_sk
          ~fee_parameter
          ()
        >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"List originated smart-contract rollups."
      no_options
      (prefixes ["list"; "sc"; "rollups"] @@ stop)
      (fun () (cctxt : Protocol_client_context.full) ->
        Plugin.RPC.Sc_rollup.list cctxt (cctxt#chain, cctxt#block)
        >>=? fun rollups ->
        List.iter_s
          (fun addr -> cctxt#message "%s" (Sc_rollup.Address.to_b58check addr))
          rollups
        >>= fun () -> return_unit);
    command
      ~group
      ~desc:
        "Execute a message from a smart-contract rollup's outbox of a cemented \
         commitment."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["execute"; "outbox"; "message"; "of"; "sc"; "rollup"]
      @@ param
           ~name:"rollup"
           ~desc:
             "The address of the smart-contract rollup where the message \
              resides."
           Sc_rollup_params.sc_rollup_address_parameter
      @@ prefix "from"
      @@ ContractAlias.destination_param
           ~name:"source"
           ~desc:"The account used for executing the outbox message."
      @@ prefixes ["for"; "commitment"; "hash"]
      @@ param
           ~name:"cemented commitment"
           ~desc:"The hash of the cemented commitment of the rollup."
           Sc_rollup_params.commitment_hash_parameter
      @@ prefixes ["for"; "the"; "outbox"; "level"]
      @@ param
           ~name:"outbox level"
           ~desc:"The level of the rollup's outbox."
           raw_level_parameter
      @@ prefixes ["for"; "the"; "message"; "at"; "index"]
      @@ param
           ~name:"message index"
           ~desc:"The index of the rollup's outbox containing the message."
           non_negative_parameter
      @@ prefixes ["and"; "inclusion"; "proof"]
      @@ param
           ~name:"inclusion proof"
           ~desc:"The inclusion proof for the message."
           Sc_rollup_params.unchecked_payload_parameter
      @@ prefixes ["and"; "message"]
      @@ param
           ~name:"message"
           ~desc:"The message to be executed."
           Sc_rollup_params.unchecked_payload_parameter
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           rollup
           source
           cemented_commitment
           outbox_level
           message_index
           inclusion_proof
           message
           cctxt ->
        (match source with
        | Originated _ ->
            failwith
              "Only implicit accounts can execute an sc rollup batch of \
               transactions"
        | Implicit source -> return source)
        >>=? fun source ->
        Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
        sc_rollup_execute_outbox_message
          cctxt
          ~chain:cctxt#chain
          ~block:cctxt#block
          ~dry_run
          ~verbose_signing
          ?fee
          ?storage_limit
          ?counter
          ?confirmations:cctxt#confirmations
          ~simulation
          ~source
          ~rollup
          ~cemented_commitment
          ~outbox_level
          ~message_index
          ~inclusion_proof
          ~message
          ~src_pk
          ~src_sk
          ~fee_parameter
          ()
        >>=? fun _res -> return_unit);
    command
      ~group
      ~desc:"Recover commitment bond from a smart contract rollup."
      (args7
         fee_arg
         dry_run_switch
         verbose_signing_switch
         simulate_switch
         fee_parameter_args
         storage_limit_arg
         counter_arg)
      (prefixes ["recover"; "bond"; "of"]
      @@ ContractAlias.destination_param
           ~name:"src"
           ~desc:"The implicit account that owns the frozen bond."
      @@ prefixes ["for"; "sc"; "rollup"]
      @@ Clic.param
           ~name:"smart contract rollup address"
           ~desc:"The address of the smart-contract rollup of the bond."
           Sc_rollup_params.sc_rollup_address_parameter
      @@ stop)
      (fun ( fee,
             dry_run,
             verbose_signing,
             simulation,
             fee_parameter,
             storage_limit,
             counter )
           source
           sc_rollup
           cctxt ->
        match source with
        | Originated _ ->
            failwith "Only implicit accounts can deposit/recover bonds"
        | Implicit source ->
            Client_keys.get_key cctxt source >>=? fun (_, src_pk, src_sk) ->
            sc_rollup_recover_bond
              cctxt
              ~chain:cctxt#chain
              ~block:cctxt#block
              ~dry_run
              ~verbose_signing
              ?fee
              ?storage_limit
              ?counter
              ?confirmations:cctxt#confirmations
              ~simulation
              ~source
              ~src_pk
              ~src_sk
              ~fee_parameter
              ~sc_rollup
              ()
            >>=? fun _res -> return_unit);
  ]

let commands network () =
  commands_rw () @ commands_network network () @ commands_ro ()
