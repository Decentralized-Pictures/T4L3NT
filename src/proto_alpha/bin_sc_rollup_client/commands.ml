(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Clic
open Protocol.Alpha_context

let get_sc_rollup_addresses_command () =
  command
    ~desc:
      "Retrieve the smart-contract rollup address the node is interacting with."
    no_options
    (fixed ["get"; "sc"; "rollup"; "address"])
    (fun () (cctxt : #Configuration.sc_client_context) ->
      RPC.get_sc_rollup_addresses_command cctxt >>=? fun addr ->
      cctxt#message "@[%a@]" Sc_rollup.Address.pp addr >>= fun () -> return_unit)

let get_state_value_command () =
  command
    ~desc:"Observe a key in the PVM state."
    no_options
    (prefixes ["get"; "state"; "value"; "for"]
    @@ string ~name:"key" ~desc:"The key of the state value"
    @@ stop)
    (fun () key (cctxt : #Configuration.sc_client_context) ->
      RPC.get_state_value_command cctxt key >>=? fun bytes ->
      cctxt#message "@[%S@]" (String.of_bytes bytes) >>= fun () -> return_unit)

(** [display_answer cctxt answer] prints an RPC answer. *)
let display_answer (cctxt : #Configuration.sc_client_context) :
    RPC_context.generic_call_result -> unit Lwt.t = function
  | `Json (`Ok json) -> cctxt#answer "%a" Json_repr.(pp (module Ezjsonm)) json
  | `Binary (`Ok binary) -> cctxt#answer "%a" Hex.pp (Hex.of_string binary)
  | `Json (`Error (Some error)) ->
      cctxt#error
        "@[<v 2>Command failed: @[%a@]@]@."
        (Format.pp_print_list Error_monad.pp)
        (Data_encoding.Json.destruct
           (Data_encoding.list Error_monad.error_encoding)
           error)
  | `Binary (`Error (Some error)) -> (
      match Data_encoding.Binary.of_string Error_monad.trace_encoding error with
      | Ok trace ->
          cctxt#error
            "@[<v 2>Command failed: @[%a@]@]@."
            Error_monad.pp_print_trace
            trace
      | Error msg ->
          cctxt#error
            "@[<v 2>Error whilst decoding the server response: @[%a@]@]@."
            Data_encoding.Binary.pp_read_error
            msg)
  | `Json (`Not_found _) | `Binary (`Not_found _) | `Other (_, `Not_found _) ->
      cctxt#error "No service found at this URL\n%!"
  | `Json (`Gone _) | `Binary (`Gone _) | `Other (_, `Gone _) ->
      cctxt#error
        "Requested data concerns a pruned block and target resource is no \
         longer available\n\
         %!"
  | `Json (`Unauthorized _)
  | `Binary (`Unauthorized _)
  | `Other (_, `Unauthorized _) ->
      cctxt#error "@[<v 2>[HTTP 403] Access denied to: %a@]@." Uri.pp cctxt#base
  | _ -> cctxt#error "Unexpected server answer\n%!"

let get_output_proof () =
  let parse_transactions transactions =
    let json = Ezjsonm.from_string transactions in
    let open Ezjsonm in
    let open Sc_rollup.Outbox.Message in
    let open Lwt_result_syntax in
    let transaction json =
      let destination =
        find json ["destination"] |> get_string
        |> Protocol.Contract_hash.of_b58check_exn
      in
      let entrypoint =
        try
          find json ["entrypoint"] |> get_string
          |> Entrypoint.of_string_strict_exn
        with Not_found -> Entrypoint.default
      in
      let*? parameters =
        Tezos_micheline.Micheline_parser.no_parsing_error
        @@ (find json ["parameters"] |> get_string
          |> Michelson_v1_parser.parse_expression)
      in
      let unparsed_parameters = parameters.expanded in
      return @@ {destination; entrypoint; unparsed_parameters}
    in
    match json with
    | `A messages ->
        let* transactions = List.map_es transaction messages in
        return @@ Atomic_transaction_batch {transactions}
    | `O _ ->
        let* transaction = transaction json in
        return @@ Atomic_transaction_batch {transactions = [transaction]}
    | _ ->
        failwith
          "An outbox message must be either a single transaction or a list of \
           transactions."
  in

  command
    ~desc:"Ask the rollup node for an output proof."
    no_options
    (prefixes ["get"; "proof"; "for"; "message"]
    @@ string ~name:"index" ~desc:"The index of the message in the outbox"
    @@ prefixes ["of"; "outbox"; "at"; "level"]
    @@ string
         ~name:"level"
         ~desc:"The level of the rollup outbox where the message is available"
    @@ prefixes ["transferring"]
    @@ string
         ~name:"transactions"
         ~desc:"A JSON description of the transactions"
    @@ stop)
    (fun () index level transactions (cctxt : #Configuration.sc_client_context) ->
      let open Lwt_result_syntax in
      let* message = parse_transactions transactions in
      let output =
        Protocol.Alpha_context.Sc_rollup.
          {
            message_index = Z.of_string index;
            outbox_level = Raw_level.of_int32_exn (Int32.of_string level);
            message;
          }
      in
      RPC.get_outbox_proof cctxt output >>=? fun (commitment_hash, proof) ->
      cctxt#message
        {|@[{ "proof" : "0x%a", "commitment_hash" : "%a"@]}|}
        Hex.pp
        (Hex.of_string proof)
        Protocol.Alpha_context.Sc_rollup.Commitment.Hash.pp
        commitment_hash
      >>= fun () -> return_unit)

(** [call_get cctxt raw_url] executes a GET RPC call against the [raw_url]. *)
let call_get (cctxt : #Configuration.sc_client_context) raw_url =
  let open Lwt_result_syntax in
  let meth = `GET in
  let uri = Uri.of_string raw_url in
  let* answer = cctxt#generic_media_type_call meth uri in
  let*! () = display_answer cctxt answer in
  return_unit

let rpc_get_command =
  command
    ~desc:"Call an RPC with the GET method."
    no_options
    (prefixes ["rpc"; "get"] @@ string ~name:"url" ~desc:"the RPC URL" @@ stop)
    (fun () url cctxt -> call_get cctxt url)

module Keys = struct
  open Tezos_client_base.Client_keys

  let generate_keys () =
    command
      ~desc:"Generate a pair of keys."
      (args1 (Secret_key.force_switch ()))
      (prefixes ["gen"; "unencrypted"; "keys"]
      @@ Aggregate_alias.Secret_key.fresh_alias_param @@ stop)
      (fun force name (cctxt : #Configuration.sc_client_context) ->
        Client_keys_commands.Bls_commands.generate_keys
          ~force
          ~encrypted:false
          name
          cctxt)

  let list_keys () =
    command
      ~desc:"List keys."
      no_options
      (prefixes ["list"; "keys"] @@ stop)
      (fun () (cctxt : #Configuration.sc_client_context) ->
        Client_keys_commands.Bls_commands.list_keys cctxt)

  let show_address () =
    command
      ~desc:"Show the keys associated with an account."
      no_options
      (prefixes ["show"; "address"]
      @@ Aggregate_alias.Public_key_hash.alias_param @@ stop)
      (fun () (name, _pkh) (cctxt : #Configuration.sc_client_context) ->
        Client_keys_commands.Bls_commands.show_address
          ~show_private:true
          name
          cctxt)

  let import_secret_key () =
    command
      ~desc:"Add a secret key to the wallet."
      (args1 (Aggregate_alias.Secret_key.force_switch ()))
      (prefixes ["import"; "secret"; "key"]
      @@ Aggregate_alias.Secret_key.fresh_alias_param @@ aggregate_sk_uri_param
      @@ stop)
      (fun force name sk_uri (cctxt : #Configuration.sc_client_context) ->
        Client_keys_commands.Bls_commands.import_secret_key
          ~force
          name
          sk_uri
          cctxt)
end

let all () =
  [
    get_sc_rollup_addresses_command ();
    get_state_value_command ();
    get_output_proof ();
    rpc_get_command;
    Keys.generate_keys ();
    Keys.list_keys ();
    Keys.show_address ();
    Keys.import_secret_key ();
  ]
