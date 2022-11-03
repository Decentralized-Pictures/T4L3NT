(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
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

open Cli_arg

type t = {
  name : string;
  path : string;
  tx_node : Tx_rollup_node.t;
  base_dir : string;
  wallet_dir : string;
  color : Log.Color.t;
}

let next_name = ref 1

let fresh_name () =
  let index = !next_name in
  incr next_name ;
  "tx_rollup_client" ^ string_of_int index

let () = Test.declare_reset_function @@ fun () -> next_name := 1

let create ~protocol ?name ?base_dir ?wallet_dir ?(color = Log.Color.FG.green)
    tx_node =
  let path =
    String.concat "-" [Constant.tx_rollup_client; Protocol.daemon_name protocol]
  in
  let name = match name with None -> fresh_name () | Some name -> name in
  let base_dir =
    match base_dir with None -> Temp.dir name | Some dir -> dir
  in
  let wallet_dir =
    match wallet_dir with None -> Temp.dir name | Some dir -> dir
  in
  {name; path; tx_node; base_dir; wallet_dir; color}

let base_dir_arg tx_client = ["--base-dir"; tx_client.base_dir]

let wallet_dir_arg tx_client = ["--wallet-dir"; tx_client.wallet_dir]

let endpoint_arg tx_client =
  ["--endpoint"; Tx_rollup_node.endpoint tx_client.tx_node]

let spawn_command ?hooks tx_client command =
  Process.spawn
    ~name:tx_client.name
    ~color:tx_client.color
    ?hooks
    tx_client.path
    (base_dir_arg tx_client @ wallet_dir_arg tx_client @ endpoint_arg tx_client
   @ command)

let get_balance ?block tx_client ~tz4_address ~ticket_id =
  let* out =
    spawn_command
      tx_client
      (["get"; "balance"; "for"; tz4_address; "of"; ticket_id]
      @ optional_arg "block" Fun.id block)
    |> Process.check_and_read_stdout
  in
  let json = JSON.parse ~origin:"tx_client_get_balance" out in
  match JSON.(json |> as_int_opt) with
  | Some level -> Lwt.return level
  | None -> Test.fail "Cannot retrieve balance of tz4 address %s" tz4_address

let get_inbox ?(block = "head") tx_client =
  let* out =
    spawn_command tx_client ["get"; "inbox"; "for"; block]
    |> Process.check_and_read_stdout
  in
  Lwt.return out

let get_block ?(style = `Fancy) tx_client ~block =
  let style = match style with `Raw -> ["--raw"] | `Fancy -> [] in
  let* out =
    spawn_command tx_client (["get"; "block"; block] @ style)
    |> Process.check_and_read_stdout
  in
  Lwt.return out

let craft_tx_transaction tx_client ~signer ?counter
    Rollup.Tx_rollup.(`Transfer {qty; destination; ticket}) =
  let qty = Int64.to_string qty in
  let* out =
    spawn_command
      tx_client
      ([
         "craft";
         "tx";
         "transferring";
         qty;
         "from";
         signer;
         "to";
         destination;
         "for";
         ticket;
       ]
      @ optional_arg "counter" Int64.to_string counter)
    |> Process.check_and_read_stdout
  in
  Lwt.return @@ JSON.parse ~origin:"tx_rollup_client" out

let sign_transaction ?(aggregate = false) ?aggregated_signature tx_client
    ~transaction ~signers =
  let* out =
    spawn_command
      tx_client
      (["sign"; "transaction"; JSON.encode transaction; "with"]
      @ signers
      @ optional_switch "aggregate" aggregate
      @ optional_arg "aggregated-signature" Fun.id aggregated_signature)
    |> Process.check_and_read_stdout
  in
  Lwt.return @@ String.trim out

let craft_tx_transfers tx_client ~signer ?counter transfers =
  let contents_json =
    let open Data_encoding in
    Json.construct
      (list Rollup.Tx_rollup.operation_content_encoding)
      (transfers :> Rollup.Tx_rollup.operation_content list)
    |> Json.to_string
  in
  let* out =
    spawn_command
      tx_client
      (["craft"; "tx"; "transfers"; "from"; signer; "using"; contents_json]
      @ optional_arg "counter" Int64.to_string counter)
    |> Process.check_and_read_stdout
  in
  Lwt.return @@ JSON.parse ~origin:"tx_rollup_client" out

let craft_tx_withdraw ?counter tx_client ~qty ~signer ~dest ~ticket =
  let qty = Int64.to_string qty in
  let* out =
    spawn_command
      tx_client
      ([
         "craft";
         "tx";
         "withdrawing";
         qty;
         "from";
         signer;
         "to";
         dest;
         "for";
         ticket;
       ]
      @ optional_arg "counter" Int64.to_string counter)
    |> Process.check_and_read_stdout
  in
  Lwt.return @@ JSON.parse ~origin:"tx_rollup_client" out

let craft_tx_batch ?(show_hex = false) tx_client ~transactions_and_sig =
  let* out =
    spawn_command
      tx_client
      (["craft"; "batch"; "with"; JSON.encode transactions_and_sig]
      @ optional_switch "bytes" show_hex)
    |> Process.check_and_read_stdout
  in
  Lwt.return
  @@
  if show_hex then `Hex (String.trim out)
  else `Json (JSON.parse ~origin:"tx_rollup_client.craft_tx_batch" out)

let transfer ?counter tx_client ~source
    Rollup.Tx_rollup.(`Transfer {qty; destination; ticket}) =
  let qty = Int64.to_string qty in
  let* out =
    spawn_command
      tx_client
      (["transfer"; qty; "of"; ticket; "from"; source; "to"; destination]
      @ optional_arg "counter" Int64.to_string counter)
    |> Process.check_and_read_stdout
  in
  out
  =~* rex "Transaction hash: ?(\\w*)"
  |> mandatory "transaction hash"
  |> Lwt.return

let withdraw ?counter tx_client ~source
    Rollup.Tx_rollup.(`Withdraw {qty; destination; ticket}) =
  let qty = Int64.to_string qty in
  let* out =
    spawn_command
      tx_client
      (["withdraw"; qty; "of"; ticket; "from"; source; "to"; destination]
      @ optional_arg "counter" Int64.to_string counter)
    |> Process.check_and_read_stdout
  in
  out
  =~* rex "Transaction hash: ?(\\w*)"
  |> mandatory "transaction hash"
  |> Lwt.return

let get_batcher_queue tx_client =
  let* out =
    spawn_command tx_client ["get"; "batcher"; "queue"]
    |> Process.check_and_read_stdout
  in
  Lwt.return out

let get_batcher_transaction tx_client ~transaction_hash =
  let* out =
    spawn_command tx_client ["get"; "batcher"; "transaction"; transaction_hash]
    |> Process.check_and_read_stdout
  in
  Lwt.return out

let inject_batcher_transaction ?expect_failure tx_client ~transactions_and_sig =
  let* out =
    Process.check_and_read_both ?expect_failure
    @@ spawn_command
         tx_client
         ["inject"; "batcher"; "transaction"; JSON.encode transactions_and_sig]
  in
  Lwt.return out

let get_message_proof ?(block = "head") tx_client ~message_position =
  let* out =
    spawn_command
      tx_client
      [
        "get";
        "proof";
        "for";
        "message";
        "at";
        "position";
        string_of_int message_position;
        "in";
        "block";
        block;
      ]
    |> Process.check_and_read_stdout
  in
  Lwt.return out

module RPC = struct
  let get tx_client uri =
    let* out =
      spawn_command tx_client ["rpc"; "get"; uri]
      |> Process.check_and_read_stdout
    in
    Lwt.return out

  let post tx_client ?data uri =
    let data =
      Option.fold ~none:[] ~some:(fun x -> ["with"; JSON.encode_u x]) data
    in
    let* out =
      spawn_command tx_client (["rpc"; "post"; uri] @ data)
      |> Process.check_and_read_stdout
    in
    Lwt.return out
end
