(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

(** The rollup node stores and publishes commitments for the PVM every
    [Constants.sc_rollup_commitment_period_in_blocks] levels.

    Every time a finalized block is processed by the rollup node, the latter
    determines whether the last commitment that the node has produced referred
    to [sc_rollup.commitment_period_in_blocks] blocks earlier. For mainnet,
    [sc_rollup.commitment_period_in_blocks = 30]. In this case, it computes and
    stores a new commitment in a level-indexed map.

    Stored commitments are signed by the rollup node operator
    and published on the layer1 chain. To ensure that commitments
    produced by the rollup node are eventually published,
    storing and publishing commitments are decoupled. Every time
    a new head is processed, the node tries to publish the oldest
    commitment that was not published already.
*)

open Protocol
open Alpha_context

let add_level level increment =
  (* We only use this function with positive increments so it is safe *)
  if increment < 0 then invalid_arg "Commitment.add_level negative increment" ;
  Raw_level.Internal_for_tests.add level increment

let sub_level level decrement =
  (* We only use this function with positive increments so it is safe *)
  if decrement < 0 then invalid_arg "Commitment.sub_level negative decrement" ;
  Raw_level.Internal_for_tests.sub level decrement

let sc_rollup_commitment_period node_ctxt =
  node_ctxt.Node_context.protocol_constants.parametric.sc_rollup
    .commitment_period_in_blocks

let sc_rollup_challenge_window node_ctxt =
  node_ctxt.Node_context.protocol_constants.parametric.sc_rollup
    .challenge_window_in_blocks

let next_commitment_level node_ctxt last_commitment_level =
  add_level last_commitment_level (sc_rollup_commitment_period node_ctxt)

module Make (PVM : Pvm.S) : Commitment_sig.S with module PVM = PVM = struct
  module PVM = PVM

  let tick_of_level (node_ctxt : _ Node_context.t) inbox_level =
    let open Lwt_result_syntax in
    let* block_hash =
      Node_context.hash_of_level node_ctxt (Raw_level.to_int32 inbox_level)
    in
    let*! block = Store.L2_blocks.get node_ctxt.store block_hash in
    return (Sc_rollup_block.final_tick block)

  let build_commitment (node_ctxt : _ Node_context.t)
      (prev_commitment : Sc_rollup.Commitment.Hash.t) ~prev_commitment_level
      ~inbox_level ctxt =
    let open Lwt_result_syntax in
    let*! pvm_state = PVM.State.find ctxt in
    let*? pvm_state =
      match pvm_state with
      | Some pvm_state -> Ok pvm_state
      | None ->
          error_with
            "PVM state for commitment at level %a is not available"
            Raw_level.pp
            inbox_level
    in
    let*! compressed_state = PVM.state_hash pvm_state in
    let*! tick = PVM.get_tick pvm_state in
    let* prev_commitment_tick = tick_of_level node_ctxt prev_commitment_level in
    let number_of_ticks =
      Sc_rollup.Tick.distance tick prev_commitment_tick
      |> Z.to_int64 |> Sc_rollup.Number_of_ticks.of_value
    in
    let*? number_of_ticks =
      match number_of_ticks with
      | Some number_of_ticks ->
          if number_of_ticks = Sc_rollup.Number_of_ticks.zero then
            error_with "A 0-tick commitment is impossible"
          else Ok number_of_ticks
      | None -> error_with "Invalid number of ticks for commitment"
    in
    return
      Sc_rollup.Commitment.
        {
          predecessor = prev_commitment;
          inbox_level;
          number_of_ticks;
          compressed_state;
        }

  let create_commitment_if_necessary (node_ctxt : _ Node_context.t) ~predecessor
      current_level ctxt =
    let open Lwt_result_syntax in
    if Raw_level.(current_level = node_ctxt.genesis_info.level) then
      let+ genesis_commitment =
        Plugin.RPC.Sc_rollup.commitment
          node_ctxt.cctxt
          (node_ctxt.cctxt#chain, `Head 0)
          node_ctxt.rollup_address
          node_ctxt.genesis_info.commitment_hash
      in
      Some genesis_commitment
    else
      let* last_commitment_hash =
        let*! pred = Store.L2_blocks.find node_ctxt.store predecessor in
        match pred with
        | None -> failwith "Missing block %a" Block_hash.pp predecessor
        | Some pred ->
            return (Sc_rollup_block.most_recent_commitment pred.header)
      in
      let*! last_commitment =
        Store.Commitments.get node_ctxt.store last_commitment_hash
      in
      let next_commitment_level =
        next_commitment_level node_ctxt last_commitment.inbox_level
      in
      if Raw_level.(current_level = next_commitment_level) then
        let*! () = Commitment_event.compute_commitment current_level in
        let+ commitment =
          build_commitment
            node_ctxt
            last_commitment_hash
            ~prev_commitment_level:last_commitment.inbox_level
            ~inbox_level:current_level
            ctxt
        in
        Some commitment
      else return_none

  let process_head (node_ctxt : _ Node_context.t) ~predecessor Layer1.{level; _}
      ctxt =
    let open Lwt_result_syntax in
    let current_level = Raw_level.of_int32_exn level in
    let* commitment =
      create_commitment_if_necessary node_ctxt ~predecessor current_level ctxt
    in
    match commitment with
    | None -> return_none
    | Some commitment ->
        let commitment_hash =
          Sc_rollup.Commitment.hash_uncarbonated commitment
        in
        let*! () =
          Store.Commitments.add node_ctxt.store commitment_hash commitment
        in
        return_some commitment_hash

  let missing_commitments (node_ctxt : _ Node_context.t) =
    let open Lwt_syntax in
    let lpc_level =
      match node_ctxt.lpc with
      | None -> node_ctxt.genesis_info.level
      | Some lpc -> lpc.inbox_level
    in
    let* head = Node_context.last_processed_head_opt node_ctxt.store in
    let next_head_level =
      Option.map
        (fun (b : Sc_rollup_block.t) -> Raw_level.succ b.header.level)
        head
    in
    let sc_rollup_challenge_window_int32 =
      sc_rollup_challenge_window node_ctxt |> Int32.of_int
    in
    let rec gather acc (commitment_hash : Sc_rollup.Commitment.Hash.t) =
      let* commitment =
        Store.Commitments.find node_ctxt.store commitment_hash
      in
      match commitment with
      | None -> return acc
      | Some commitment
        when Raw_level.(commitment.inbox_level <= node_ctxt.lcc.level) ->
          (* Commitment is before or at the LCC, we have reached the end. *)
          return acc
      | Some commitment when Raw_level.(commitment.inbox_level <= lpc_level) ->
          (* Commitment is before the last published one, we have also reached
             the end because we only publish commitments that are for the inbox
             of a finalized L1 block. *)
          return acc
      | Some commitment ->
          let* published_info =
            Store.Commitments_published_at_level.find
              node_ctxt.store
              commitment_hash
          in
          let past_curfew =
            match (published_info, next_head_level) with
            | None, _ | _, None -> false
            | Some {first_published_at_level; _}, Some next_head_level ->
                Raw_level.diff next_head_level first_published_at_level
                > sc_rollup_challenge_window_int32
          in
          let acc = if past_curfew then acc else commitment :: acc in
          (* We keep the commitment and go back to the previous one. *)
          gather acc commitment.predecessor
    in
    let* finalized_block =
      Node_context.get_finalized_head_opt node_ctxt.store
    in
    match finalized_block with
    | None -> return_nil
    | Some finalized ->
        (* Start from finalized block's most recent commitment and gather all
           commitments that are missing. *)
        let commitment =
          Sc_rollup_block.most_recent_commitment finalized.header
        in
        gather [] commitment

  let publish_commitment (node_ctxt : _ Node_context.t) ~source
      (commitment : Sc_rollup.Commitment.t) =
    let open Lwt_result_syntax in
    let publish_operation =
      Sc_rollup_publish {rollup = node_ctxt.rollup_address; commitment}
    in
    let* _hash = Injector.add_pending_operation ~source publish_operation in
    return_unit

  let publish_commitments (node_ctxt : _ Node_context.t) =
    let open Lwt_result_syntax in
    let operator = Node_context.get_operator node_ctxt Publish in
    match operator with
    | None ->
        (* Configured to not publish commitments *)
        return_unit
    | Some source ->
        let*! commitments = missing_commitments node_ctxt in
        List.iter_es (publish_commitment node_ctxt ~source) commitments

  (* Commitments can only be cemented after [sc_rollup_challenge_window] has
     passed since they were first published. *)
  let earliest_cementing_level node_ctxt commitment_hash =
    let open Lwt_option_syntax in
    let+ {first_published_at_level; _} =
      Store.Commitments_published_at_level.find
        node_ctxt.Node_context.store
        commitment_hash
    in
    add_level first_published_at_level (sc_rollup_challenge_window node_ctxt)

  (** [latest_cementable_commitment node_ctxt head] is the most recent commitment
      hash that could be cemented in [head]'s successor if:

      - all its predecessors were cemented
      - it would have been first published at the same level as its inbox

      It does not need to be exact but it must be an upper bound on which we can
      start the search for cementable commitments. *)
  let latest_cementable_commitment (node_ctxt : _ Node_context.t)
      (head : Sc_rollup_block.t) =
    let open Lwt_option_syntax in
    let commitment_hash = Sc_rollup_block.most_recent_commitment head.header in
    let* commitment = Store.Commitments.find node_ctxt.store commitment_hash in
    let*? cementable_level_bound =
      sub_level commitment.inbox_level (sc_rollup_challenge_window node_ctxt)
    in
    if Raw_level.(cementable_level_bound <= node_ctxt.lcc.level) then fail
    else
      let* cementable_bound_block_hash =
        Node_context.hash_of_level_opt
          node_ctxt
          (Raw_level.to_int32 cementable_level_bound)
      in
      let* cementable_bound_block =
        Store.L2_blocks.find node_ctxt.store cementable_bound_block_hash
      in
      let cementable_commitment =
        Sc_rollup_block.most_recent_commitment cementable_bound_block.header
      in
      return cementable_commitment

  let cementable_commitments (node_ctxt : _ Node_context.t) =
    let open Lwt_result_syntax in
    let ( let*& ) x f =
      (* A small monadic combinator to return an empty list of cementable
         commitments on None results. *)
      let*! x = x in
      match x with None -> return_nil | Some x -> f x
    in
    let*& head =
      Node_context.last_processed_head_opt node_ctxt.Node_context.store
    in
    let head_level = head.header.level in
    let rec gather acc (commitment_hash : Sc_rollup.Commitment.Hash.t) =
      let open Lwt_syntax in
      let* commitment =
        Store.Commitments.find node_ctxt.store commitment_hash
      in
      match commitment with
      | None -> return acc
      | Some commitment
        when Raw_level.(commitment.inbox_level <= node_ctxt.lcc.level) ->
          (* If we have moved backward passed or at the current LCC then we have
             reached the end. *)
          return acc
      | Some commitment ->
          let* earliest_cementing_level =
            earliest_cementing_level node_ctxt commitment_hash
          in
          let acc =
            match earliest_cementing_level with
            | None -> acc
            | Some earliest_cementing_level ->
                if Raw_level.(earliest_cementing_level > head_level) then
                  (* Commitments whose cementing level are after the head's
                     successor won't be cementable in the next block. *)
                  acc
                else commitment_hash :: acc
          in
          gather acc commitment.predecessor
    in
    (* We start our search from the last possible cementable commitment. This is
       to avoid iterating over a large number of commitments
       ([challenge_window_in_blocks / commitment_period_in_blocks], in the order
       of 10^3 on mainnet). *)
    let*& latest_cementable_commitment =
      latest_cementable_commitment node_ctxt head
    in
    let*! cementable = gather [] latest_cementable_commitment in
    match cementable with
    | [] -> return_nil
    | first_cementable :: _ ->
        (* Make sure that the first commitment can be cemented according to the
           Layer 1 node as a failsafe. *)
        let* green_light =
          Plugin.RPC.Sc_rollup.can_be_cemented
            node_ctxt.cctxt
            (node_ctxt.cctxt#chain, `Head 0)
            node_ctxt.rollup_address
            first_cementable
        in
        if green_light then return cementable else return_nil

  let cement_commitment (node_ctxt : _ Node_context.t) ~source commitment_hash =
    let open Lwt_result_syntax in
    let cement_operation =
      Sc_rollup_cement
        {rollup = node_ctxt.rollup_address; commitment = commitment_hash}
    in
    let* _hash = Injector.add_pending_operation ~source cement_operation in
    return_unit

  let cement_commitments node_ctxt =
    let open Lwt_result_syntax in
    let operator = Node_context.get_operator node_ctxt Cement in
    match operator with
    | None ->
        (* Configured to not cement commitments *)
        return_unit
    | Some source ->
        let* cementable_commitments = cementable_commitments node_ctxt in
        List.iter_es
          (cement_commitment node_ctxt ~source)
          cementable_commitments

  let start () = Commitment_event.starting ()
end
