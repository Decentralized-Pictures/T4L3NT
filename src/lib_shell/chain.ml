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

open State_logging

let genesis chain_state =
  let genesis = State.Chain.genesis chain_state in
  State.Block.read_opt chain_state genesis.block
  >|= Option.unopt_assert ~loc:__POS__

let known_heads chain_state =
  State.read_chain_data chain_state (fun chain_store _data ->
      Store.Chain_data.Known_heads.elements chain_store)
  >>= fun hashes ->
  Lwt_list.map_p
    (fun h ->
      State.Block.read_opt chain_state h >|= Option.unopt_assert ~loc:__POS__)
    hashes

let head chain_state =
  State.read_chain_data chain_state (fun _chain_store data ->
      Lwt.return data.current_head)

let mem chain_state hash =
  State.read_chain_data chain_state (fun chain_store data ->
      if Block_hash.equal (State.Block.hash data.current_head) hash then
        Lwt.return_true
      else Store.Chain_data.In_main_branch.known (chain_store, hash))

type data = State.chain_data = {
  current_head : State.Block.t;
  current_mempool : Mempool.t;
  live_blocks : Block_hash.Set.t;
  live_operations : Operation_hash.Set.t;
  test_chain : Chain_id.t option;
  save_point : Int32.t * Block_hash.t;
  caboose : Int32.t * Block_hash.t;
}

let data chain_state =
  State.read_chain_data chain_state (fun _chain_store data -> Lwt.return data)

let locator chain_state seed =
  data chain_state
  >>= fun data -> State.compute_locator chain_state data.current_head seed

let locked_set_head chain_store data block live_blocks live_operations =
  let rec pop_blocks ancestor block =
    let hash = State.Block.hash block in
    if Block_hash.equal hash ancestor then Lwt.return_unit
    else
      lwt_debug
        Tag.DSL.(
          fun f ->
            f "pop_block %a" -% t event "pop_block"
            -% a Block_hash.Logging.tag hash)
      >>= fun () ->
      Store.Chain_data.In_main_branch.remove (chain_store, hash)
      >>= fun () ->
      State.Block.predecessor block
      >>= function
      | Some predecessor ->
          pop_blocks ancestor predecessor
      | None ->
          assert false
    (* Cannot pop the genesis... *)
  in
  let push_block pred_hash block =
    let hash = State.Block.hash block in
    lwt_debug
      Tag.DSL.(
        fun f ->
          f "push_block %a" -% t event "push_block"
          -% a Block_hash.Logging.tag hash)
    >>= fun () ->
    Store.Chain_data.In_main_branch.store (chain_store, pred_hash) hash
    >>= fun () -> Lwt.return hash
  in
  Chain_traversal.new_blocks ~from_block:data.current_head ~to_block:block
  >>= fun (ancestor, path) ->
  let ancestor = State.Block.hash ancestor in
  pop_blocks ancestor data.current_head
  >>= fun () ->
  Lwt_list.fold_left_s push_block ancestor path
  >>= fun _ ->
  Store.Chain_data.Current_head.store chain_store (State.Block.hash block)
  >>= fun () ->
  (* TODO more optimized updated of live_{blocks/operations} when the
     new head is a direct successor of the current head...
     Make sure to do the live blocks computation in `init_head`
     when this TODO is resolved. *)
  Lwt.return
    {
      current_head = block;
      current_mempool = Mempool.empty;
      live_blocks;
      live_operations;
      save_point = data.save_point;
      caboose = data.caboose;
      test_chain = data.test_chain;
    }

let set_head chain_state block =
  State.Block.max_operations_ttl block
  >>=? fun max_op_ttl ->
  Chain_traversal.live_blocks block max_op_ttl
  >>=? fun (live_blocks, live_operations) ->
  State.update_chain_data chain_state (fun chain_store data ->
      locked_set_head chain_store data block live_blocks live_operations
      >>= fun new_chain_data ->
      Lwt.return (Some new_chain_data, data.current_head))
  >>= fun chain_state -> return chain_state

let test_and_set_head chain_state ~old block =
  State.Block.max_operations_ttl block
  >>=? fun max_op_ttl ->
  Chain_traversal.live_blocks block max_op_ttl
  >>=? fun (live_blocks, live_operations) ->
  State.update_chain_data chain_state (fun chain_store data ->
      if not (State.Block.equal data.current_head old) then
        Lwt.return (None, false)
      else
        locked_set_head chain_store data block live_blocks live_operations
        >>= fun new_chain_data -> Lwt.return (Some new_chain_data, true))
  >>= fun chain_state -> return chain_state

let init_head chain_state =
  head chain_state
  >>= fun block ->
  set_head chain_state block >>=? fun (_ : State.Block.t) -> return_unit
