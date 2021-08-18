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

let assert_presence_in_cemented_store ?(with_metadata = true) cemented_store
    blocks =
  List.iter_es
    (fun b ->
      let hash = Block_repr.hash b in
      Cemented_block_store.get_cemented_block_by_hash
        ~read_metadata:with_metadata
        cemented_store
        hash
      >>=? function
      | None ->
          Alcotest.failf
            "assert_presence_in_cemented_store: cannot find block %a"
            pp_raw_block
            b
      | Some b' ->
          if with_metadata then (
            Assert.equal ~msg:"block equality with metadata" b b' ;
            return_unit)
          else (
            Assert.equal_block
              ~msg:"block equality without metadata"
              (Block_repr.header b)
              (Block_repr.header b') ;
            return_unit))
    blocks

let test_cement_pruned_blocks cemented_store =
  make_raw_block_list ~kind:`Pruned (genesis_hash, -1l) 4095
  >>= fun (blocks, _head) ->
  Cemented_block_store.cement_blocks cemented_store ~write_metadata:false blocks
  >>=? fun () ->
  assert_presence_in_cemented_store ~with_metadata:true cemented_store blocks

let test_cement_full_blocks cemented_store =
  make_raw_block_list ~kind:`Full (genesis_hash, -1l) 4095
  >>= fun (blocks, _head) ->
  Cemented_block_store.cement_blocks cemented_store ~write_metadata:false blocks
  >>=? fun () ->
  assert_presence_in_cemented_store ~with_metadata:false cemented_store blocks

let test_metadata_retrieval cemented_store =
  make_raw_block_list ~kind:`Full (genesis_hash, -1l) 100
  >>= fun (blocks, _head) ->
  Cemented_block_store.cement_blocks cemented_store ~write_metadata:true blocks
  >>=? fun () ->
  assert_presence_in_cemented_store ~with_metadata:true cemented_store blocks

let wrap_cemented_store_test (name, f) =
  let cemented_store_init f _ () =
    let prefix_dir = "tezos_indexed_store_test_" in
    Lwt_utils_unix.with_tempdir prefix_dir (fun base_dir ->
        let run f = f base_dir in
        run (fun base_dir ->
            let store_dir = Naming.store_dir ~dir_path:base_dir in
            let chain_dir = Naming.chain_dir store_dir Chain_id.zero in
            Lwt_unix.mkdir (Naming.dir_path chain_dir) 0o700 >>= fun () ->
            Cemented_block_store.init ~readonly:false chain_dir
            >>=? fun cemented_store ->
            Error_monad.protect (fun () ->
                f cemented_store >>=? fun () ->
                Cemented_block_store.close cemented_store ;
                return_unit))
        >>= function
        | Error err ->
            Format.printf
              "@\nTest failed:@\n%a@."
              Error_monad.pp_print_error
              err ;
            Lwt.fail Alcotest.Test_error
        | Ok () -> Lwt.return_unit)
  in
  Alcotest_lwt.test_case name `Quick (cemented_store_init f)

let tests =
  let test_cases =
    List.map
      wrap_cemented_store_test
      [
        ("cementing pruned blocks", test_cement_pruned_blocks);
        ("cementing full blocks", test_cement_full_blocks);
        ("retrieve cemented metadata", test_metadata_retrieval);
      ]
  in
  ("cemented store", test_cases)
