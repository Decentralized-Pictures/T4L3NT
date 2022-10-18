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

module Assert = Lib_test.Assert
module Assert_lib = Lib_test_extra.Assert_lib
open Alcotest_lwt
open Filename.Infix

let equal_metadata ?msg m1 m2 =
  let eq m1 m2 =
    match (m1, m2) with
    | None, None -> true
    | Some m1, Some m2 -> m1 = m2
    | _ -> false
  in
  let pp ppf (md : Tezos_store_unix.Store.Block.metadata option) =
    let none ppf () = Format.pp_print_string ppf "none" in
    Format.fprintf
      ppf
      "%a"
      (Format.pp_print_option
         ~none
         (fun
           ppf
           ({
              message;
              max_operations_ttl;
              last_allowed_fork_level;
              block_metadata = _;
              operations_metadata = _;
            } :
             Store.Block.metadata)
         ->
           Format.fprintf
             ppf
             "message: %a@.max_operations_ttl: %d@. last_allowed_fork_level: \
              %ld@."
             (Format.pp_print_option ~none Format.pp_print_string)
             message
             max_operations_ttl
             last_allowed_fork_level))
      md
  in
  Assert.equal ?msg ~pp ~eq m1 m2

let genesis_hash =
  Block_hash.of_b58check_exn
    "BLockGenesisGenesisGenesisGenesisGenesisf79b5d1CoW2"

let genesis =
  {
    Genesis.block = genesis_hash;
    time = Time.Protocol.epoch;
    protocol = Tezos_protocol_alpha.Protocol.hash;
  }

let default_protocol_constants = Default_parameters.constants_test

let default_max_operations_ttl = 1

let check_invariants ?(expected_checkpoint = None) ?(expected_savepoint = None)
    ?(expected_caboose = None) chain_store =
  let open Lwt_result_syntax in
  Lwt.catch
    (fun () ->
      let open Store in
      let*! current_head = Chain.current_head chain_store in
      let*! checkpoint = Chain.checkpoint chain_store in
      let*! savepoint =
        match expected_savepoint with
        | Some savepoint -> Lwt.return savepoint
        | None -> Chain.savepoint chain_store
      in
      let*! caboose =
        match expected_caboose with
        | Some caboose -> Lwt.return caboose
        | None -> Chain.caboose chain_store
      in
      Format.eprintf
        "head %ld - savepoint %ld - checkpoint %ld - caboose %ld@."
        (Store.Block.level current_head)
        (snd savepoint)
        (snd checkpoint)
        (snd caboose) ;
      let*! head_metadata =
        let*! o = Block.get_block_metadata_opt chain_store current_head in
        match o with
        | None ->
            Assert.fail_msg "check_invariant: could not find head's metadata"
        | Some metadata -> Lwt.return metadata
      in
      let expected_checkpoint_level =
        match expected_checkpoint with
        | Some l -> snd l
        | None -> Block.last_allowed_fork_level head_metadata
      in
      Assert.assert_true
        (Format.sprintf
           "check_invariant: checkpoint.level(%ld) < \
            head.last_allowed_fork_level(%ld)"
           (snd checkpoint)
           expected_checkpoint_level)
        Compare.Int32.(snd checkpoint >= expected_checkpoint_level) ;
      let*! savepoint_b_opt =
        Block.read_block_opt chain_store (fst savepoint)
      in
      let* savepoint_metadata_opt =
        Block.read_block_metadata chain_store (fst savepoint)
      in
      let*! () =
        match (savepoint_b_opt, savepoint_metadata_opt) with
        | Some _, Some _ -> Lwt.return_unit
        | Some _, None ->
            Assert.fail_msg
              "check_invariant: could not find savepoint's metadata"
        | _ -> Assert.fail_msg "check_invariant: could not find savepoint block"
      in
      let*! caboose_b_opt = Block.read_block_opt chain_store (fst caboose) in
      let* caboose_metadata_opt =
        Block.read_block_metadata chain_store (fst caboose)
      in
      match (caboose_b_opt, caboose_metadata_opt) with
      | Some _, (Some _ | None) -> return_unit
      | None, _ ->
          Format.eprintf "caboose lvl : %ld@." (snd caboose) ;
          Assert.fail_msg "check_invariant: could not find the caboose block")
    (fun exn ->
      let*! pp = Store.make_pp_chain_store chain_store in
      Format.printf "DEBUG CHAIN STORE: %a@." pp () ;
      Lwt.fail exn)

let dummy_patch_context ctxt =
  let open Lwt_result_syntax in
  let open Tezos_protocol_alpha in
  let*! ctxt = Context_ops.add ctxt ["version"] (Bytes.of_string "genesis") in
  let open Tezos_protocol_alpha_parameters in
  let proto_params =
    let json =
      Default_parameters.json_of_parameters
        Default_parameters.(parameters_of_constants constants_test)
    in
    Data_encoding.Binary.to_bytes_exn Data_encoding.json json
  in
  let*! ctxt = Context_ops.add ctxt ["protocol_parameters"] proto_params in
  let*! res =
    Protocol.Main.init
      Chain_id.zero
      ctxt
      {
        level = 0l;
        proto_level = 0;
        predecessor = genesis.block;
        timestamp = genesis.time;
        validation_passes = 0;
        operations_hash = Operation_list_list_hash.empty;
        fitness = [];
        context = Context_hash.zero;
      }
  in
  let*? {context; _} = Environment.wrap_tzresult res in
  return context

let register_gc store =
  let open Lwt_result_syntax in
  let chain_store = Store.main_chain_store store in
  let gc ch =
    let*! () = Context_ops.gc (Store.context_index store) ch in
    return_unit
  in
  Store.Chain.register_gc_callback chain_store gc

let wrap_store_init ?(patch_context = dummy_patch_context)
    ?(history_mode = History_mode.Archive) ?(allow_testchains = true)
    ?(keep_dir = false) ?(with_gc = true) ?block_cache_limit
    ?(manual_close = false) k _ () : unit Lwt.t =
  let open Lwt_result_syntax in
  let prefix_dir = "tezos_indexed_store_test_" in
  let run f =
    if not keep_dir then Lwt_utils_unix.with_tempdir prefix_dir f
    else
      let base_dir = Filename.temp_file prefix_dir "" in
      Format.printf "temp dir: %s@." base_dir ;
      let*! () = Lwt_unix.unlink base_dir in
      let*! () = Lwt_unix.mkdir base_dir 0o700 in
      f base_dir
  in
  let*! r =
    run (fun base_dir ->
        let store_dir = base_dir // "store" in
        let context_dir = base_dir // "context" in
        let* store =
          Store.init
            ?block_cache_limit
            ~patch_context
            ~history_mode
            ~store_dir
            ~context_dir
            ~allow_testchains
            genesis
        in
        if with_gc then register_gc store ;
        protect
          ~on_error:(fun err ->
            let*! pp_store = Store.make_pp_store store in
            Format.eprintf "@[<v>DEBUG:@ %a@]@." pp_store () ;
            let*! () =
              if manual_close then Lwt.return_unit else Store.close_store store
            in
            Lwt.return (Error err))
          (fun () ->
            let* () = k (store_dir, context_dir) store in
            Format.printf "Invariants check before closing@." ;
            let* () =
              if manual_close then return_unit
              else
                let* () = check_invariants (Store.main_chain_store store) in
                let*! () = Store.close_store store in
                return_unit
            in
            let* store' =
              Store.init
                ~history_mode
                ~store_dir
                ~context_dir
                ~allow_testchains
                genesis
            in
            Format.printf "Invariants check after reloading@." ;
            let* () =
              Lwt.finalize
                (fun () -> check_invariants (Store.main_chain_store store'))
                (fun () ->
                  let*! _ = Store.close_store store' in
                  Lwt.return_unit)
            in
            return_unit))
  in
  match r with
  | Error err ->
      Format.printf "@\nTest failed:@\n%a@." Error_monad.pp_print_trace err ;
      Lwt.fail Alcotest.Test_error
  | Ok r -> Lwt.return r

let wrap_test ?history_mode ?(speed = `Quick) ?patch_context ?keep_dir ?with_gc
    ?block_cache_limit ?manual_close (name, f) =
  test_case
    name
    speed
    (wrap_store_init
       ?patch_context
       ?history_mode
       ?keep_dir
       ?with_gc
       ?block_cache_limit
       ?manual_close
       f)

let wrap_simple_store_init ?(patch_context = dummy_patch_context)
    ?(history_mode = History_mode.default) ?(allow_testchains = true)
    ?(keep_dir = false) ?(with_gc = true) k _ () : unit Lwt.t =
  let open Lwt_result_syntax in
  let prefix_dir = "tezos_indexed_store_test_" in
  let run f =
    if not keep_dir then Lwt_utils_unix.with_tempdir prefix_dir f
    else
      let base_dir = Filename.temp_file prefix_dir "" in
      let*! () = Lwt_unix.unlink base_dir in
      let*! () = Lwt_unix.mkdir base_dir 0o700 in
      f base_dir
  in
  let*! r =
    run (fun base_dir ->
        let store_dir = base_dir // "store" in
        let context_dir = base_dir // "context" in
        let* store =
          Store.init
            ~history_mode
            ~patch_context
            ~store_dir
            ~context_dir
            ~allow_testchains
            genesis
        in
        if with_gc then register_gc store ;
        protect
          ~on_error:(fun err ->
            let*! () = Store.close_store store in
            Lwt.return (Error err))
          (fun () ->
            Lwt.finalize
              (fun () -> k (store_dir, context_dir) store)
              (fun () ->
                let*! () =
                  Lwt.catch
                    (fun () -> Store.close_store store)
                    (fun _ ->
                      (* FIXME https://gitlab.com/tezos/tezos/-/issues/3305

                         Avoid to re-raise Pack_error: "Double_close"
                         when closing the Context multiple times.*)
                      Lwt.return_unit)
                in
                Lwt.return_unit)))
  in
  match r with
  | Error err ->
      Format.printf "@\nTest failed:@\n%a@." Error_monad.pp_print_trace err ;
      Lwt.fail Alcotest.Test_error
  | Ok () -> Lwt.return_unit

let wrap_simple_store_init_test ?history_mode ?(speed = `Quick) ?patch_context
    ?keep_dir ?with_gc (name, f) =
  test_case
    name
    speed
    (wrap_simple_store_init ?history_mode ?patch_context ?keep_dir ?with_gc f)

let make_raw_block ?min_lafl ?(max_operations_ttl = default_max_operations_ttl)
    ?(constants = default_protocol_constants) ?(context = Context_hash.zero)
    (pred_block_hash, pred_block_level) =
  let level = Int32.succ pred_block_level in
  let header =
    {
      Block_header.shell =
        {
          level;
          proto_level = 0;
          predecessor = pred_block_hash;
          timestamp = Time.Protocol.(add epoch (Int64.of_int32 level));
          validation_passes =
            List.length Tezos_protocol_alpha.Protocol.Main.validation_passes;
          operations_hash = Operation_list_list_hash.zero;
          fitness = [Bytes.create 8];
          context;
        };
      protocol_data =
        (* make it random to be certain to obtain a different hash *)
        Data_encoding.(Binary.to_bytes_exn int31 Random.(int (bits ())));
    }
  in
  let hash = Block_header.hash header in
  let last_allowed_fork_level =
    let current_cycle = Int32.(div (pred level) constants.blocks_per_cycle) in
    Int32.(
      mul
        constants.blocks_per_cycle
        (Compare.Int32.max
           0l
           (sub current_cycle (of_int constants.preserved_cycles))))
  in
  let last_allowed_fork_level =
    match min_lafl with
    | Some min_lafl -> Compare.Int32.max min_lafl last_allowed_fork_level
    | None -> last_allowed_fork_level
  in
  let operations =
    List.map
      (fun _ ->
        Stdlib.List.init (Random.int 10) (fun _i ->
            Operation.
              {
                shell = {branch = pred_block_hash};
                proto =
                  Data_encoding.(
                    Binary.to_bytes_exn int31 Random.(int (bits ())));
              }))
      Tezos_protocol_alpha.Protocol.Main.validation_passes
  in
  let metadata =
    Some
      {
        Block_repr.message = Some "message";
        max_operations_ttl;
        last_allowed_fork_level;
        block_metadata = Bytes.create 1;
        operations_metadata =
          List.map
            (List.map (fun _ ->
                 if Random.bool () then Block_validation.Too_large_metadata
                 else
                   Metadata
                     Data_encoding.(
                       Binary.to_bytes_exn int31 Random.(int (bits ())))))
            operations;
      }
  in
  let b =
    {
      Block_repr.hash;
      contents =
        {
          header;
          operations;
          block_metadata_hash =
            (if Random.bool () then Some Block_metadata_hash.zero else None);
          operations_metadata_hashes =
            (if Random.bool () then
             Some
               (List.map
                  (List.map (fun _ -> Operation_metadata_hash.zero))
                  operations)
            else None);
        };
      metadata;
    }
  in
  b

let prune_block block = block.Block_repr.metadata <- None

let pp_block fmt b =
  let h, lvl = Store.Block.descriptor b in
  Format.fprintf fmt "%a (%ld)" Block_hash.pp h lvl

let raw_descriptor b = (Block_repr.hash b, Block_repr.level b)

let pp_raw_block fmt b =
  let h, lvl = raw_descriptor b in
  Format.fprintf fmt "%a (%ld)" Block_hash.pp h lvl

let store_raw_block chain_store (raw_block : Block_repr.t) =
  let open Lwt_syntax in
  let metadata =
    WithExceptions.Option.get ~loc:__LOC__ (Block_repr.metadata raw_block)
  in
  let ops_metadata =
    let operations_metadata = Block_repr.operations_metadata metadata in
    match Block_repr.operations_metadata_hashes raw_block with
    | Some metadata_hashes ->
        let res =
          WithExceptions.List.map2
            ~loc:__LOC__
            (WithExceptions.List.map2 ~loc:__LOC__ (fun x y -> (x, y)))
            operations_metadata
            metadata_hashes
        in
        Block_validation.Metadata_hash res
    | None -> Block_validation.(No_metadata_hash operations_metadata)
  in
  let validation_result =
    {
      Tezos_validation.Block_validation.validation_store =
        {
          context_hash = Block_repr.context raw_block;
          timestamp = Block_repr.timestamp raw_block;
          message = Block_repr.message metadata;
          max_operations_ttl = Block_repr.max_operations_ttl metadata;
          last_allowed_fork_level = Block_repr.last_allowed_fork_level metadata;
        };
      block_metadata =
        ( Block_repr.block_metadata metadata,
          Block_repr.block_metadata_hash raw_block );
      ops_metadata;
    }
  in
  let* r =
    Store.Block.store_block
      chain_store
      ~block_header:(Block_repr.header raw_block)
      ~operations:(Block_repr.operations raw_block)
      validation_result
  in
  match r with
  | Ok (Some block) -> return_ok block
  | Ok None ->
      Alcotest.failf
        "store_raw_block: could not store block %a (%ld)"
        Block_hash.pp
        (Block_repr.hash raw_block)
        (Block_repr.level raw_block)
  | Error _ as err -> Lwt.return err

let set_block_predecessor blk pred_hash =
  let open Block_repr in
  let open Block_header in
  {
    blk with
    contents =
      {
        blk.contents with
        header =
          {
            blk.contents.header with
            shell = {blk.contents.header.shell with predecessor = pred_hash};
          };
      };
  }

let make_raw_block_list ?min_lafl ?constants ?max_operations_ttl ?(kind = `Full)
    (pred_hash, pred_level) n =
  List.fold_left
    (fun ((pred_hash, pred_level), acc) _ ->
      let raw_block =
        make_raw_block
          ?min_lafl
          ?constants
          ?max_operations_ttl
          (pred_hash, pred_level)
      in
      if kind = `Pruned then prune_block raw_block ;
      ((Block_repr.hash raw_block, Block_repr.level raw_block), raw_block :: acc))
    ((pred_hash, pred_level), [])
    (1 -- n)
  |> snd
  |> fun l ->
  let blk = List.hd l |> WithExceptions.Option.get ~loc:__LOC__ in
  Lwt.return (List.rev l, blk)

let incr_fitness b =
  match b with
  | [] ->
      let b = Bytes.create 8 in
      Bytes.set_int32_be b 0 1l ;
      [b]
  | [fitness_b] ->
      let fitness = Bytes.get_int32_be fitness_b 0 in
      let b = Bytes.create 8 in
      Bytes.set_int32_be b 0 (Int32.succ fitness) ;
      [b]
  | _ -> assert false

let append_blocks ?min_lafl ?constants ?max_operations_ttl ?root ?(kind = `Full)
    ?(should_set_head = false) ?(should_commit = false) ?protocol_level
    ?set_protocol chain_store n =
  let open Lwt_result_syntax in
  let*! root =
    match root with
    | Some (bh, bl) -> Lwt.return (bh, bl)
    | None ->
        let*! block = Store.Chain.current_head chain_store in
        Lwt.return (Store.Block.descriptor block)
  in
  let* root_b = Store.Block.read_block chain_store (fst root) in
  let*! ctxt_opt =
    Context_ops.checkout
      (Store.context_index (Store.Chain.global_store chain_store))
      (Store.Block.context_hash root_b)
  in
  let*! blocks, _last =
    make_raw_block_list ?min_lafl ?constants ?max_operations_ttl ~kind root n
  in
  let proto_level =
    match protocol_level with
    | None -> Store.Block.proto_level root_b
    | Some proto_level -> proto_level
  in
  let* _, _, blocks =
    List.fold_left_es
      (fun (ctxt_opt, last_opt, blocks) b ->
        let* ctxt, last_opt, b =
          if should_commit then
            let ctxt = WithExceptions.Option.get ~loc:__LOC__ ctxt_opt in
            let*! ctxt =
              Context_ops.add
                ctxt
                ["level"]
                (Bytes.of_string (Format.asprintf "%ld" (Block_repr.level b)))
            in
            let*! ctxt =
              match set_protocol with
              | None -> Lwt.return ctxt
              | Some proto -> Context_ops.add_protocol ctxt proto
            in
            let*! ctxt_hash =
              Context_ops.commit ~time:Time.Protocol.epoch ctxt
            in
            let predecessor =
              match List.hd blocks with None -> root_b | Some pred -> pred
            in
            let shell =
              {
                b.contents.header.Block_header.shell with
                fitness = incr_fitness (Store.Block.fitness predecessor);
                proto_level;
                context = ctxt_hash;
                predecessor = Store.Block.hash predecessor;
              }
            in
            let header =
              {
                Block_header.shell;
                protocol_data = b.contents.header.protocol_data;
              }
            in
            let hash = Block_header.hash header in
            return
              ( Some ctxt,
                Some hash,
                {
                  Block_repr.hash;
                  contents =
                    {
                      header;
                      operations = b.contents.operations;
                      block_metadata_hash = None;
                      operations_metadata_hashes = None;
                    };
                  metadata = b.metadata;
                } )
          else return (ctxt_opt, last_opt, b)
        in
        let* b = store_raw_block chain_store b in
        let* () =
          if should_set_head then
            let* _ = Store.Chain.set_head chain_store b in
            return_unit
          else return_unit
        in
        return (ctxt, last_opt, b :: blocks))
      (ctxt_opt, None, [])
      blocks
  in
  let head = List.hd blocks |> WithExceptions.Option.get ~loc:__LOC__ in
  return (List.rev blocks, head)

let append_cycle ?(constants = default_protocol_constants) ?max_operations_ttl
    ?root ?(kind = `Full) ?(should_set_head = false) chain_store =
  append_blocks
    chain_store
    ~constants
    ?max_operations_ttl
    ?root
    ~kind
    ~should_set_head
    (Int32.to_int constants.blocks_per_cycle)

let assert_presence_in_store ?(with_metadata = false) chain_store blocks =
  let open Lwt_syntax in
  let* () =
    Lwt_list.iter_s
      (fun b ->
        let hash = Store.Block.hash b in
        let* o = Store.Block.read_block_opt chain_store hash in
        match o with
        | None ->
            Format.eprintf "Block %a not present in store@." pp_block b ;
            Lwt.fail Alcotest.Test_error
        | Some b' ->
            let b_header = Store.Block.header b in
            let b'_header = Store.Block.header b' in
            Assert_lib.Crypto.equal_block
              ~msg:"assert_presence: different header"
              b_header
              b'_header ;
            let* () =
              if with_metadata then (
                let* b_metadata =
                  Store.Block.get_block_metadata_opt chain_store b
                in
                let* b'_metadata =
                  Store.Block.get_block_metadata_opt chain_store b'
                in
                equal_metadata
                  b_metadata
                  b'_metadata
                  ~msg:"assert_presence: different metadata" ;
                Lwt.return_unit)
              else Lwt.return_unit
            in
            Lwt.return_unit)
      blocks
  in
  return_ok_unit

let assert_absence_in_store chain_store blocks =
  let open Lwt_syntax in
  let* () =
    Lwt_list.iter_s
      (fun b ->
        let* o = Store.Block.(read_block_opt chain_store (hash b)) in
        match o with
        | None -> Lwt.return_unit
        | Some b' ->
            let* current_head = Store.Chain.current_head chain_store in
            let* checkpoint = Store.Chain.checkpoint chain_store in
            let* savepoint = Store.Chain.savepoint chain_store in
            let* caboose = Store.Chain.caboose chain_store in
            Format.printf
              "head %ld - savepoint %ld - checkpoint %ld - caboose %ld@."
              (Store.Block.level current_head)
              (snd savepoint)
              (snd checkpoint)
              (snd caboose) ;
            if not (Store.Block.equal b b') then
              Alcotest.failf
                "assert_absence_in_store: found %a and got a different block \
                 %a@."
                pp_block
                b
                pp_block
                b'
            else
              Alcotest.failf
                "assert_absence_in_store: unexpected block found in store %a@."
                pp_block
                b')
      blocks
  in
  return_ok_unit

let set_head_by_level chain_store lvl =
  let open Lwt_result_syntax in
  let* head = Store.Block.read_block_by_level chain_store lvl in
  Store.Chain.set_head chain_store head

module Example_tree = struct
  (**********************************************************

    Genesis (H) - A1 - A2 - A3 - A4 - A5 - A6 - A7 - A8
                         \
                          B1 - B2 - B3 - B4 - B5 - B6 - B7 - B8

   **********************************************************)

  module Nametbl = Hashtbl.MakeSeeded (struct
    type t = string

    let hash = Hashtbl.seeded_hash

    let equal = String.equal
  end)

  let build_example_tree store =
    let open Lwt_result_syntax in
    let combine_exn l1 l2 =
      match
        List.combine ~when_different_lengths:(Failure "combine_exn") l1 l2
      with
      | Ok x -> x
      | Error _ -> assert false
    in
    let chain_store = Store.main_chain_store store in
    let main_chain = List.map (fun i -> Format.sprintf "A%d" i) (1 -- 8) in
    let* blocks, _head =
      append_blocks chain_store ~kind:`Full (List.length main_chain)
    in
    let*! main_blocks =
      Lwt_list.filter_map_s
        (fun b -> Store.Block.read_block_opt chain_store (Store.Block.hash b))
        blocks
    in
    let a2 = List.nth main_blocks 2 |> WithExceptions.Option.get ~loc:__LOC__ in
    let main_blocks = combine_exn main_chain main_blocks in
    let branch_chain = List.map (fun i -> Format.sprintf "B%d" i) (1 -- 8) in
    let* branch, _head =
      append_blocks
        chain_store
        ~root:(Store.Block.descriptor a2)
        ~kind:`Full
        (List.length branch_chain)
    in
    let*! branch_blocks =
      Lwt_list.filter_map_s
        (fun b -> Store.Block.read_block_opt chain_store (Store.Block.hash b))
        branch
    in
    let branch_blocks = combine_exn branch_chain branch_blocks in
    let vtbl = Nametbl.create 17 in
    let*! genesis = Store.Chain.genesis_block chain_store in
    Nametbl.add vtbl "Genesis" genesis ;
    List.iter (fun (k, b) -> Nametbl.add vtbl k b) (main_blocks @ branch_blocks) ;
    let* () = assert_presence_in_store chain_store (blocks @ branch) in
    return vtbl

  let rev_lookup block_hash tbl =
    Nametbl.fold
      (fun k b o ->
        match o with
        | None ->
            if Block_hash.equal block_hash (Store.Block.hash b) then Some k
            else None
        | x -> x)
      tbl
      None
    |> WithExceptions.Option.to_exn ~none:Not_found

  let vblock tbl k = Nametbl.find tbl k

  let wrap_test ?keep_dir ?history_mode ?with_gc (name, g) =
    let open Lwt_result_syntax in
    let f _ store =
      let chain_store = Store.main_chain_store store in
      let* tbl = build_example_tree store in
      g chain_store tbl
    in
    wrap_test ?keep_dir ?history_mode ?with_gc (name, f)
end
