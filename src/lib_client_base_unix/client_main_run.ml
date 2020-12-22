(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

(* Tezos Command line interface - Main Program *)

open Client_context_unix

let builtin_commands =
  let open Clic in
  [ command
      ~desc:"List the protocol versions that this client understands."
      no_options
      (fixed ["list"; "understood"; "protocols"])
      (fun () (cctxt : #Client_context.full) ->
        Seq.iter_s
          (fun (ver, _) -> cctxt#message "%a" Protocol_hash.pp_short ver)
          (Client_commands.get_versions ())
        >>= fun () -> return_unit) ]

module type M = sig
  type t

  val global_options : unit -> (t, Client_context_unix.unix_full) Clic.options

  val parse_config_args :
    #Tezos_client_base.Client_context.full ->
    string list ->
    (Client_config.parsed_config_args * string list) tzresult Lwt.t

  val default_chain : Chain_services.chain

  val default_block : [> `Head of int]

  val default_base_dir : string

  val other_registrations :
    (Client_config.Cfg_file.t -> (module Client_config.Remote_params) -> unit)
    option

  val clic_commands :
    base_dir:string ->
    config_commands:Tezos_client_base.Client_context.full Clic.command list ->
    builtin_commands:Tezos_client_base.Client_context.full Clic.command list ->
    other_commands:Tezos_client_base.Client_context.full Clic.command list ->
    require_auth:bool ->
    Tezos_client_base.Client_context.full Clic.command list

  val logger : RPC_client_unix.logger option
end

let setup_remote_signer (module C : M) client_config
    (rpc_config : RPC_client_unix.config) parsed_config_file =
  let module Remote_params = struct
    let authenticate pkhs payload =
      Client_keys.list_keys client_config
      >>=? fun keys ->
      match
        List.filter_map
          (function
            | (_, known_pkh, _, Some known_sk_uri)
              when List.exists
                     (fun pkh -> Signature.Public_key_hash.equal pkh known_pkh)
                     pkhs ->
                Some known_sk_uri
            | _ ->
                None)
          keys
      with
      | sk_uri :: _ ->
          Client_keys.sign client_config sk_uri payload
      | [] ->
          failwith
            "remote signer expects authentication signature, but no \
             authorized key was found in the wallet"

    let logger =
      (* overriding the logger we might already have with the one from
             module C *)
      match C.logger with Some logger -> logger | None -> rpc_config.logger
  end in
  let module Http =
    Tezos_signer_backends.Http.Make (RPC_client_unix) (Remote_params)
  in
  let module Https =
    Tezos_signer_backends.Https.Make (RPC_client_unix) (Remote_params)
  in
  let module Socket = Tezos_signer_backends_unix.Socket.Make (Remote_params) in
  Client_keys.register_signer
    ( module Tezos_signer_backends.Encrypted.Make (struct
      let cctxt = (client_config :> Client_context.prompter)
    end) ) ;
  Client_keys.register_signer (module Tezos_signer_backends.Unencrypted) ;
  Client_keys.register_signer
    (module Tezos_signer_backends_unix.Ledger.Signer_implementation) ;
  Client_keys.register_signer (module Socket.Unix) ;
  Client_keys.register_signer (module Socket.Tcp) ;
  Client_keys.register_signer (module Http) ;
  Client_keys.register_signer (module Https) ;
  match parsed_config_file with
  | None ->
      ()
  | Some parsed_config_file -> (
    match C.other_registrations with
    | Some r ->
        r parsed_config_file (module Remote_params)
    | None ->
        () )

let setup_http_rpc_client_config parsed_args base_dir rpc_config =
  (* Make sure that base_dir is not a mockup. *)
  ( match Tezos_mockup.Persistence.classify_base_dir base_dir with
  | Base_dir_is_mockup ->
      failwith
        "%s is setup as a mockup, yet mockup mode is not active"
        base_dir
  | _ ->
      return_unit )
  >>=? fun () ->
  return
  @@ new unix_full
       ~chain:
         ( match parsed_args with
         | Some p ->
             p.Client_config.chain
         | None ->
             Client_config.default_chain )
       ~block:
         ( match parsed_args with
         | Some p ->
             p.Client_config.block
         | None ->
             Client_config.default_block )
       ~confirmations:
         ( match parsed_args with
         | Some p ->
             p.Client_config.confirmations
         | None ->
             None )
       ~password_filename:
         ( match parsed_args with
         | Some p ->
             p.Client_config.password_filename
         | None ->
             None )
       ~base_dir
       ~rpc_config

let setup_mockup_rpc_client_config
    (cctxt : Tezos_client_base.Client_context.full)
    (args : Client_config.cli_args) base_dir =
  let in_memory_mockup (args : Client_config.cli_args) =
    match args.protocol with
    | None ->
        Tezos_mockup.Persistence.default_mockup_context cctxt
    | Some protocol_hash ->
        Tezos_mockup.Persistence.init_mockup_context_by_protocol_hash
          ~cctxt
          ~protocol_hash
          ~constants_overrides_json:None
          ~bootstrap_accounts_json:None
  in
  let base_dir_class = Tezos_mockup.Persistence.classify_base_dir base_dir in
  ( match base_dir_class with
  | Tezos_mockup.Persistence.Base_dir_is_empty
  | Tezos_mockup.Persistence.Base_dir_is_file
  | Tezos_mockup.Persistence.Base_dir_is_nonempty
  | Tezos_mockup.Persistence.Base_dir_does_not_exist ->
      let mem_only = true in
      in_memory_mockup args >>=? fun res -> return (res, mem_only)
  | Tezos_mockup.Persistence.Base_dir_is_mockup ->
      let mem_only = false in
      Tezos_mockup.Persistence.get_mockup_context_from_disk
        ~base_dir
        ~protocol_hash:args.protocol
      >>=? fun res -> return (res, mem_only) )
  >>=? fun ((mockup_env, (chain_id, rpc_context)), mem_only) ->
  return
    (new unix_mockup ~base_dir ~mem_only ~mockup_env ~chain_id ~rpc_context)

let setup_client_config (cctxt : Tezos_client_base.Client_context.full)
    (parsed_args : Client_config.cli_args option) base_dir rpc_config =
  match parsed_args with
  | None ->
      setup_http_rpc_client_config parsed_args base_dir rpc_config
  | Some args -> (
    match args.Client_config.client_mode with
    | Client_config.Mode_client ->
        setup_http_rpc_client_config parsed_args base_dir rpc_config
    | Client_config.Mode_mockup ->
        setup_mockup_rpc_client_config cctxt args base_dir )

(* Main (lwt) entry *)
let main (module C : M) ~select_commands =
  let global_options = C.global_options () in
  let executable_name = Filename.basename Sys.executable_name in
  let (original_args, autocomplete) =
    (* for shell aliases *)
    let rec move_autocomplete_token_upfront acc = function
      | "bash_autocomplete" :: prev_arg :: cur_arg :: script :: args ->
          let args = List.rev acc @ args in
          (args, Some (prev_arg, cur_arg, script))
      | x :: rest ->
          move_autocomplete_token_upfront (x :: acc) rest
      | [] ->
          (List.rev acc, None)
    in
    match Array.to_list Sys.argv with
    | _ :: args ->
        move_autocomplete_token_upfront [] args
    | [] ->
        ([], None)
  in
  Random.self_init () ;
  ignore
    Clic.(
      setup_formatter
        Format.std_formatter
        (if Unix.isatty Unix.stdout then Ansi else Plain)
        Short) ;
  ignore
    Clic.(
      setup_formatter
        Format.err_formatter
        (if Unix.isatty Unix.stderr then Ansi else Plain)
        Short) ;
  Internal_event_unix.init ()
  >>= fun () ->
  Lwt.catch
    (fun () ->
      let full =
        new unix_full
          ~chain:C.default_chain
          ~block:C.default_block
          ~confirmations:None
          ~password_filename:None
          ~base_dir:C.default_base_dir
          ~rpc_config:RPC_client_unix.default_config
      in
      C.parse_config_args full original_args
      >>=? (fun (parsed, remaining) ->
             let parsed_config_file = parsed.Client_config.parsed_config_file
             and parsed_args = parsed.Client_config.parsed_args
             and config_commands = parsed.Client_config.config_commands in
             let base_dir : string =
               match parsed.Client_config.base_dir with
               | Some p ->
                   p
               | None -> (
                 match parsed_config_file with
                 | None ->
                     C.default_base_dir
                 | Some p ->
                     p.Client_config.Cfg_file.base_dir )
             and require_auth = parsed.Client_config.require_auth in
             let rpc_config =
               let rpc_config : RPC_client_unix.config =
                 match parsed_config_file with
                 | None ->
                     RPC_client_unix.default_config
                 | Some cfg ->
                     {
                       RPC_client_unix.default_config with
                       endpoint =
                         Option.value
                           cfg.endpoint
                           ~default:Client_config.default_endpoint;
                     }
               in
               match parsed_args with
               | Some parsed_args ->
                   if parsed_args.Client_config.print_timings then
                     let gettimeofday = Unix.gettimeofday in
                     {
                       rpc_config with
                       logger =
                         RPC_client_unix.timings_logger
                           ~gettimeofday
                           Format.err_formatter;
                     }
                   else if parsed_args.Client_config.log_requests then
                     {
                       rpc_config with
                       logger =
                         RPC_client_unix.full_logger Format.err_formatter;
                     }
                   else rpc_config
               | None ->
                   rpc_config
             in
             setup_client_config full parsed_args base_dir rpc_config
             >>=? fun client_config ->
             setup_remote_signer
               (module C)
               client_config
               rpc_config
               parsed_config_file ;
             ( match parsed_args with
             | Some parsed_args ->
                 select_commands
                   (client_config :> RPC_client_unix.http_ctxt)
                   parsed_args
             | None ->
                 return_nil )
             >>=? fun other_commands ->
             let commands =
               Clic.add_manual
                 ~executable_name
                 ~global_options
                 (if Unix.isatty Unix.stdout then Clic.Ansi else Clic.Plain)
                 Format.std_formatter
                 (C.clic_commands
                    ~base_dir
                    ~config_commands
                    ~builtin_commands
                    ~other_commands
                    ~require_auth)
             in
             match autocomplete with
             | Some (prev_arg, cur_arg, script) ->
                 Clic.autocompletion
                   ~script
                   ~cur_arg
                   ~prev_arg
                   ~args:original_args
                   ~global_options
                   commands
                   client_config
                 >>=? fun completions ->
                 List.iter print_endline completions ;
                 return_unit
             | None ->
                 Clic.dispatch commands client_config remaining)
      >>= function
      | Ok () ->
          Lwt.return 0
      | Error [Clic.Help command] ->
          Clic.usage
            Format.std_formatter
            ~executable_name
            ~global_options
            (match command with None -> [] | Some c -> [c]) ;
          Lwt.return 0
      | Error errs ->
          Clic.pp_cli_errors
            Format.err_formatter
            ~executable_name
            ~global_options
            ~default:Error_monad.pp
            errs ;
          Lwt.return 1)
    (function
      | Client_commands.Version_not_found ->
          Format.eprintf
            "@{<error>@{<title>Fatal error@}@} unknown protocol version.@." ;
          Lwt.return 1
      | Failure message ->
          Format.eprintf
            "@{<error>@{<title>Fatal error@}@}@.  @[<h 0>%a@]@."
            Format.pp_print_text
            message ;
          Lwt.return 1
      | exn ->
          Format.printf
            "@{<error>@{<title>Fatal error@}@}@.  @[<h 0>%a@]@."
            Format.pp_print_text
            (Printexc.to_string exn) ;
          Lwt.return 1)
  >>= fun retcode ->
  Format.pp_print_flush Format.err_formatter () ;
  Format.pp_print_flush Format.std_formatter () ;
  Internal_event_unix.close () >>= fun () -> Lwt.return retcode

(* Where all the user friendliness starts *)
let run (module M : M)
    ~(select_commands :
       RPC_client_unix.http_ctxt ->
       Client_config.cli_args ->
       Client_context.full Clic.command list tzresult Lwt.t) =
  Stdlib.exit @@ Lwt_main.run @@ Lwt_exit.wrap_and_forward
  @@ main (module M) ~select_commands
