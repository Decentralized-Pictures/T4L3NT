(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs, <contact@nomadic-labs.com>               *)
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
open Refutation_coordinator_types

module type S = sig
  module PVM : Pvm.S

  val init : Node_context.rw -> unit tzresult Lwt.t

  val process : Layer1.head -> unit tzresult Lwt.t

  val shutdown : unit -> unit Lwt.t
end

(* Count instances of the coordinator functor to allow for multiple
   worker events without conflicts. *)
let instances_count = ref 0

module Make (Interpreter : Interpreter.S) = struct
  include Refutation_game.Make (Interpreter)
  module Player = Refutation_player.Make (Interpreter)
  module Pkh_map = Signature.Public_key_hash.Map
  module Pkh_table = Signature.Public_key_hash.Table

  let () = incr instances_count

  type state = {
    node_ctxt : Node_context.rw;
    pending_opponents : unit Pkh_table.t;
  }

  let get_conflicts cctxt head_block =
    Plugin.RPC.Sc_rollup.conflicts cctxt (cctxt#chain, head_block)

  let get_ongoing_games cctxt head_block =
    Plugin.RPC.Sc_rollup.ongoing_refutation_games cctxt (cctxt#chain, head_block)

  let untracked_conflicts opponent_players conflicts =
    List.filter
      (fun conflict ->
        not
        @@ Pkh_map.mem
             conflict.Sc_rollup.Refutation_storage.other
             opponent_players)
      conflicts

  (* Transform the list of ongoing games [(Game.t * pkh * pkh) list]
     into a mapping from opponents' pkhs to their corresponding game
     state.
  *)
  let make_game_map self ongoing_games =
    List.fold_left
      (fun acc (game, alice, bob) ->
        let opponent_pkh =
          if Signature.Public_key_hash.equal self alice then bob else alice
        in
        Pkh_map.add opponent_pkh game acc)
      Pkh_map.empty
      ongoing_games

  let on_process Layer1.{hash; level} state =
    let node_ctxt = state.node_ctxt in
    let head_block = `Hash (hash, 0) in
    let open Lwt_result_syntax in
    let refute_signer = Node_context.get_operator node_ctxt Refute in
    match refute_signer with
    | None ->
        (* Not injecting refutations, don't play refutation games *)
        return_unit
    | Some self ->
        let Node_context.{rollup_address; cctxt; _} = node_ctxt in
        (* Current conflicts in L1 *)
        let* conflicts = get_conflicts cctxt head_block rollup_address self in
        (* Map of opponents the node is playing against to the corresponding
           player worker *)
        let opponent_players =
          Pkh_map.of_seq @@ List.to_seq @@ Player.current_games ()
        in
        (* Conflicts for which we need to start new refutation players.
           Some of these might be ongoing. *)
        let new_conflicts = untracked_conflicts opponent_players conflicts in
        (* L1 ongoing games *)
        let* ongoing_games =
          get_ongoing_games cctxt head_block rollup_address self
        in
        (* Map between opponents and their corresponding games *)
        let ongoing_game_map = make_game_map self ongoing_games in
        (* Launch new players for new conflicts, and play one step *)
        let* () =
          List.iter_ep
            (fun conflict ->
              let other = conflict.Sc_rollup.Refutation_storage.other in
              Pkh_table.replace state.pending_opponents other () ;
              let game = Pkh_map.find_opt other ongoing_game_map in
              Player.init_and_play node_ctxt ~self ~conflict ~game ~level)
            new_conflicts
        in
        let*! () =
          (* Play one step of the refutation game in every remaining player *)
          Pkh_map.iter_p
            (fun opponent worker ->
              match Pkh_map.find opponent ongoing_game_map with
              | Some game ->
                  Pkh_table.remove state.pending_opponents opponent ;
                  Player.play worker game ~level
              | None ->
                  (* Kill finished players: those who don't aren't
                     playing against pending opponents that don't have
                     ongoing games in the L1 *)
                  if not @@ Pkh_table.mem state.pending_opponents opponent then
                    Player.shutdown worker
                  else Lwt.return_unit)
            opponent_players
        in
        return_unit

  module Types = struct
    type nonrec state = state

    type parameters = {node_ctxt : Node_context.rw}
  end

  module Name = struct
    (* We only have a single coordinator in the node *)
    type t = unit

    let encoding = Data_encoding.unit

    let base =
      (* But we can have multiple instances in the unit tests. This is just to
         avoid conflicts in the events declarations. *)
      Refutation_game_event.Coordinator.section
      @ [
          ("worker"
          ^ if !instances_count = 1 then "" else string_of_int !instances_count
          );
        ]

    let pp _ _ = ()

    let equal () () = true
  end

  module Worker = Worker.MakeSingle (Name) (Request) (Types)

  type worker = Worker.infinite Worker.queue Worker.t

  module Handlers = struct
    type self = worker

    let on_request :
        type r request_error.
        worker ->
        (r, request_error) Request.t ->
        (r, request_error) result Lwt.t =
     fun w request ->
      let state = Worker.state w in
      match request with Request.Process b -> on_process b state

    type launch_error = error trace

    let on_launch _w () Types.{node_ctxt} =
      return {node_ctxt; pending_opponents = Pkh_table.create 5}

    let on_error (type a b) _w st (r : (a, b) Request.t) (errs : b) :
        unit tzresult Lwt.t =
      let open Lwt_result_syntax in
      let request_view = Request.view r in
      let emit_and_return_errors errs =
        let*! () =
          Refutation_game_event.Coordinator.request_failed request_view st errs
        in
        return_unit
      in
      match r with Request.Process _ -> emit_and_return_errors errs

    let on_completion _w r _ st =
      Refutation_game_event.Coordinator.request_completed (Request.view r) st

    let on_no_request _ = Lwt.return_unit

    let on_close _w = Lwt.return_unit
  end

  let table = Worker.create_table Queue

  let worker_promise, worker_waker = Lwt.task ()

  let init node_ctxt =
    let open Lwt_result_syntax in
    let*! () = Refutation_game_event.Coordinator.starting () in
    let+ worker = Worker.launch table () {node_ctxt} (module Handlers) in
    Lwt.wakeup worker_waker worker

  (* This is a refutation coordinator for a single scoru *)
  let worker =
    lazy
      (match Lwt.state worker_promise with
      | Lwt.Return worker -> ok worker
      | Lwt.Fail _ | Lwt.Sleep ->
          error Sc_rollup_node_errors.No_refutation_coordinator)

  let process b =
    let open Lwt_result_syntax in
    let*? w = Lazy.force worker in
    let*! (_pushed : bool) = Worker.Queue.push_request w (Request.Process b) in
    return_unit

  let shutdown () =
    let open Lwt_syntax in
    let w = Lazy.force worker in
    match w with
    | Error _ ->
        (* There is no refutation coordinator, nothing to do *)
        Lwt.return_unit
    | Ok w ->
        (* Shut down all current refutation players *)
        let games = Player.current_games () in
        let* () =
          List.iter_s (fun (_opponent, player) -> Player.shutdown player) games
        in
        Worker.shutdown w
end
