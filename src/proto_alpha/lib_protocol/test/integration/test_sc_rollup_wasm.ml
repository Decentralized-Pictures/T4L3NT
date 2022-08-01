(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2022 Trili Tech, <contact@trili.tech>                       *)
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

(** Testing
    -------
    Component:    sc rollup wasm
    Invocation:   dune exec \
                  src/proto_alpha/lib_protocol/test/integration/main.exe \
                  -- test "^sc rollup wasm$"
    Subject:      Test the WASM 2.0 PVM.
*)

open Protocol
open Alpha_context
module Context_binary = Tezos_context_memory.Context_binary

module Tree :
  Environment.Context.TREE
    with type t = Context_binary.t
     and type tree = Context_binary.tree
     and type key = string list
     and type value = bytes = struct
  type t = Context_binary.t

  type tree = Context_binary.tree

  type key = Context_binary.key

  type value = Context_binary.value

  include Context_binary.Tree
end

module WASM_P :
  Protocol.Alpha_context.Sc_rollup.Wasm_2_0_0PVM.P
    with type Tree.t = Context_binary.t
     and type Tree.tree = Context_binary.tree
     and type Tree.key = string list
     and type Tree.value = bytes
     and type proof = Context_binary.Proof.tree Context_binary.Proof.t = struct
  module Tree = Tree

  type tree = Tree.tree

  type proof = Context_binary.Proof.tree Context_binary.Proof.t

  let proof_encoding =
    Tezos_context_helpers.Merkle_proof_encoding.V2.Tree2.tree_proof_encoding

  let kinded_hash_to_state_hash :
      Context_binary.Proof.kinded_hash -> Sc_rollup.State_hash.t = function
    | `Value hash | `Node hash ->
        Sc_rollup.State_hash.context_hash_to_state_hash hash

  let proof_before proof =
    kinded_hash_to_state_hash proof.Context_binary.Proof.before

  let proof_after proof =
    kinded_hash_to_state_hash proof.Context_binary.Proof.after

  let produce_proof context tree step =
    let open Lwt_syntax in
    let* context = Context_binary.add_tree context [] tree in
    let _hash = Context_binary.commit ~time:Time.Protocol.epoch context in
    let index = Context_binary.index context in
    match Context_binary.Tree.kinded_key tree with
    | Some k ->
        let* p = Context_binary.produce_tree_proof index k step in
        return (Some p)
    | None ->
        Stdlib.failwith
          "produce_proof: internal error, [kinded_key] returned [None]"

  let verify_proof proof step =
    let open Lwt_syntax in
    let* result = Context_binary.verify_tree_proof proof step in
    match result with
    | Ok v -> return (Some v)
    | Error _ ->
        (* We skip the error analysis here since proof verification is not a
           job for the rollup node. *)
        return None
end

module Verifier = Alpha_context.Sc_rollup.Wasm_2_0_0PVM.ProtocolImplementation

module Prover = Alpha_context.Sc_rollup.Wasm_2_0_0PVM.Make (WASM_P)
(* Helpers *)

let complete_boot_sector sector :
    Tezos_scoru_wasm.Gather_floppies.origination_message =
  Complete_kernel (Bytes.of_string sector)

let incomplete_boot_sector sector Account.{pk; _} :
    Tezos_scoru_wasm.Gather_floppies.origination_message =
  Incomplete_kernel (Bytes.of_string sector, pk)

let find tree key encoding =
  let open Lwt.Syntax in
  let+ value = Context_binary.Tree.find tree key in
  match value with
  | Some bytes -> Some (Data_encoding.Binary.of_bytes_exn encoding bytes)
  | None -> None

let find_status tree =
  find
    tree
    ["pvm"; "status"]
    Tezos_scoru_wasm.Gather_floppies.internal_status_encoding

let get_chunks_count tree =
  let open Lwt.Syntax in
  let+ len =
    find tree ["durable"; "kernel"; "boot.wasm"; "len"] Data_encoding.int32
  in
  Option.value ~default:0l len

let check_status tree expected =
  let open Lwt.Syntax in
  let* status = find_status tree in
  match (status, expected) with
  | Some status, Some expected ->
      assert (status = expected) ;
      Lwt.return ()
  | None, None -> Lwt.return ()
  | _, _ -> assert false

let check_chunks_count tree expected =
  let open Lwt.Syntax in
  let* count = get_chunks_count tree in
  if count = expected then Lwt_result.return ()
  else
    failwith
      "wrong chunks counter, expected %d, got %d"
      (Int32.to_int expected)
      (Int32.to_int count)

let operator () =
  match Account.generate_accounts 1 with
  | [(account, _, _)] -> account
  | _ -> assert false

let should_boot_complete_boot_sector boot_sector () =
  let open Tezos_scoru_wasm.Gather_floppies in
  let open Lwt_result_syntax in
  let*! index = Context_binary.init "/tmp" in
  let context = Context_binary.empty index in
  (* The number of chunks necessary to store the kernel. *)
  let nb_chunk_i32 =
    match boot_sector with
    | Complete_kernel bytes | Incomplete_kernel (bytes, _) ->
        let len = Bytes.length bytes |> Int32.of_int in
        let empty = if 0l < Int32.rem len 4_000l then 1l else 0l in
        Int32.(add (div len 4_000l) empty)
  in
  let boot_sector =
    Data_encoding.Binary.to_string_exn origination_message_encoding boot_sector
  in
  (* We create a new PVM, and install the boot sector. *)
  let*! s = Prover.initial_state context in
  let*! s = Prover.install_boot_sector s boot_sector in
  (* After this first step, the PVM has just loaded the boot sector in
     "/boot-sector", and nothing more.  As a consequence, most of the
     step of the [Gather_floppies] instrumentation is not set. *)
  let*! () = check_status s None in
  let* () = check_chunks_count s 0l in
  (* At this step, the [eval] function of the PVM will interpret the
     origination message encoded in [boot_sector]. *)
  let*! s = Prover.eval s in
  (* We expect that the WASM does not expect more floppies, and that
     the kernel as been correctly splitted into several chunks. *)
  let*! () = check_status s (Some Not_gathering_floppies) in
  let* () = check_chunks_count s nb_chunk_i32 in
  return_unit

let floppy_input i operator chunk =
  let open Lwt_result_syntax in
  let signature = Signature.sign operator.Account.sk chunk in
  let floppy = Tezos_scoru_wasm.Gather_floppies.{chunk; signature} in
  match
    Sc_rollup.Inbox.Message.serialize
      (External
         (Data_encoding.Binary.to_string_exn
            Tezos_scoru_wasm.Gather_floppies.floppy_encoding
            floppy))
  with
  | Ok payload ->
      return
        Sc_rollup.
          {
            inbox_level = Raw_level.of_int32_exn 0l;
            message_counter = Z.of_int i;
            payload;
          }
  | Error err ->
      Format.printf "%a@," Environment.Error_monad.pp_trace err ;
      assert false

let should_interpret_empty_chunk () =
  let open Lwt_result_syntax in
  let op = operator () in
  let chunk_size = Tezos_scoru_wasm.Gather_floppies.chunk_size in
  let origination_message =
    Data_encoding.Binary.to_string_exn
      Tezos_scoru_wasm__Gather_floppies.origination_message_encoding
    @@ incomplete_boot_sector (String.make chunk_size 'a') op
  in
  let chunk = Bytes.empty in
  let* correct_input = floppy_input 0 op chunk in

  (* Init the PVM *)
  let*! index = Context_binary.init "/tmp" in
  let context = Context_binary.empty index in
  let*! s = Prover.initial_state context in
  let*! s = Prover.install_boot_sector s origination_message in
  (* Intererptation of the origination message *)
  let*! s = Prover.eval s in
  let*! () = check_status s (Some Gathering_floppies) in
  let* () = check_chunks_count s 1l in
  (* Try to interpret the empty input (correctly signed) *)
  let*! s = Prover.set_input correct_input s in
  let*! () = check_status s (Some Not_gathering_floppies) in
  (* We still have 1 chunk. *)
  let* () = check_chunks_count s 1l in
  return_unit

let should_refuse_chunks_with_incorrect_signature () =
  let open Lwt_result_syntax in
  let good_op = operator () in
  let bad_op = operator () in
  let chunk_size = Tezos_scoru_wasm.Gather_floppies.chunk_size in
  let origination_message =
    Data_encoding.Binary.to_string_exn
      Tezos_scoru_wasm__Gather_floppies.origination_message_encoding
    @@ incomplete_boot_sector (String.make chunk_size 'a') good_op
  in
  let chunk = Bytes.make chunk_size 'b' in
  let* incorrect_input = floppy_input 0 bad_op chunk in
  let* correct_input = floppy_input 0 good_op chunk in

  (* Init the PVM *)
  let*! index = Context_binary.init "/tmp" in
  let context = Context_binary.empty index in
  let*! s = Prover.initial_state context in
  let*! s = Prover.install_boot_sector s origination_message in
  (* Intererptation of the origination message *)
  let*! s = Prover.eval s in
  let*! () = check_status s (Some Gathering_floppies) in
  let* () = check_chunks_count s 1l in
  (* Try to interpret the incorrect input (badly signed) *)
  let*! s = Prover.set_input incorrect_input s in
  let*! () = check_status s (Some Gathering_floppies) in
  (* We still have 1 chunk. *)
  let* () = check_chunks_count s 1l in
  (* Try to interpret the correct input (correctly signed) *)
  let*! s = Prover.set_input correct_input s in
  let*! () = check_status s (Some Gathering_floppies) in
  (* We now have 2 chunks. *)
  let* () = check_chunks_count s 2l in
  return_unit

let should_boot_incomplete_boot_sector () =
  let open Lwt_result_syntax in
  let operator = operator () in
  let chunk_size = Tezos_scoru_wasm.Gather_floppies.chunk_size in
  let initial_chunk =
    Data_encoding.Binary.to_string_exn
      Tezos_scoru_wasm__Gather_floppies.origination_message_encoding
    @@ incomplete_boot_sector (String.make chunk_size 'a') operator
  in
  let chunks = [Bytes.make chunk_size 'b'; Bytes.make chunk_size 'c'] in
  let final_chunk = Bytes.make 2 'd' in

  let*! index = Context_binary.init "/tmp" in
  let context = Context_binary.empty index in
  let*! s = Prover.initial_state context in
  let*! s = Prover.install_boot_sector s initial_chunk in
  let*! () = check_status s None in
  let* () = check_chunks_count s 0l in
  (* First tick, to interpret the boot sector. One chunk have been
     provided, and the PVM expects more chunk to come. *)
  let*! s = Prover.eval s in
  let*! () = check_status s (Some Gathering_floppies) in
  let* () = check_chunks_count s 1l in
  (* Then, installing the additional chunks. *)
  let* s =
    List.fold_left_i_es
      (fun i s chunk ->
        (* We are installing the [i+2]th chunk ([i] starts at 0, and
           the first chunk is not part of the list). *)
        let* input = floppy_input i operator chunk in
        let*! s = Prover.set_input input s in
        (* We are still gathering floppies. *)
        let*! () = check_status s (Some Gathering_floppies) in
        (* We have [i+2] chunks. *)
        let* () = check_chunks_count s Int32.(of_int @@ (i + 2)) in
        return s)
      s
      chunks
  in
  (* Up until the very last one, where the status of the PVM change. *)
  let len = List.length chunks in
  let* input = floppy_input len operator final_chunk in
  let*! s = Prover.set_input input s in
  let*! () = check_status s (Some Not_gathering_floppies) in
  let* () = check_chunks_count s Int32.(of_int @@ (len + 2)) in
  return_unit

let tests =
  [
    Tztest.tztest "should boot a complete boot sector" `Quick
    @@ should_boot_complete_boot_sector
         (complete_boot_sector @@ String.make 10_000 'a');
    ( Tztest.tztest "should boot an incomplete but too small boot sector" `Quick
    @@ fun () ->
      let operator = operator () in
      should_boot_complete_boot_sector
        (incomplete_boot_sector "a nice boot sector" operator)
        () );
    Tztest.tztest
      "should boot an incomplete boot sector with floppies"
      `Quick
      should_boot_incomplete_boot_sector;
    Tztest.tztest
      "should interpret an empty chunk as EOF"
      `Quick
      should_interpret_empty_chunk;
    Tztest.tztest
      "should refuse chunks with an incorrect signature"
      `Quick
      should_refuse_chunks_with_incorrect_signature;
  ]
