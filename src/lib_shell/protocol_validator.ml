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

open Validation_errors

include Internal_event.Legacy_logging.Make_semantic(struct let name = "node.validator.block" end)

type 'a request =
  | Request_validation: {
      hash: Protocol_hash.t ;
      protocol: Protocol.t ;
    } -> Registered_protocol.t tzresult request

type message = Message: 'a request * 'a Lwt.u option -> message

type t = {
  db: Distributed_db.t ;
  mutable worker: unit Lwt.t ;
  messages: message Lwt_pipe.t ;
  canceler: Lwt_canceler.t ;
}

(** Block validation *)

let rec worker_loop bv =
  begin
    protect ~canceler:bv.canceler begin fun () ->
      Lwt_pipe.pop bv.messages >>= return
    end >>=? function Message (request, wakener) ->
    match request with
    | Request_validation { hash ; protocol } ->
        Updater.compile hash protocol >>= fun valid ->
        begin
          if valid then
            Distributed_db.commit_protocol bv.db hash protocol
          else
            (* no need to tag 'invalid' protocol on disk,
               the economic protocol prevents us from
               being spammed with protocol validation. *)
            return_true
        end >>=? fun _ ->
        match wakener with
        | None ->
            return_unit
        | Some wakener ->
            if valid then
              match Registered_protocol.get hash with
              | Some protocol ->
                  Lwt.wakeup_later wakener (Ok protocol)
              | None ->
                  Lwt.wakeup_later wakener
                    (error
                       (Invalid_protocol { hash ; error = Dynlinking_failed }))
            else
              Lwt.wakeup_later wakener
                (error
                   (Invalid_protocol { hash ; error = Compilation_failed })) ;
            return_unit
  end >>= function
  | Ok () ->
      worker_loop bv
  | Error (Canceled :: _) | Error (Exn Lwt_pipe.Closed :: _) ->
      lwt_log_notice Tag.DSL.(fun f ->
          f "terminating" -% t event "terminating")
  | Error err ->
      lwt_log_error Tag.DSL.(fun f ->
          f "@[Unexpected error (worker):@ %a@]"
          -% t event "unexpected_error"
          -% a errs_tag err) >>= fun () ->
      Lwt_canceler.cancel bv.canceler

let create db =
  let canceler = Lwt_canceler.create () in
  let messages = Lwt_pipe.create () in
  let bv = {
    canceler ; messages ; db ;
    worker = Lwt.return_unit } in
  Lwt_canceler.on_cancel bv.canceler begin fun () ->
    Lwt_pipe.close bv.messages ;
    Lwt.return_unit
  end ;
  bv.worker <-
    Lwt_utils.worker "block_validator"
      ~on_event:Internal_event.Lwt_worker_event.on_event
      ~run:(fun () -> worker_loop bv)
      ~cancel:(fun () -> Lwt_canceler.cancel bv.canceler) ;
  bv

let shutdown { canceler ; worker ; _ } =
  Lwt_canceler.cancel canceler >>= fun () ->
  worker

let validate { messages ; _ } hash protocol =
  match Registered_protocol.get hash with
  | Some protocol ->
      lwt_debug Tag.DSL.(fun f ->
          f "previously validated protocol %a (before pipe)"
          -% t event "previously_validated_protocol"
          -% a Protocol_hash.Logging.tag hash) >>= fun () ->
      return protocol
  | None ->
      let res, wakener = Lwt.task () in
      lwt_debug Tag.DSL.(fun f ->
          f "pushing validation request for protocol %a"
          -% t event "pushing_validation_request"
          -% a Protocol_hash.Logging.tag hash) >>= fun () ->
      Lwt_pipe.push messages
        (Message (Request_validation { hash ; protocol },
                  Some wakener)) >>= fun () ->
      res

let fetch_and_compile_protocol pv ?peer ?timeout hash =
  match Registered_protocol.get hash with
  | Some proto -> return proto
  | None ->
      begin
        Distributed_db.Protocol.read_opt pv.db hash >>= function
        | Some protocol -> return protocol
        | None ->
            lwt_log_notice Tag.DSL.(fun f ->
                f "Fetching protocol %a%a"
                -% t event "fetching_protocol"
                -% a Protocol_hash.Logging.tag hash
                -% a P2p_peer.Id.Logging.tag_source peer) >>= fun () ->
            Distributed_db.Protocol.fetch pv.db ?peer ?timeout hash ()
      end >>=? fun protocol ->
      validate pv hash protocol >>=? fun proto ->
      return proto

let fetch_and_compile_protocols pv ?peer ?timeout (block: State.Block.t) =
  let protocol_level = State.Block.protocol_level block in
  let chain_state = State.Block.chain_state block in
  State.Block.context block >>= fun context ->
  let protocol =
    Context.get_protocol context >>= fun protocol_hash ->
    fetch_and_compile_protocol pv ?peer ?timeout protocol_hash >>=? fun _p ->
    let chain_id = State.Chain.id chain_state in
    State.Chain.update_level_indexed_protocol_store
      chain_state chain_id protocol_level protocol_hash (State.Block.header block)
    >>= fun () ->
    return_unit
  and test_protocol =
    Context.get_test_chain context >>= function
    | Not_running -> return_unit
    | Forking { protocol ; _ }
    | Running { protocol ; _ } ->
        fetch_and_compile_protocol pv ?peer ?timeout protocol >>=? fun _ ->
        begin State.Chain.test chain_state >>= function
          | None -> Lwt.return_unit
          | Some chain_id ->
              State.Chain.update_level_indexed_protocol_store
                chain_state chain_id protocol_level protocol (State.Block.header block)
        end >>= fun () ->
        return_unit in
  protocol >>=? fun () ->
  test_protocol

let prefetch_and_compile_protocols pv ?peer ?timeout block =
  try ignore (fetch_and_compile_protocols pv ?peer ?timeout block) with _ -> ()
