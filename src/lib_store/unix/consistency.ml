(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020-2021 Nomadic Labs, <contact@nomadic-labs.com>          *)
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

open Store_types
open Store_errors

(* A non-empty store is considered consistent if the following
   invariants hold:

   - genesis, caboose, savepoint, checkpoint, current_head,
   alternate_heads associated files exists, are decodable and the
   blocks they point to may be read in the block store and are
   consistent with their definition;

   - genesis ≤ caboose ≤ savepoint ≤ [cementing_highwatermark] ≤
   checkpoint ≤ all(alternate_heads ∪ current_head)

   Hypothesis:

   - We suppose that the stores have not been modified outside of the
   store.
*)

(* [check_cementing_highwatermark ~chain_dir block_store] checks that
   the cementing_highwatermark is consistent with the cemented
   store. *)
let check_cementing_highwatermark ~cementing_highwatermark block_store =
  let open Lwt_result_syntax in
  let cemented_store = Block_store.cemented_block_store block_store in
  let highest_cemented_level =
    Cemented_block_store.get_highest_cemented_level cemented_store
  in
  match (highest_cemented_level, cementing_highwatermark) with
  | Some highest_cemented_level, Some cementing_highwatermark ->
      fail_unless
        (Int32.equal highest_cemented_level cementing_highwatermark)
        (Inconsistent_cementing_highwatermark
           {highest_cemented_level; cementing_highwatermark})
  | Some _, None ->
      (* Can be the case after a snapshot import *)
      return_unit
  | None, Some _ ->
      (* Can be the case in Rolling 0 *)
      return_unit
  | None, None -> return_unit

let is_block_stored block_store (descriptor, expected_metadata, block_name) =
  let open Lwt_result_syntax in
  let* o =
    Block_store.read_block
      ~read_metadata:expected_metadata
      block_store
      (Block (fst descriptor, 0))
  in
  match o with
  | None -> tzfail (Unexpected_missing_block {block_name})
  | Some _block ->
      if expected_metadata then
        (* Force read the metadata of a block to avoid false negatives
           due to the cache.*)
        let* o =
          Block_store.read_block_metadata
            block_store
            (Block (fst descriptor, 0))
        in
        match o with
        | None -> tzfail (Unexpected_missing_block_metadata {block_name})
        | Some _ -> return_unit
      else return_unit

(* Checks that the activation blocks above the caboose can be read and
   that the caboose, savepoint and checkpoint have a protocol
   associtated to them. *)
let check_protocol_levels block_store ~savepoint ~current_head protocol_levels =
  let open Lwt_result_syntax in
  let* savepoint =
    Block_store.read_block
      ~read_metadata:false
      block_store
      (Block (fst savepoint, 0))
  in
  let* current_head =
    Block_store.read_block
      ~read_metadata:false
      block_store
      (Block (fst current_head, 0))
  in
  (* We already checked that those blocks are present, it is safe to
     unopt them. *)
  let savepoint = WithExceptions.Option.get ~loc:__LOC__ savepoint in
  let current_head = WithExceptions.Option.get ~loc:__LOC__ current_head in
  let savepoint_proto_level = Block_repr.proto_level savepoint in
  let current_head_proto_level = Block_repr.proto_level current_head in
  let available_proto_levels =
    savepoint_proto_level -- current_head_proto_level
  in
  let* () =
    List.iter_es
      (fun protocol_level ->
        match Protocol_levels.find protocol_level protocol_levels with
        | None ->
            (* We don't have it, we should... *)
            tzfail (Unexpected_missing_protocol {protocol_level})
        | Some _ -> return_unit)
      available_proto_levels
  in
  return_unit

let check_invariant ~genesis ~caboose ~savepoint ~cementing_highwatermark
    ~checkpoint ~current_head ~alternate_heads =
  let ( <= ) descr descr' = Compare.Int32.(snd descr <= snd descr') in
  let invariant_holds =
    genesis <= caboose && caboose <= savepoint && savepoint <= checkpoint
    && checkpoint <= current_head
    && List.for_all
         (fun alternate_head -> checkpoint <= alternate_head)
         alternate_heads
    &&
    match cementing_highwatermark with
    | Some ch -> Compare.Int32.(ch <= snd checkpoint)
    | None -> true
  in
  fail_unless
    invariant_holds
    (Bad_ordering_invariant
       {
         genesis = snd genesis;
         caboose = snd caboose;
         savepoint = snd savepoint;
         cementing_highwatermark;
         checkpoint = snd checkpoint;
         head = snd current_head;
       })

(* [check_consistency ~store_dir genesis] aims to provide a quick
   check (in terms of execution time) which checks that files may be
   read and they are consistent w.r.t to the given invariant.

   Hypothesis: an existing store is provided. *)
let check_consistency chain_dir genesis =
  let open Lwt_result_syntax in
  (* Try loading all the block's data files *)
  let* genesis_data = Stored_data.load (Naming.genesis_block_file chain_dir) in
  let*! genesis_block = Stored_data.get genesis_data in
  let* () =
    fail_unless
      (Block_hash.equal (Block_repr.hash genesis_block) genesis.Genesis.block)
      (Inconsistent_genesis
         {expected = genesis.block; got = Block_repr.hash genesis_block})
  in
  let* _chain_config = Stored_data.load (Naming.chain_config_file chain_dir) in
  let* caboose_data = Stored_data.load (Naming.caboose_file chain_dir) in
  let*! caboose = Stored_data.get caboose_data in
  let* savepoint_data = Stored_data.load (Naming.savepoint_file chain_dir) in
  let*! savepoint = Stored_data.get savepoint_data in
  let* checkpoint_data = Stored_data.load (Naming.checkpoint_file chain_dir) in
  let*! checkpoint = Stored_data.get checkpoint_data in
  let* current_head_data =
    Stored_data.load (Naming.current_head_file chain_dir)
  in
  let*! current_head = Stored_data.get current_head_data in
  let* alternate_heads_data =
    Stored_data.load (Naming.alternate_heads_file chain_dir)
  in
  let*! alternate_heads = Stored_data.get alternate_heads_data in
  let* protocol_levels_data =
    Stored_data.load (Naming.protocol_levels_file chain_dir)
  in
  let* _invalid_blocks_data =
    Stored_data.load (Naming.invalid_blocks_file chain_dir)
  in
  let* _forked_chains_data =
    Stored_data.load (Naming.forked_chains_file chain_dir)
  in
  let* _target_data = Stored_data.load (Naming.target_file chain_dir) in
  (* Open the store and try to read the blocks *)
  (* [~readonly:false] to recover from a potential interrupted merge *)
  let* block_store = Block_store.load chain_dir ~genesis_block ~readonly:true in
  Lwt.finalize
    (fun () ->
      (* TODO should we check context as well? *)
      let genesis_descr = Block_repr.descriptor genesis_block in
      let expected_blocks =
        [
          (genesis_descr, false, "genesis");
          (caboose, false, "caboose");
          (savepoint, true, "savepoint");
          (* is this really true? *)
          (checkpoint, true, "checkpoint");
          (current_head, true, "current_head");
        ]
        @ List.map
            (fun descr -> (descr, true, "alternate_heads"))
            alternate_heads
      in
      let* () =
        List.iter_es
          (fun block -> is_block_stored block_store block)
          expected_blocks
      in
      let* cementing_highwatermark_data =
        Stored_data.load (Naming.cementing_highwatermark_file chain_dir)
      in
      let*! cementing_highwatermark =
        Stored_data.get cementing_highwatermark_data
      in
      let* () =
        check_cementing_highwatermark ~cementing_highwatermark block_store
      in
      let*! protocol_levels = Stored_data.get protocol_levels_data in
      let* () =
        check_protocol_levels
          block_store
          ~savepoint
          ~current_head
          protocol_levels
      in
      let* () =
        check_invariant
          ~genesis:genesis_descr
          ~caboose
          ~savepoint
          ~cementing_highwatermark
          ~checkpoint
          ~current_head
          ~alternate_heads
      in
      return_unit)
    (fun () -> Block_store.close block_store)

let fix_floating_stores chain_dir =
  let open Lwt_result_syntax in
  let store_kinds = [Floating_block_store.RO; RW; RW_TMP; RO_TMP] in
  let*! existing_floating_stores, incomplete_floating_stores =
    List.partition_s
      (fun kind -> Floating_block_store.all_files_exists chain_dir kind)
      store_kinds
  in
  (* Remove potentially partial floating stores *)
  let*! () =
    List.iter_s
      (fun kind ->
        let dir_path =
          Naming.floating_blocks_dir chain_dir kind |> Naming.dir_path
        in
        Lwt_utils_unix.remove_dir dir_path)
      incomplete_floating_stores
  in
  let* () =
    List.iter_es
      (fun kind -> Floating_block_store.fix_integrity chain_dir kind)
      existing_floating_stores
  in
  let*! () = Store_events.(emit fix_floating_stores ()) in
  return_unit

(* [fix_head chain_dir block_store genesis_block] iter through the
   floating blocks and set, as head, the fittest block found. *)
let fix_head chain_dir block_store genesis_block =
  let open Lwt_result_syntax in
  let floating_stores = Block_store.floating_block_stores block_store in
  let* blocks =
    List.map_es
      (Floating_block_store.fold_left_s
         (fun last_max block ->
           let block_fitness = Block_repr.fitness block in
           let last_max_fitness = Block_repr.fitness last_max in
           if Fitness.(block_fitness > last_max_fitness) then return block
           else return last_max)
         genesis_block)
      floating_stores
  in
  let floating_head =
    List.fold_left
      (fun e1 e2 ->
        if Fitness.(Block_repr.fitness e1 > Block_repr.fitness e2) then e1
        else e2)
      genesis_block
      blocks
  in
  (* Find the highest block from cemented *)
  let cemented_block_store = Block_store.cemented_block_store block_store in
  let* inferred_head =
    match Cemented_block_store.cemented_blocks_files cemented_block_store with
    | None -> return floating_head
    | Some cemented_block_files ->
        let cemented_block_files = Array.to_list cemented_block_files in
        (* If the fittest of the floating blocks is genesis (genesis is the
           result of the unsuccessful search from the floatings) and there
           is at least one cemented file, then it means that the floating
           blocks were truncated. The head is then chosen as the highest
           cemented block known. *)
        if
          cemented_block_files <> []
          && Block_hash.equal
               (Block_repr.hash genesis_block)
               (Block_repr.hash floating_head)
        then
          let highest_cycle =
            List.last_opt cemented_block_files
            |> WithExceptions.Option.get ~loc:__LOC__
          in
          let highest_cemented_level =
            highest_cycle.Cemented_block_store.end_level
          in
          let+ o =
            Cemented_block_store.get_cemented_block_by_level
              cemented_block_store
              ~read_metadata:true
              highest_cemented_level
          in
          WithExceptions.Option.get ~loc:__LOC__ o
          (* If the highest of the floating blocks is genesis and there is
             at least one cemented file, then it means that the floating
             blocks were truncated. The head is then chosen as the highest
             cemented block known. *)
        else return floating_head
  in
  (* Make sure that the inferred head have metadata *)
  let* () =
    let* o =
      Block_store.read_block_metadata
        block_store
        (Block_store.Block (Block_repr.hash floating_head, 0))
    in
    match o with
    | None ->
        tzfail
          (Corrupted_store
             (Inferred_head
                (Block_repr.hash inferred_head, Block_repr.level inferred_head)))
    | Some _ -> return_unit
  in
  (* Try to load the current head *)
  let*! stored_head =
    let*! r = Stored_data.load (Naming.current_head_file chain_dir) in
    match r with
    | Ok current_head_data ->
        let*! d = Stored_data.get current_head_data in
        Lwt.return_some d
    | Error _ -> Lwt.return_none
  in
  let*! () =
    Store_events.(
      emit fix_head (stored_head, Block_repr.descriptor inferred_head))
  in
  return inferred_head

(* Search for the lowest block with metadata (for savepoint) and the
   lowest block (for caboose) from the cemented store.
   We assume that the given [cemented_block_files] list is sorted in
   ascending order (lowest block files comes first). *)
let lowest_cemented_block cemented_block_files =
  match cemented_block_files with
  | [] -> None
  | {Cemented_block_store.start_level; _} :: _ -> Some start_level

(* Returns the lowest block level of a cemented metadata file. *)
let lowest_metadata_entry metadata_file =
  let open Lwt_syntax in
  let metadata_file_path = Naming.file_path metadata_file in
  let* exists = Lwt_unix.file_exists metadata_file_path in
  if exists then
    let* in_file = Lwt_preemptive.detach Zip.open_in metadata_file_path in
    Lwt.finalize
      (fun () ->
        let* entries = Lwt_preemptive.detach Zip.entries in_file in
        match entries with
        | [] ->
            (* A metadata file is never empty *)
            assert false
        | entry :: entries ->
            let lowest_entry =
              List.fold_left
                (fun lowest entry ->
                  let entry = entry.Zip.filename in
                  if Compare.Int.(int_of_string lowest <= int_of_string entry)
                  then lowest
                  else entry)
                entry.Zip.filename
                entries
            in
            return (Int32.of_string lowest_entry))
      (fun () -> Lwt_preemptive.detach Zip.close_in in_file)
  else
    (* No need to use an error here as it will be caught and
       ignored. *)
    Lwt.fail_with
      (Format.sprintf "cannot find metadata file %s" metadata_file_path)

(* Returns the lowest block level, from the cemented store, which is
   associated to some block metadata *)
let lowest_cemented_metadata cemented_dir =
  let open Lwt_result_syntax in
  let* metadata_files = Cemented_block_store.load_metadata_table cemented_dir in
  match metadata_files with
  | Some metadata_files ->
      let*! m =
        Seq_s.of_seq (Array.to_seq metadata_files)
        |> Seq_s.filter_map_s
             (fun {Cemented_block_store.metadata_file; start_level; end_level}
             ->
               let*! lowest_metadata_entry =
                 Option.catch_s (fun () -> lowest_metadata_entry metadata_file)
               in
               let*! () =
                 match lowest_metadata_entry with
                 | Some _ -> Lwt.return_unit
                 | None ->
                     (* Can be the case if the metadata file is
                        corrupted. Raise a warning and continue the
                        search in the next metadata file. *)
                     Store_events.(
                       emit warning_missing_metadata (start_level, end_level))
               in
               Lwt.return lowest_metadata_entry)
        |> Seq_s.first
      in
      return m
  | None -> return_none

(* Returns both the lowest block and the lowest block with metadata
   from the floating block store.*)
let lowest_floating_blocks floating_stores =
  let open Lwt_result_syntax in
  let* l =
    List.map_es
      (Floating_block_store.fold_left_s
         (fun (last_min, last_min_with_metadata) block ->
           let lowest_block =
             match last_min with
             | None -> Some (Block_repr.level block)
             | Some last_min -> Some (min last_min (Block_repr.level block))
           in
           let lowest_block_with_metadata =
             match (last_min_with_metadata, Block_repr.metadata block) with
             | Some last_min_with_metadata, Some _ ->
                 Some (min last_min_with_metadata (Block_repr.level block))
             | Some last_min_with_metadata, None -> Some last_min_with_metadata
             | None, Some _ -> Some (Block_repr.level block)
             | None, None -> None
           in
           return (lowest_block, lowest_block_with_metadata))
         (None, None))
      floating_stores
  in
  let min l = List.fold_left (Option.merge min) None l in
  let lw, lwm = List.split l in
  (* If we have failed getting a block with metadata from both the
     RO and RW floating stores, then it is not possible to determine
     a savepoint. The store is broken. *)
  let lw = min lw in
  let lwm = min lwm in
  return (lw, lwm)

let read_block_at_level ~read_metadata block_store ~head:(head_hash, head_level)
    level =
  Block_store.read_block
    ~read_metadata
    block_store
    (Block_store.Block (head_hash, Int32.(to_int (sub head_level level))))

(* Reads and returns the inferred savepoint. *)
let load_inferred_savepoint chain_dir block_store head savepoint_level =
  let open Lwt_result_syntax in
  let* block =
    read_block_at_level
      ~read_metadata:false
      block_store
      ~head:(Block_repr.descriptor head)
      savepoint_level
  in
  match block with
  | Some block ->
      let inferred_savepoint =
        (Block_repr.hash block, Block_repr.level block)
      in
      (* Try to load the current savepoint *)
      let*! savepoint_data =
        Stored_data.load (Naming.savepoint_file chain_dir)
      in
      let savepoint_data = Option.of_result savepoint_data in
      let*! stored_savepoint = Option.map_s Stored_data.get savepoint_data in
      let*! () =
        Store_events.(emit fix_savepoint (stored_savepoint, inferred_savepoint))
      in
      return inferred_savepoint
  | None ->
      (* Assumption: the head is valid. Thus, at least the head
         (with metadata) must be a valid candidate for the
         savepoint. *)
      tzfail (Corrupted_store Cannot_find_savepoint_candidate)

(* Reads and returns the inferred caboose. *)
let load_inferred_caboose chain_dir block_store head caboose_level =
  let open Lwt_result_syntax in
  let* block =
    read_block_at_level
      ~read_metadata:false
      block_store
      ~head:(Block_repr.descriptor head)
      caboose_level
  in
  match block with
  | Some block ->
      let inferred_caboose = (Block_repr.hash block, Block_repr.level block) in
      (* Try to load the current caboose *)
      let*! caboose_data = Stored_data.load (Naming.caboose_file chain_dir) in
      let caboose_data = Option.of_result caboose_data in
      let*! stored_caboose = Option.map_s Stored_data.get caboose_data in
      let*! () =
        Store_events.(emit fix_caboose (stored_caboose, inferred_caboose))
      in
      return inferred_caboose
  | None -> tzfail (Corrupted_store Cannot_find_caboose_candidate)

(* Infers an returns both the savepoint and caboose to meet the
   invariants of the store. *)
let infer_savepoint_and_caboose chain_dir block_store =
  let open Lwt_result_syntax in
  let cemented_dir = Naming.cemented_blocks_dir chain_dir in
  let cemented_block_store = Block_store.cemented_block_store block_store in
  let cemented_block_files =
    match Cemented_block_store.cemented_blocks_files cemented_block_store with
    | None -> []
    | Some arr -> Array.to_list arr
  in
  let* cemented_savepoint_candidate = lowest_cemented_metadata cemented_dir in
  let cemented_caboose_candidate = lowest_cemented_block cemented_block_files in
  let floating_stores = Block_store.floating_block_stores block_store in
  match (cemented_savepoint_candidate, cemented_caboose_candidate) with
  | Some cemented_savepoint, Some cemented_caboose ->
      (* Cemented candidates are available. However, we must check
         that the lowest block with metadata from the floating store
         is not lower than the cemented candidate and thus, a better
         candidate. It can be the case when [checkpoint_level -
         max_op_ttl < lowest_cemented_level_with_metadata]. *)
      let* _, lowest_floating_with_metadata =
        lowest_floating_blocks floating_stores
      in
      let sp =
        match lowest_floating_with_metadata with
        | Some lowest_floating_with_metadata ->
            if
              Compare.Int32.(lowest_floating_with_metadata < cemented_savepoint)
            then lowest_floating_with_metadata
            else cemented_savepoint
        | None -> cemented_savepoint
      in
      let cb =
        if Compare.Int32.(cemented_caboose > sp) then sp else cemented_caboose
      in
      return (sp, cb)
  | None, Some cemented_caboose ->
      (* No cemented cycle with metadata but some cycles. Search for
         the savepoint in the floating blocks. *)
      let* _, lowest_floating_with_metadata =
        lowest_floating_blocks floating_stores
      in
      let* savepoint_level =
        match lowest_floating_with_metadata with
        | Some lvl -> return lvl
        | None -> tzfail (Corrupted_store Cannot_find_floating_savepoint)
      in
      let caboose_level =
        if Compare.Int32.(cemented_caboose > savepoint_level) then
          savepoint_level
        else cemented_caboose
      in
      return (savepoint_level, caboose_level)
  | None, None ->
      (* No cycle found. Searching for savepoint and caboose in the
         floating block store.*)
      let* lowest_floating, lowest_floating_with_metadata =
        lowest_floating_blocks floating_stores
      in
      let* savepoint_level =
        match lowest_floating_with_metadata with
        | Some lvl -> return lvl
        | None -> tzfail (Corrupted_store Cannot_find_floating_savepoint)
      in
      let* caboose_level =
        match lowest_floating with
        | Some lvl -> return lvl
        | None -> tzfail (Corrupted_store Cannot_find_floating_caboose)
      in
      return (savepoint_level, caboose_level)
  | Some _, None ->
      (* Inconsistent as a cemented cycle with metadata implies that
         the caboose candidate is known. *)
      assert false

let load_genesis block_store genesis =
  let open Lwt_result_syntax in
  let* block =
    Block_store.read_block
      ~read_metadata:true
      block_store
      (Block_store.Block (genesis.Genesis.block, 0))
  in
  match block with
  | Some block -> return block
  | None -> tzfail (Corrupted_store Missing_genesis)

(* [fix_savepoint_and_caboose chain_dir block_store head]
   Fix the savepoint by setting it to the lowest block with metadata.
   Assumption:
   - block store is valid and available.

   Fix the caboose by setting it to the lowest block.
   Assumption:
   - block store is valid and available. *)
let fix_savepoint_and_caboose ?history_mode chain_dir block_store head genesis =
  let open Lwt_result_syntax in
  match history_mode with
  | Some History_mode.Archive ->
      (* This case does not cover all the potential cases where the
         storage is set to archive, as one might have not set the
         history mode in the config file nor command line. The last
         check will be done after inferring the history_mode, see
         [fix_chain_state].*)
      let* genesis_block = load_genesis block_store genesis in
      let genesis_descr = Block_repr.descriptor genesis_block in
      return (genesis_descr, genesis_descr)
  | None | Some (Full _) | Some (Rolling _) ->
      let* savepoint_level, caboose_level =
        infer_savepoint_and_caboose chain_dir block_store
      in
      let* savepoint =
        load_inferred_savepoint chain_dir block_store head savepoint_level
      in
      let* caboose =
        load_inferred_caboose chain_dir block_store head caboose_level
      in
      return (savepoint, caboose)

(* [fix_checkpoint chain_dir block_store head] fixes the checkpoint
   by setting it to the lowest block with metadata which is higher
   that the last allowed fork level of the current head (and <=
   head_level).
   Assumptions:
   - head is valid,
   - savepoint is valid,
   - block store is valid and available. *)
let fix_checkpoint chain_dir block_store head =
  let open Lwt_result_syntax in
  let set_checkpoint head =
    let* head_lafl =
      match Block_repr.metadata head with
      | Some m -> return m.last_allowed_fork_level
      | None ->
          (*Assumption: head must have metadata *)
          tzfail
            (Corrupted_store
               (Inferred_head (Block_repr.hash head, Block_repr.level head)))
    in
    (* Returns the lowest block with metadata *)
    let rec find_lbwm block_level =
      let* o =
        read_block_at_level
          ~read_metadata:false
          block_store
          ~head:(Block_repr.descriptor head)
          block_level
      in
      match o with
      | Some block -> (
          if
            (* The lowest block with metadata is never higher than
               current head. *)
            Compare.Int32.(Block_repr.level block = Block_repr.level head)
          then return head
          else
            match Block_repr.metadata block with
            | Some _metadata -> return block
            | None -> find_lbwm (Int32.succ block_level))
      | None ->
          (* If the head was reached and it has no metadata, the store
             is broken *)
          if Compare.Int32.(block_level = Block_repr.level head) then
            tzfail (Corrupted_store Cannot_find_block_with_metadata)
          else
            (* Freshly imported rolling nodes may have deleted blocks
               at a level higher that the lafl of the current
               head. Continue. *)
            find_lbwm (Int32.succ block_level)
    in
    let* lbwm = find_lbwm head_lafl in
    let checkpoint = (Block_repr.hash lbwm, Block_repr.level lbwm) in
    let* () =
      Stored_data.write_file (Naming.checkpoint_file chain_dir) checkpoint
    in
    return checkpoint
  in
  let* inferred_checkpoint = set_checkpoint head in
  (* Try to load the current checkpoint *)
  let*! stored_checkpoint =
    let*! r = Stored_data.load (Naming.checkpoint_file chain_dir) in
    match r with
    | Ok checkpoint_data ->
        let*! d = Stored_data.get checkpoint_data in
        Lwt.return_some d
    | Error _ -> Lwt.return_none
  in
  let*! () =
    Store_events.(emit fix_checkpoint (stored_checkpoint, inferred_checkpoint))
  in
  return inferred_checkpoint

let check_block_protocol_hash context_index ~expected block =
  let open Lwt_result_syntax in
  protect @@ fun () ->
  let*! ctxt = Context.checkout_exn context_index (Block_repr.context block) in
  let*! got = Context.get_protocol ctxt in
  return Protocol_hash.(got = expected)

(** Look into the cemented store for the lowest block with an
    associated proto level that is above the savepoint. *)
let find_activation_block_in_cemented block_store ~savepoint_level ~proto_level
    =
  let open Lwt_result_syntax in
  let cemented_store = Block_store.cemented_block_store block_store in
  let read_cemented_block_by_level level =
    let* b_opt =
      Cemented_block_store.get_cemented_block_by_level
        cemented_store
        ~read_metadata:false
        level
    in
    let* b =
      match b_opt with
      | Some b -> return b
      | None ->
          failwith
            "find_activation_block_in_cemented: unexpected missing block in \
             the cemented store"
    in
    return b
  in
  let* is_in_cemented =
    match Cemented_block_store.get_highest_cemented_level cemented_store with
    | None -> return_false
    | Some level ->
        if Compare.Int32.(savepoint_level > level) then return_false
        else
          let* b = read_cemented_block_by_level level in
          return Compare.Int.(Block_repr.proto_level b >= proto_level)
  in
  if not is_in_cemented then return_none
  else
    (* If it is in the cemented, iter on the cemented cycles (in reverse) *)
    let* cemented_cycles =
      match Cemented_block_store.cemented_blocks_files cemented_store with
      | None ->
          failwith
            "find_activation_block_in_cemented: no cycle in the cemented store \
             but got a highest cemented level"
      | Some cycles -> return cycles
    in
    let len = Array.length cemented_cycles in
    let rec find_activation_cycle previous_cycle = function
      | -1 ->
          (* We know that there is at least one cemented cycle,
             otherwise, we wouldn't have a cemented highest level *)
          let* min_b =
            read_cemented_block_by_level
              previous_cycle.Cemented_block_store.start_level
          in
          if Compare.Int.(Block_repr.proto_level min_b <= proto_level) then
            return previous_cycle
          else
            failwith
              "find_activation_block_in_cemented: cannot find activation block \
               for proto %d in cemented store"
              proto_level
      | n ->
          let ({Cemented_block_store.start_level; end_level; _} as cycle) =
            cemented_cycles.(n)
          in
          let min_level = Compare.Int32.(max start_level savepoint_level) in
          let* min_b = read_cemented_block_by_level min_level in
          let* max_b = read_cemented_block_by_level end_level in
          let min_proto_level = Block_repr.proto_level min_b in
          let max_proto_level = Block_repr.proto_level max_b in
          if Compare.Int.(min_proto_level > proto_level) then
            (* Too recent *)
            find_activation_cycle cycle (pred n)
          else if Compare.Int.(max_proto_level < proto_level) then
            (* Too high, it must be in the previous cycle *)
            return previous_cycle
          else if
            min_proto_level <= proto_level && proto_level <= max_proto_level
          then
            (* Activation may have occured in a previous cycle *)
            find_activation_cycle cycle (pred n)
          else
            (* All cases are covered:
               (proto_level < min) v (max < proto_level) v
               (min <= proto_level <= max) *)
            assert false
    in
    let* cycle = find_activation_cycle cemented_cycles.(len - 1) (len - 1) in
    let exception Found of Block_repr.block in
    Lwt.catch
      (fun () ->
        let*! () =
          Cemented_block_store.raw_iter_cemented_file
            (fun block ->
              if Compare.Int32.(Block_repr.level block < savepoint_level) then
                Lwt.return_unit
              else if Compare.Int.(Block_repr.proto_level block = proto_level)
              then Lwt.fail (Found block)
              else Lwt.return_unit)
            cycle
        in
        failwith "find_activation_block_in_cemented: cannot read cemented cycle")
      (function
        | Found block -> return_some block
        | exn ->
            tzfail
              (Inconsistent_cemented_file
                 (Naming.file_path cycle.file, Printexc.to_string exn)))

let find_activation_block_in_floating block_store ~head ~savepoint_level
    ~proto_level =
  let open Lwt_result_syntax in
  let rec loop block_proto_level block =
    if Compare.Int32.(Block_repr.level block <= savepoint_level) then
      let* () =
        fail_unless
          (Block_repr.proto_level block = proto_level)
          (Corrupted_store (Cannot_find_activation_block proto_level))
      in
      return block
    else
      let* predecessor_opt =
        Block_store.read_block
          ~read_metadata:false
          block_store
          (Block (Block_repr.hash block, 1))
      in
      let predecessor =
        (* This block is between savepoint and head: it is expected to
           be available *)
        WithExceptions.Option.get ~loc:__LOC__ predecessor_opt
      in
      let predecessor_proto_level = Block_repr.proto_level predecessor in
      if
        Compare.Int.(
          predecessor_proto_level < block_proto_level
          && block_proto_level = proto_level)
      then (* Found *)
        return block
      else (* Continue *)
        loop predecessor_proto_level predecessor
  in
  loop (Block_repr.proto_level head) head

let craft_activation_block context_index block =
  let open Lwt_result_syntax in
  protect @@ fun () ->
  let* commit_info =
    Lwt.catch
      (fun () ->
        let* tup =
          Context.retrieve_commit_info context_index (Block_repr.header block)
        in
        return_some (Protocol_levels.commit_info_of_tuple tup))
      (fun _ -> return_none)
  in
  let*! protocol =
    let*! ctxt =
      Context.checkout_exn context_index (Block_repr.context block)
    in
    Context.get_protocol ctxt
  in
  return
    {Protocol_levels.block = Block_repr.descriptor block; protocol; commit_info}

let find_lowest_block_with_proto_level block_store ~head ~savepoint_level
    proto_level =
  let open Lwt_result_syntax in
  let* activation_block =
    find_activation_block_in_cemented block_store ~savepoint_level ~proto_level
  in
  match activation_block with
  | Some b -> return b
  | None ->
      find_activation_block_in_floating
        block_store
        ~head
        ~savepoint_level
        ~proto_level

(* Fixes protocol levels table by searching for all the protocol
   levels in the block store (cemented and floating). A complete fix
   of this table is possible in archive mode only. In Full and Rolling
   modes, only the protocol with an activation block associated to a
   stored context will be fully recoverable. To temper with this
   restriction, we also consider the existing protocol table,
   if it is available, and trust the uncheckable entries.
   Assumptions:
   - block store is valid and available,
   - head is valid and available.
   - savepoint is valid and available. *)
let fix_protocol_levels chain_dir block_store context_index
    ~savepoint:(savepoint_hash, _) ~head =
  let open Lwt_result_syntax in
  (* Attempt to recover with the previous protocol table. *)
  let*! (stored_protocol_levels : 'a Protocol_levels.t) =
    let*! r = Stored_data.load (Naming.protocol_levels_file chain_dir) in
    match r with
    | Error _ -> Lwt.return Protocol_levels.empty
    | Ok v -> Stored_data.get v
  in
  let* savepoint_opt =
    Block_store.read_block
      ~read_metadata:false
      block_store
      (Block (savepoint_hash, 0))
  in
  (* We already checked that the savepoint is present, it is safe to
     unopt them. *)
  let savepoint = WithExceptions.Option.get ~loc:__LOC__ savepoint_opt in
  let savepoint_proto_level = Block_repr.proto_level savepoint in
  let head_proto_level = Block_repr.proto_level head in
  let protocol_levels_geq_savepoint =
    savepoint_proto_level -- head_proto_level
  in
  let* invalid_proto_levels =
    List.fold_left_es
      (fun invalid_protocol_levels proto_level ->
        match Protocol_levels.find_opt proto_level stored_protocol_levels with
        | None -> return (proto_level :: invalid_protocol_levels)
        | Some activation_block -> (
            let activation_block_level =
              snd activation_block.Protocol_levels.block
            in
            let level_to_read =
              if
                Compare.Int32.(
                  activation_block_level < Block_repr.level savepoint)
              then (
                (* If the activation block is below the savepoint, it
                   must mean that its proto level is the same as the
                   savepoint's. Otherwise, the chain contains non
                   incremental proto levels. *)
                assert (Compare.Int.(proto_level = savepoint_proto_level)) ;
                Block_repr.level savepoint)
              else activation_block_level
            in
            let* b_opt =
              read_block_at_level
                ~read_metadata:false
                block_store
                ~head:(Block_repr.descriptor head)
                level_to_read
            in
            match b_opt with
            | None ->
                (* The block should be readable, this protocol level is invalid *)
                return (proto_level :: invalid_protocol_levels)
            | Some b ->
                let* protocol_matches =
                  check_block_protocol_hash
                    context_index
                    ~expected:activation_block.protocol
                    b
                in
                if protocol_matches then return invalid_protocol_levels
                else
                  (* if the protocol isn't the same as the expected
                     one, mark this proto level as invalid *)
                  return (proto_level :: invalid_protocol_levels)))
      []
      protocol_levels_geq_savepoint
  in
  let*! () =
    if List.compare_lengths [] invalid_proto_levels = 0 then
      Store_events.(emit restore_protocols_table ())
    else Lwt.return_unit
  in
  let correct_protocol_levels =
    (* Remove invalid proto levels from the existing stored table *)
    Protocol_levels.filter
      (fun i _ -> not (List.mem ~equal:Int.equal i invalid_proto_levels))
      stored_protocol_levels
  in
  (* For each protocol level equal or above the savepoint's that is
     invalid:
     - Retrieve the *lowest* block in the range [savepoint;head]
       that has this protocol level.
     - Add it to the existing correct protocol levels *)
  let* fixed_protocol_levels =
    List.fold_left_es
      (fun fixed_protocol_levels invalid_proto_level ->
        let* b =
          find_lowest_block_with_proto_level
            block_store
            ~head
            ~savepoint_level:(Block_repr.level savepoint)
            invalid_proto_level
        in
        let* activation_block = craft_activation_block context_index b in
        let*! () =
          Store_events.(
            emit
              restore_protocol_activation
              (invalid_proto_level, activation_block.protocol))
        in
        return
          (Protocol_levels.add
             invalid_proto_level
             activation_block
             fixed_protocol_levels))
      correct_protocol_levels
      invalid_proto_levels
  in
  return fixed_protocol_levels

(* [fix_chain_state chain_dir ~head ~cementing_highwatermark
   ~checkpoint ~savepoint ~caboose ~alternate_heads ~forked_chains
   ~protocol_levels ~chain_config ~genesis ~genesis_context] writes, as
   [Stored_data.t], the given arguments. *)
let fix_chain_state chain_dir block_store ~head ~cementing_highwatermark
    ~checkpoint ~savepoint:tmp_savepoint ~caboose:tmp_caboose ~alternate_heads
    ~forked_chains ~protocol_levels ~chain_config ~genesis ~genesis_context =
  let open Lwt_result_syntax in
  (* By setting each stored data, we erase the previous content. *)
  let* () =
    Stored_data.write_file (Naming.chain_config_file chain_dir) chain_config
  in
  let* () =
    Stored_data.write_file
      (Naming.protocol_levels_file chain_dir)
      protocol_levels
  in
  let genesis_block =
    Block_repr.create_genesis_block ~genesis genesis_context
  in
  let* () =
    Stored_data.write_file (Naming.genesis_block_file chain_dir) genesis_block
  in
  let* () = Stored_data.write_file (Naming.current_head_file chain_dir) head in
  let* () =
    Stored_data.write_file
      (Naming.alternate_heads_file chain_dir)
      alternate_heads
  in
  let* () =
    Stored_data.write_file (Naming.checkpoint_file chain_dir) checkpoint
  in
  let* () =
    Stored_data.write_file
      (Naming.cementing_highwatermark_file chain_dir)
      cementing_highwatermark
  in
  (* For archive mode, do not update the savepoint/caboose to the
     inferred ones if they are breaking the invariants (savepoint =
     caboose = genesis). *)
  let* savepoint, caboose =
    match chain_config.history_mode with
    | History_mode.Archive ->
        if snd tmp_savepoint = 0l && snd tmp_caboose = 0l then
          return (tmp_savepoint, tmp_caboose)
        else
          let* genesis_block = load_genesis block_store genesis in
          let genesis_descr = Block_repr.descriptor genesis_block in
          return (genesis_descr, genesis_descr)
    | Full _ | Rolling _ -> return (tmp_savepoint, tmp_caboose)
  in
  let* () =
    Stored_data.write_file (Naming.savepoint_file chain_dir) savepoint
  in
  let* () = Stored_data.write_file (Naming.caboose_file chain_dir) caboose in
  let* () =
    Stored_data.write_file
      (Naming.invalid_blocks_file chain_dir)
      Block_hash.Map.empty
  in
  let* () =
    Stored_data.write_file (Naming.forked_chains_file chain_dir) forked_chains
  in
  return_unit

(* Infers the history mode by inspecting the state of the store. *)
let infer_history_mode chain_dir block_store genesis caboose savepoint =
  let open Lwt_syntax in
  let cemented_block_store = Block_store.cemented_block_store block_store in
  let cemented_blocks_files =
    match Cemented_block_store.cemented_blocks_files cemented_block_store with
    | None -> []
    | Some arr -> Array.to_list arr
  in
  let cemented_dir = Naming.cemented_blocks_dir chain_dir in
  let cemented_metadata_dir =
    Naming.cemented_blocks_metadata_dir cemented_dir
  in
  let cemented_metadata_dir_path = Naming.dir_path cemented_metadata_dir in
  let* nb_cycles_metadata =
    if Sys.file_exists cemented_metadata_dir_path then
      Lwt_stream.fold
        (fun e count -> match e with "." | ".." -> count | _ -> count + 1)
        (Lwt_unix.files_of_directory cemented_metadata_dir_path)
        0
    else Lwt.return 0
  in
  let nb_cycles = List.length cemented_blocks_files in
  (* If the inferred offset equals the default offset value then we
     assume that "default" was the previous value. *)
  let offset =
    if
      Compare.Int.(
        nb_cycles_metadata = History_mode.default_additional_cycles.offset)
    then None
    else Some {History_mode.offset = nb_cycles_metadata}
  in
  let history_mode =
    (* Caboose is not genesis: we sure are in rolling*)
    if not (Block_hash.equal (fst caboose) genesis.Genesis.block) then
      History_mode.Rolling offset
    else if
      (* Caboose is genesis and savepoint is not genesis: we can be in
         both rolling and full. We choose full as the less destructive. *)
      not (Block_hash.equal (fst savepoint) genesis.block)
    then Full offset
    else if
      (* Caboose is genesis and savepoint is genesis and there are as
         many cycles as metadata: we can be in any modes. We choose
         archive as the less destructive.*)
      nb_cycles_metadata = nb_cycles
    then Archive
    else
      (* Otherwise, the number of cemented data differs. We can be in
         full or rolling. We choose full as the less destructive. *)
      Full offset
  in
  let* () = Store_events.(emit restore_inferred_history_mode history_mode) in
  return_ok {history_mode; genesis; expiration = None}

(* [fix_chain_config ?history_mode chain_dir block_store genesis
   caboose savepoint] infers the history mode. *)
let fix_chain_config ?history_mode chain_dir block_store genesis caboose
    savepoint =
  let open Lwt_syntax in
  let* r = Stored_data.load (Naming.chain_config_file chain_dir) in
  match r with
  | Ok chain_config ->
      (* If the store's config is available, we use it as is. *)
      let* d = Stored_data.get chain_config in
      return_ok d
  | Error _ -> (
      match history_mode with
      (* Otherwise, we try to get the history mode that was given by
         the command line or the config file. *)
      | Some history_mode ->
          let* () = Store_events.(emit restore_history_mode history_mode) in
          return_ok {history_mode; genesis; expiration = None}
      | None ->
          (* If there is no hint in the config file nor the command
             line, we try to infer the history mode. *)
          infer_history_mode chain_dir block_store genesis caboose savepoint)

let fix_cementing_highwatermark chain_dir block_store =
  let open Lwt_syntax in
  let cemented_block_store = Block_store.cemented_block_store block_store in
  let inferred_cementing_highwatermark =
    Cemented_block_store.get_highest_cemented_level cemented_block_store
  in
  (* Try to load the current cementing highwatermark *)
  let* stored_cementing_highwatermark =
    let* r = Stored_data.load (Naming.cementing_highwatermark_file chain_dir) in
    match r with
    | Ok cementing_highwatermark_data ->
        let* d = Stored_data.get cementing_highwatermark_data in
        Lwt.return d
    | Error _ -> Lwt.return_none
  in
  let* () =
    Store_events.(
      emit
        fix_cementing_highwatermark
        (stored_cementing_highwatermark, inferred_cementing_highwatermark))
  in
  Lwt.return inferred_cementing_highwatermark

(* [fix_consistency ?history_mode store_dir context_index]
   aims to fix a store in an inconsistent state. The fixing steps are:
    - the current head is set as the highest block level found in the
      floating stores,
    - the savepoint is set as the lowest block with metadata found in
      both the floating and cemented stores,
    - the caboose is set as the lowest block found in both the
      floating and cemented stores,
    - alternated heads is set as empty,
    - forked chains is set as empty,
    - genesis is set based on the node's run args (network flag),
    - the chain_state is updated accordingly to the inferred values.
   Assumptions:
    - context is valid and available
    - block store is valid and available *)
let fix_consistency ?history_mode chain_dir context_index genesis =
  let open Lwt_result_syntax in
  let*! () = Store_events.(emit fix_store ()) in
  (* We suppose that the genesis block is accessible *)
  let* genesis_data =
    trace
      (Corrupted_store Missing_genesis)
      (Stored_data.load (Naming.genesis_block_file chain_dir))
  in
  let*! genesis_block = Stored_data.get genesis_data in
  (* Start fixing things *)
  let* () = fix_floating_stores chain_dir in
  (* May fix an interrupted store merge *)
  let* block_store =
    Block_store.load chain_dir ~genesis_block ~readonly:false
  in
  let* head = fix_head chain_dir block_store genesis_block in
  let*! cementing_highwatermark =
    fix_cementing_highwatermark chain_dir block_store
  in
  let* savepoint, caboose =
    fix_savepoint_and_caboose chain_dir block_store head genesis
  in
  let* checkpoint = fix_checkpoint chain_dir block_store head in
  let* chain_config =
    fix_chain_config
      ?history_mode
      chain_dir
      block_store
      genesis
      caboose
      savepoint
  in
  let* protocol_levels =
    fix_protocol_levels chain_dir block_store context_index ~savepoint ~head
  in
  let* () =
    fix_chain_state
      chain_dir
      block_store
      ~head:(Block_repr.descriptor head)
      ~cementing_highwatermark
      ~checkpoint
      ~savepoint
      ~caboose
      ~alternate_heads:[]
      ~forked_chains:Chain_id.Map.empty
      ~protocol_levels
      ~chain_config
      ~genesis
      ~genesis_context:(Block_repr.context genesis_block)
  in
  let*! () = Block_store.close block_store in
  return_unit
