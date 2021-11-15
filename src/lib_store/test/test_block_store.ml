(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Test_utils
open Block_store

let assert_presence_in_block_store ?(with_metadata = false) block_store blocks =
  List.iter_es
    (fun b ->
      let hash = Block_repr.hash b in
      Block_store.mem block_store (Block (hash, 0)) >>=? fun is_known ->
      if not is_known then
        Alcotest.failf
          "assert_presence_in_block_store: block %a in not known"
          pp_raw_block
          b ;
      Block_store.read_block
        ~read_metadata:with_metadata
        block_store
        (Block (hash, 0))
      >>=? function
      | None ->
          Alcotest.failf
            "assert_presence_in_block_store: cannot find block %a"
            pp_raw_block
            b
      | Some b' ->
          if with_metadata then (
            Assert.equal
              ~prn:(Format.asprintf "%a" Block_repr.pp_json)
              ~msg:"block equality with metadata"
              b
              b' ;
            return_unit)
          else (
            Assert.equal_block
              ~msg:"block equality without metadata"
              (Block_repr.header b)
              (Block_repr.header b') ;
            return_unit))
    blocks

let assert_absence_in_block_store block_store blocks =
  List.iter_es
    (fun b ->
      let hash = Block_repr.hash b in
      Block_store.mem block_store (Block (hash, 0)) >>=? function
      | true ->
          Alcotest.failf
            "assert_absence_in_block_store: found unexpected block %a"
            pp_raw_block
            b
      | false -> return_unit)
    blocks

let assert_pruned_blocks_in_block_store block_store blocks =
  List.iter_es
    (fun b ->
      let hash = Block_repr.hash b in
      Block_store.mem block_store (Block (hash, 0)) >>=? fun is_known ->
      if not is_known then
        Alcotest.failf
          "assert_pruned_blocks_in_block_store: block %a in not known"
          pp_raw_block
          b ;
      Block_store.read_block ~read_metadata:true block_store (Block (hash, 0))
      >>=? function
      | None ->
          Alcotest.failf
            "assert_pruned_blocks_in_block_store: cannot find block %a"
            pp_raw_block
            b
      | Some {metadata = Some _; _} ->
          Alcotest.failf
            "assert_pruned_blocks_in_block_store: unpruned block %a"
            pp_raw_block
            b
      | Some ({metadata = None; _} as b') ->
          Assert.equal_block
            ~msg:"block equality without metadata"
            (Block_repr.header b)
            (Block_repr.header b') ;
          return_unit)
    blocks

let assert_cemented_bound block_store (lowest, highest) =
  let unopt_level = function
    | Some level -> level
    | None -> Assert.fail_msg "could not retrieve cemented level"
  in
  let lowest_cemented_level =
    unopt_level
      (Cemented_block_store.get_lowest_cemented_level
         (Block_store.cemented_block_store block_store))
  in
  let highest_cemented_level =
    unopt_level
      (Cemented_block_store.get_highest_cemented_level
         (Block_store.cemented_block_store block_store))
  in
  Assert.is_true
    ~msg:"is 0 the lowest cemented level?"
    Compare.Int32.(lowest_cemented_level = lowest) ;
  Assert.is_true
    ~msg:"is head's lafl the lowest cemented level?"
    Compare.Int32.(highest_cemented_level = highest)

let test_storing_and_access_predecessors block_store =
  make_raw_block_list ~kind:`Full (genesis_hash, -1l) 50
  >>= fun (blocks, _head) ->
  List.iter_es (Block_store.store_block block_store) blocks >>=? fun () ->
  assert_presence_in_block_store block_store blocks >>=? fun () ->
  List.iter_es
    (fun b ->
      let hash = Block_repr.hash b in
      let level = Block_repr.level b in
      List.iter_es
        (fun distance ->
          Block_store.get_hash block_store (Block (hash, distance))
          >>=? function
          | None -> Alcotest.fail "expected predecessor but none found"
          | Some h ->
              Alcotest.check
                (module Block_hash)
                (Format.asprintf
                   "get %d-th predecessor of %a (%ld)"
                   distance
                   Block_hash.pp
                   hash
                   level)
                h
                (List.nth blocks (Int32.to_int level - distance)
                |> WithExceptions.Option.get ~loc:__LOC__)
                  .hash ;
              return_unit)
        (0 -- (Int32.to_int level - 1)))
    blocks
  >>=? fun () -> return_unit

let make_raw_block_list_with_lafl pred size ~lafl =
  make_raw_block_list ~kind:`Full pred size >>= fun (chunk, head) ->
  let change_lafl block =
    let metadata =
      WithExceptions.Option.to_exn ~none:Not_found block.Block_repr.metadata
    in
    block.Block_repr.metadata <-
      Some {metadata with last_allowed_fork_level = lafl} ;
    block
  in
  Lwt.return (List.map change_lafl chunk, change_lafl head)

let make_n_consecutive_cycles pred ~cycle_length ~nb_cycles =
  assert (nb_cycles > 0) ;
  assert (cycle_length > 0) ;
  let rec loop acc pred = function
    | 0 ->
        let head =
          List.last_opt (List.hd acc |> WithExceptions.Option.get ~loc:__LOC__)
          |> WithExceptions.Option.get ~loc:__LOC__
        in
        Lwt.return (List.rev acc, head)
    | n ->
        let cycle_length =
          if Block_hash.equal (fst pred) genesis_hash then cycle_length - 1
          else cycle_length
        in
        let lafl = max 0l (snd pred) in
        make_raw_block_list_with_lafl pred cycle_length ~lafl
        >>= fun (chunk, head) ->
        loop (chunk :: acc) (Block_repr.descriptor head) (n - 1)
  in
  loop [] pred nb_cycles

let make_n_initial_consecutive_cycles block_store ~cycle_length ~nb_cycles =
  let genesis_descr =
    Block_repr.descriptor (Block_store.genesis_block block_store)
  in
  make_n_consecutive_cycles genesis_descr ~cycle_length ~nb_cycles

let test_simple_merge block_store =
  make_n_initial_consecutive_cycles block_store ~cycle_length:10 ~nb_cycles:2
  >>= fun (cycles, head) ->
  let head_metadata =
    Block_repr.metadata head |> WithExceptions.Option.get ~loc:__LOC__
  in
  let all_blocks = List.concat cycles in
  List.iter_es (Block_store.store_block block_store) all_blocks >>=? fun () ->
  Block_store.merge_stores
    block_store
    ~on_error:(fun err ->
      Assert.fail_msg "merging failed: %a" pp_print_trace err)
    ~finalizer:(fun _ -> assert_presence_in_block_store block_store all_blocks)
    ~history_mode:Archive
    ~new_head:head
    ~new_head_metadata:head_metadata
    ~cementing_highwatermark:0l
  >>=? fun () ->
  Block_store.await_merging block_store >>= fun () ->
  assert_cemented_bound
    block_store
    (0l, Block_repr.last_allowed_fork_level head_metadata) ;
  return_unit

let test_consecutive_concurrent_merges block_store =
  (* Append 10 cycles of 10 blocks *)
  make_n_initial_consecutive_cycles block_store ~cycle_length:10 ~nb_cycles:10
  >>= fun (cycles, head) ->
  let head_metadata =
    Block_repr.metadata head |> WithExceptions.Option.get ~loc:__LOC__
  in
  let all_blocks = List.concat cycles in
  List.iter_es (Block_store.store_block block_store) all_blocks >>=? fun () ->
  let cycles_to_merge =
    List.fold_left
      (fun (acc, pred_cycle_lafl) cycle ->
        let block_in_cycle =
          List.hd cycle |> WithExceptions.Option.get ~loc:__LOC__
        in
        let block_lafl =
          Block_repr.metadata block_in_cycle
          |> WithExceptions.Option.get ~loc:__LOC__
          |> Block_repr.last_allowed_fork_level
        in
        ((cycle, pred_cycle_lafl) :: acc, block_lafl))
      ([], 0l)
      cycles
    |> fst |> List.rev |> List.tl
    |> WithExceptions.Option.get ~loc:__LOC__
  in
  let merge_cycle (cycle, previous_cycle_lafl) =
    let new_head =
      List.last_opt cycle |> WithExceptions.Option.get ~loc:__LOC__
    in
    let new_head_metadata =
      Block_repr.metadata new_head |> WithExceptions.Option.get ~loc:__LOC__
    in
    Block_store.merge_stores
      block_store
      ~on_error:(fun err ->
        Assert.fail_msg "merging failed: %a" pp_print_trace err)
      ~finalizer:(fun _ -> assert_presence_in_block_store block_store cycle)
      ~history_mode:Archive
      ~new_head
      ~new_head_metadata
      ~cementing_highwatermark:previous_cycle_lafl
  in
  let threads = List.map merge_cycle cycles_to_merge in
  Lwt.all threads >>= fun res ->
  List.iter
    (function
      | Ok () -> ()
      | Error err -> Assert.fail_msg "merging failed: %a" pp_print_trace err)
    res ;
  Block_store.await_merging block_store >>= fun () ->
  assert_presence_in_block_store ~with_metadata:true block_store all_blocks
  >>=? fun () ->
  assert_cemented_bound
    block_store
    (0l, Block_repr.last_allowed_fork_level head_metadata) ;
  return_unit

let test_ten_cycles_merge block_store =
  (* Append 10 cycles *)
  make_n_initial_consecutive_cycles block_store ~cycle_length:100 ~nb_cycles:10
  >>= fun (cycles, head) ->
  let all_blocks = List.concat cycles in
  List.iter_es (Block_store.store_block block_store) all_blocks >>=? fun () ->
  Block_store.merge_stores
    block_store
    ~on_error:(fun err ->
      Assert.fail_msg "merging failed: %a" pp_print_trace err)
    ~finalizer:(fun _ -> return_unit)
    ~history_mode:Archive
    ~new_head:head
    ~new_head_metadata:
      (head |> Block_repr.metadata
      |> WithExceptions.Option.to_exn ~none:Not_found)
    ~cementing_highwatermark:0l
  >>=? fun () ->
  assert_presence_in_block_store ~with_metadata:true block_store all_blocks
  >>=? fun () ->
  Block_store.await_merging block_store >>= fun () -> return_unit

(** Makes several branches at different level and make sure those
    created before the checkpoint are correctly GCed *)
let test_merge_with_branches block_store =
  (* make an initial chain of 2 cycles of 100 blocks with each
     block's lafl pointing to the highest block of its preceding cycle.
     i.e. 1st cycle's lafl = 0, 2nd cycle's lafl = 99 *)
  make_n_initial_consecutive_cycles block_store ~cycle_length:100 ~nb_cycles:2
  >>= fun (cycles, head) ->
  let all_blocks = List.concat cycles in
  List.iter_es (Block_store.store_block block_store) all_blocks >>=? fun () ->
  let branches_fork_points_to_gc = [20; 40; 60; 80; 98] in
  (* 448 => we also keep the checkpoint *)
  List.map_es
    (fun level ->
      let fork_root =
        List.nth all_blocks (level - 1)
        |> WithExceptions.Option.get ~loc:__LOC__
      in
      make_raw_block_list_with_lafl
        ~lafl:0l
        (Block_repr.descriptor fork_root)
        50
      >>= fun (blocks, _head) ->
      (* tweek lafl's to make them coherent *)
      List.iter
        (fun block ->
          if Compare.Int32.(Block_repr.level block > 99l) then
            block.metadata <-
              Option.map
                (fun metadata ->
                  {metadata with Block_repr.last_allowed_fork_level = 99l})
                block.metadata)
        blocks ;
      List.iter_es (Block_store.store_block block_store) blocks >>=? fun () ->
      return blocks)
    branches_fork_points_to_gc
  >>=? fun blocks_to_gc ->
  let branches_fork_points_to_keep = [120; 140; 160; 180] in
  List.map_es
    (fun level ->
      let fork_root =
        List.nth all_blocks (level - 1)
        |> WithExceptions.Option.get ~loc:__LOC__
      in
      make_raw_block_list_with_lafl
        ~lafl:99l
        (Block_repr.descriptor fork_root)
        50
      >>= fun (blocks, _head) ->
      (* tweek lafl's to make them coherent *)
      List.iter
        (fun block ->
          if Compare.Int32.(Block_repr.level block > 199l) then
            block.metadata <-
              Option.map
                (fun metadata ->
                  {metadata with Block_repr.last_allowed_fork_level = 199l})
                block.metadata)
        blocks ;
      List.iter_es (Block_store.store_block block_store) blocks >>=? fun () ->
      return blocks)
    branches_fork_points_to_keep
  >>=? fun blocks_to_keep ->
  (* merge 1st cycle *)
  Block_store.merge_stores
    block_store
    ~on_error:(fun err ->
      Assert.fail_msg "merging failed: %a" pp_print_trace err)
    ~finalizer:(fun _ -> return_unit)
    ~history_mode:Archive
    ~new_head:head
    ~new_head_metadata:
      (head |> Block_repr.metadata
      |> WithExceptions.Option.to_exn ~none:Not_found)
    ~cementing_highwatermark:0l
  >>=? fun () ->
  Block_store.await_merging block_store >>= fun () ->
  assert_presence_in_block_store
    block_store
    (all_blocks @ List.flatten blocks_to_keep)
  >>=? fun () ->
  assert_absence_in_block_store block_store (List.flatten blocks_to_gc)

let perform_n_cycles_merge ?(cycle_length = 10) block_store history_mode
    nb_cycles =
  make_n_initial_consecutive_cycles block_store ~cycle_length ~nb_cycles
  >>= fun (cycles, head) ->
  let all_blocks = List.concat cycles in
  List.iter_es (Block_store.store_block block_store) all_blocks >>=? fun () ->
  assert_presence_in_block_store ~with_metadata:true block_store all_blocks
  >>=? fun () ->
  Block_store.merge_stores
    block_store
    ~on_error:(fun err ->
      Assert.fail_msg "merging failed: %a" pp_print_trace err)
    ~finalizer:(fun _ -> return_unit)
    ~history_mode
    ~new_head:head
    ~new_head_metadata:
      (head |> Block_repr.metadata
      |> WithExceptions.Option.to_exn ~none:Not_found)
    ~cementing_highwatermark:0l
  >>=? fun () ->
  Block_store.await_merging block_store >>= fun () -> return cycles

let test_archive_merge block_store =
  perform_n_cycles_merge block_store Archive 10 >>=? fun cycles ->
  assert_presence_in_block_store
    ~with_metadata:true
    block_store
    (List.concat cycles)
  >>=? fun () ->
  Block_store.savepoint block_store >>= fun savepoint ->
  Assert.equal ~prn:Int32.to_string ~msg:"savepoint" 0l (snd savepoint) ;
  Block_store.caboose block_store >>= fun caboose ->
  Assert.equal ~prn:Int32.to_string ~msg:"caboose" 0l (snd caboose) ;
  return_unit

let test_full_0_merge block_store =
  (* The total of blocks should be > 130 to prevent the cache from
     retaining them *)
  let cycle_length = 20 in
  let nb_cycles = 10 in
  perform_n_cycles_merge
    ~cycle_length
    block_store
    (Full (Some {offset = 0}))
    nb_cycles
  >>=? fun cycles ->
  let all_blocks = List.concat cycles in
  assert_presence_in_block_store
    ~with_metadata:false
    block_store
    (List.rev all_blocks)
  (* hack: invert the reading order to clear the cache *)
  >>=? fun () ->
  let expected_savepoint_level =
    ((nb_cycles - 1) * cycle_length) - 1 (* lafl *) - 1
    (* lafl max_op_ttl *)
  in
  let (expected_pruned_blocks, expected_preserved_blocks) =
    List.split_n
      (expected_savepoint_level - 1)
      (* the genesis block is not counted *) all_blocks
    (* First 9 cycles shouldn't have metadata except for the lafl block
       (i.e. the last one) *)
  in
  assert_presence_in_block_store
    ~with_metadata:true
    block_store
    expected_preserved_blocks
  >>=? fun () ->
  assert_pruned_blocks_in_block_store block_store expected_pruned_blocks
  >>=? fun () ->
  Block_store.savepoint block_store >>= fun savepoint ->
  Assert.equal
    ~prn:Int32.to_string
    ~msg:"savepoint"
    (Int32.of_int expected_savepoint_level)
    (snd savepoint) ;
  Block_store.caboose block_store >>= fun caboose ->
  Assert.equal ~prn:Int32.to_string ~msg:"caboose" 0l (snd caboose) ;
  return_unit

let test_full_2_merge block_store =
  (* The total of blocks should be > 130 to prevent the cache from
     retaining them *)
  perform_n_cycles_merge
    ~cycle_length:20
    block_store
    (Full (Some {offset = 2}))
    10
  >>=? fun cycles ->
  assert_presence_in_block_store
    ~with_metadata:false
    block_store
    (List.rev (List.concat cycles))
  (* hack: invert the reading order to clear the cache *)
  >>=? fun () ->
  let expected_preserved_blocks = List.concat (List.sub (List.rev cycles) 3) in
  (* Last 3 cycles should have metadata *)
  assert_presence_in_block_store
    ~with_metadata:true
    block_store
    expected_preserved_blocks
  >>=? fun () ->
  let expected_pruned_blocks =
    List.sub cycles (List.length cycles - 3) |> List.concat
  in
  (* First 7 cycles shouldn't have metadata *)
  assert_pruned_blocks_in_block_store block_store expected_pruned_blocks
  >>=? fun () ->
  Block_store.savepoint block_store >>= fun savepoint ->
  let expected_savepoint =
    List.nth cycles (10 - 3)
    |> WithExceptions.Option.get ~loc:__LOC__
    |> List.hd
    |> WithExceptions.Option.get ~loc:__LOC__
    |> Block_repr.level
  in
  Assert.equal
    ~prn:Int32.to_string
    ~msg:"savepoint"
    expected_savepoint
    (snd savepoint) ;
  Block_store.caboose block_store >>= fun caboose ->
  Assert.equal ~prn:Int32.to_string ~msg:"caboose" 0l (snd caboose) ;
  return_unit

let test_rolling_0_merge block_store =
  (* The total of blocks should be > 130 to prevent the cache from
     retaining them *)
  let cycle_length = 20 in
  let nb_cycles = 10 in
  perform_n_cycles_merge
    ~cycle_length
    block_store
    (Rolling (Some {offset = 0}))
    nb_cycles
  >>=? fun cycles ->
  let all_blocks = List.concat cycles in
  let expected_savepoint_level =
    ((nb_cycles - 1) * cycle_length) - 1 (* lafl *) - 1
    (* lafl max_op_ttl *)
  in
  let (expected_pruned_blocks, expected_preserved_blocks) =
    List.split_n
      (expected_savepoint_level - 1)
      (* the genesis block is not counted *) all_blocks
    (* First 9 cycles shouldn't have metadata except for the lafl block
       (i.e. the last one) *)
  in
  assert_absence_in_block_store block_store expected_pruned_blocks
  >>=? fun () ->
  assert_presence_in_block_store
    ~with_metadata:true
    block_store
    expected_preserved_blocks
  >>=? fun () ->
  Block_store.savepoint block_store >>= fun savepoint ->
  Assert.equal
    ~prn:Int32.to_string
    ~msg:"savepoint"
    (Int32.of_int expected_savepoint_level)
    (snd savepoint) ;
  Block_store.caboose block_store >>= fun caboose ->
  Assert.equal
    ~prn:Int32.to_string
    ~msg:"caboose"
    (Int32.of_int expected_savepoint_level)
    (snd caboose) ;
  return_unit

let test_rolling_2_merge block_store =
  (* The total of blocks should be > 130 to prevent the cache from
     retaining them *)
  perform_n_cycles_merge
    ~cycle_length:20
    block_store
    (Rolling (Some {offset = 2}))
    10
  >>=? fun cycles ->
  let expected_preserved_blocks = List.concat (List.sub (List.rev cycles) 3) in
  (* Last 3 cycles should have metadata *)
  assert_presence_in_block_store
    ~with_metadata:true
    block_store
    expected_preserved_blocks
  >>=? fun () ->
  let expected_pruned_blocks =
    List.sub cycles (List.length cycles - 3) |> List.concat
  in
  (* First 7 cycles shouldn't have metadata *)
  assert_absence_in_block_store block_store expected_pruned_blocks
  >>=? fun () ->
  Block_store.savepoint block_store >>= fun savepoint ->
  let expected_savepoint =
    List.nth cycles (10 - 3)
    |> WithExceptions.Option.get ~loc:__LOC__
    |> List.hd
    |> WithExceptions.Option.get ~loc:__LOC__
    |> Block_repr.level
  in
  Assert.equal
    ~prn:Int32.to_string
    ~msg:"savepoint"
    expected_savepoint
    (snd savepoint) ;
  Block_store.caboose block_store >>= fun caboose ->
  Assert.equal
    ~prn:Int32.to_string
    ~msg:"caboose"
    expected_savepoint
    (snd caboose) ;
  return_unit

let wrap_test ?(keep_dir = false) (name, g) =
  let f dir_path =
    let genesis_block =
      Block_repr.create_genesis_block
        ~genesis:Test_utils.genesis
        Context_hash.zero
    in
    let store_dir = Naming.store_dir ~dir_path in
    let chain_dir = Naming.chain_dir store_dir Chain_id.zero in
    Lwt_utils_unix.create_dir (Naming.dir_path chain_dir) >>= fun () ->
    Block_store.create chain_dir ~genesis_block >>= function
    | Error err ->
        Format.printf
          "@\nCannot instanciate block store:@\n%a@."
          Error_monad.pp_print_trace
          err ;
        Lwt.fail Alcotest.Test_error
    | Ok block_store -> (
        Lwt.finalize
          (fun () -> protect (fun () -> g block_store))
          (fun () -> Block_store.close block_store)
        >>= function
        | Ok () -> Lwt.return_unit
        | Error err ->
            Format.printf
              "@\nTest failed:@\n%a@."
              Error_monad.pp_print_trace
              err ;
            Lwt.fail Alcotest.Test_error)
  in
  let run _ _ =
    let prefix_dir = "tezos_block_store_test_" in
    if not keep_dir then Lwt_utils_unix.with_tempdir prefix_dir f
    else
      let base_dir = Filename.temp_file prefix_dir "" in
      Format.printf "temp dir: %s@." base_dir ;
      Lwt_unix.unlink base_dir >>= fun () ->
      Lwt_unix.mkdir base_dir 0o700 >>= fun () -> f base_dir
  in
  Alcotest_lwt.test_case name `Quick run

let tests : string * unit Alcotest_lwt.test_case list =
  let test_cases =
    List.map
      wrap_test
      [
        ( "block storing and access predecessors (hash only)",
          test_storing_and_access_predecessors );
        ("simple merge", test_simple_merge);
        ("consecutive & concurrent merge", test_consecutive_concurrent_merges);
        ("10 cycles merge", test_ten_cycles_merge);
        ("merge with branches", test_merge_with_branches);
        ("consecutive merge (Archive)", test_archive_merge);
        ("consecutive merge (Full + 0 cycles)", test_full_0_merge);
        ("consecutive merge (Full + 2 cycles)", test_full_2_merge);
        ("consecutive merge (Rolling + 0 cycles)", test_rolling_0_merge);
        ("consecutive merge (Rolling + 2 cycles)", test_rolling_2_merge);
      ]
  in
  ("block store", test_cases)
