(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

let rec retry (cctxt : #Protocol_client_context.full) ~delay ~tries f x =
  f x
  >>= function
  | Ok _ as r ->
      Lwt.return r
  | Error
      (RPC_client_errors.Request_failed {error = Connection_failed _; _} :: _)
    as err
    when tries > 0 -> (
      cctxt#message "Connection refused, retrying in %.2f seconds..." delay
      >>= fun () ->
      Lwt.pick
        [ (Lwt_unix.sleep delay >|= fun () -> `Continue);
          (Lwt_exit.termination_thread >|= fun _ -> `Killed) ]
      >>= function
      | `Killed ->
          Lwt.return err
      | `Continue ->
          retry cctxt ~delay:(delay *. 1.5) ~tries:(tries - 1) f x )
  | Error _ as err ->
      Lwt.return err

let await_bootstrapped_node (cctxt : #Protocol_client_context.full) =
  (* Waiting for the node to be synchronized *)
  cctxt#message "Waiting for the node to be synchronized with its peers..."
  >>= fun () ->
  retry cctxt ~tries:5 ~delay:1. Shell_services.Monitor.bootstrapped cctxt
  >>=? fun (block_stream, _stopper) ->
  let rec waiting_loop () =
    Lwt_stream.get block_stream
    >>= function None -> Lwt.return_unit | Some _ -> waiting_loop ()
  in
  waiting_loop ()
  >>= fun () -> cctxt#message "Node synchronized." >>= fun () -> return_unit

let monitor_fork_testchain (cctxt : #Protocol_client_context.full)
    ~cleanup_nonces =
  (* Waiting for the node to be synchronized *)
  cctxt#message "Waiting for the test chain to be forked..."
  >>= fun () ->
  Shell_services.Monitor.active_chains cctxt
  >>=? fun (stream, _) ->
  let rec loop () =
    Lwt_stream.next stream
    >>= fun l ->
    let testchain =
      List.find_opt
        (function Shell_services.Monitor.Active_test _ -> true | _ -> false)
        l
    in
    match testchain with
    | Some (Active_test {protocol; expiration_date; _})
      when Protocol_hash.equal Protocol.hash protocol ->
        let abort_daemon () =
          cctxt#message
            "Test chain's expiration date reached (%a)... Stopping the \
             daemon.@."
            Time.Protocol.pp_hum
            expiration_date
          >>= fun () ->
          if cleanup_nonces then
            (* Clean-up existing nonces *)
            cctxt#with_lock (fun () ->
                Client_baking_files.resolve_location cctxt ~chain:`Test `Nonce
                >>=? fun nonces_location ->
                Client_baking_nonces.(save cctxt nonces_location empty))
          else return_unit >>=? fun () -> exit 0
        in
        let canceler = Lwt_canceler.create () in
        Lwt_canceler.on_cancel canceler (fun () ->
            abort_daemon () >>= function _ -> Lwt.return_unit) ;
        let now = Time.System.(to_protocol (Systime_os.now ())) in
        let delay = Int64.to_int (Time.Protocol.diff expiration_date now) in
        if delay <= 0 then (* Testchain already expired... Retrying. *)
          loop ()
        else
          let timeout =
            Lwt_timeout.create delay (fun () ->
                Lwt_canceler.cancel canceler |> ignore)
          in
          Lwt_timeout.start timeout ; return_unit
    | None ->
        loop ()
    | Some _ ->
        loop ()
    (* Got a testchain for a different protocol, skipping *)
  in
  Lwt.pick
    [ (Lwt_exit.termination_thread >>= fun _ -> failwith "Interrupted...");
      loop () ]
  >>=? fun () -> cctxt#message "Test chain forked." >>= fun () -> return_unit

module Endorser = struct
  let run (cctxt : #Protocol_client_context.full) ~chain ~delay delegates =
    await_bootstrapped_node cctxt
    >>=? fun _ ->
    ( if chain = `Test then monitor_fork_testchain cctxt ~cleanup_nonces:false
    else return_unit )
    >>=? fun () ->
    Client_baking_blocks.monitor_heads
      ~next_protocols:(Some [Protocol.hash])
      cctxt
      chain
    >>=? fun block_stream ->
    cctxt#message "Endorser started."
    >>= fun () ->
    Client_baking_endorsement.create cctxt ~delay delegates block_stream
end

module Baker = struct
  let run (cctxt : #Protocol_client_context.full) ?minimal_fees
      ?minimal_nanotez_per_gas_unit ?minimal_nanotez_per_byte ?max_priority
      ~chain ~context_path delegates =
    await_bootstrapped_node cctxt
    >>=? fun _ ->
    Config_services.user_activated_upgrades cctxt
    >>=? fun user_activated_upgrades ->
    ( if chain = `Test then monitor_fork_testchain cctxt ~cleanup_nonces:true
    else return_unit )
    >>=? fun () ->
    Client_baking_blocks.monitor_heads
      ~next_protocols:(Some [Protocol.hash])
      cctxt
      chain
    >>=? fun block_stream ->
    cctxt#message "Baker started."
    >>= fun () ->
    Client_baking_forge.create
      cctxt
      ~user_activated_upgrades
      ?minimal_fees
      ?minimal_nanotez_per_gas_unit
      ?minimal_nanotez_per_byte
      ?max_priority
      ~chain
      ~context_path
      delegates
      block_stream
end

module Accuser = struct
  let run (cctxt : #Protocol_client_context.full) ~chain ~preserved_levels =
    await_bootstrapped_node cctxt
    >>=? fun _ ->
    ( if chain = `Test then monitor_fork_testchain cctxt ~cleanup_nonces:true
    else return_unit )
    >>=? fun () ->
    Client_baking_blocks.monitor_valid_blocks
      ~next_protocols:(Some [Protocol.hash])
      cctxt
      ~chains:[chain]
      ()
    >>=? fun valid_blocks_stream ->
    cctxt#message "Accuser started."
    >>= fun () ->
    Client_baking_denunciation.create
      cctxt
      ~preserved_levels
      valid_blocks_stream
end
