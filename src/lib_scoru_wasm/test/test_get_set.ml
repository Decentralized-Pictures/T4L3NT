(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech  <contact@trili.tech>                       *)
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
    Component:    Lib_scoru_wasm input
    Invocation:   dune exec  src/lib_scoru_wasm/test/test_scoru_wasm.exe \
                    -- test "Set/get"
    Subject:      Input tests for the tezos-scoru-wasm library
*)

open Tztest
open Tezos_webassembly_interpreter
open Tezos_scoru_wasm

(* Use context-binary for testing. *)
module Context = Tezos_context_memory.Context_binary
module Vector = Tezos_lazy_containers.Lazy_vector.Int32Vector

let empty_tree () =
  let open Lwt_syntax in
  let* index = Context.init "/tmp" in
  let empty_store = Context.empty index in
  return @@ Context.Tree.empty empty_store

type Tezos_lazy_containers.Lazy_map.tree += Tree of Context.tree

module Tree : Tezos_tree_encoding.TREE with type tree = Context.tree = struct
  type tree = Context.tree

  include Context.Tree

  let select = function
    | Tree t -> t
    | _ -> raise Tezos_tree_encoding.Incorrect_tree_type

  let wrap t = Tree t
end

module Wasm = Wasm_pvm.Make (Tree)
module Tree_encoding_runner = Tezos_tree_encoding.Runner.Make (Tree)

let current_tick_encoding =
  Tezos_tree_encoding.value ["wasm"; "current_tick"] Data_encoding.n

let floppy_encoding =
  Tezos_tree_encoding.value
    ["gather-floppies"; "status"]
    Gather_floppies.internal_status_encoding

let inp_encoding =
  Tezos_tree_encoding.value ["input"; "0"; "1"] Data_encoding.string

(* Replicates the encoding of buffers from [Wasm_pvm] as part of the pvm_state. *)
let buffers_encoding =
  Tezos_tree_encoding.scope ["pvm"; "buffers"] Wasm_encoding.buffers_encoding

let zero =
  WithExceptions.Option.get
    ~loc:__LOC__
    (Bounded.Non_negative_int32.of_value 0l)

(** Artificial initialization. Under normal circumstances the changes in
    [current_tick], [gather_floppies] and [status] will be done by the other
    PVM operations. for example the [origination_kernel_loading_step] in
    Gather_floppies will initialize both the [current_tick] and the
    [gather_floppies] *)
let initialise_tree () =
  let open Lwt_syntax in
  let* empty_tree = empty_tree () in
  let boot_sector =
    Data_encoding.Binary.to_string_exn
      Gather_floppies.origination_message_encoding
      (Complete_kernel (Bytes.of_string "some boot sector"))
  in
  let* tree =
    Wasm.Internal_for_tests.initial_tree_from_boot_sector
      ~empty_tree
      boot_sector
  in

  let* tree = Tree_encoding_runner.encode current_tick_encoding Z.zero tree in
  Tree_encoding_runner.encode
    floppy_encoding
    Gather_floppies.Not_gathering_floppies
    tree

let make_inbox_info ~inbox_level ~message_counter =
  Wasm_pvm_state.
    {
      inbox_level =
        WithExceptions.Option.get
          ~loc:__LOC__
          (Bounded.Non_negative_int32.of_value (Int32.of_int inbox_level));
      message_counter = Z.of_int message_counter;
    }

let make_output_info ~outbox_level ~message_index =
  Wasm_pvm_state.
    {
      outbox_level =
        WithExceptions.Option.get
          ~loc:__LOC__
          (Bounded.Non_negative_int32.of_value (Int32.of_int outbox_level));
      message_index = Z.of_int message_index;
    }

(** Artificial initialization of the raw_level and message id. Again, in practice
    these will normally be initialized  by the origination step and modified by
    subsequent read_input steps.*)
let add_input_info ~inbox_level ~message_counter tree =
  let open Lwt_syntax in
  let* tree =
    Tree_encoding_runner.encode
      (Tezos_tree_encoding.value_option
         ["wasm"; "input"]
         Wasm_pvm_sig.input_info_encoding)
      (Some (make_inbox_info ~inbox_level ~message_counter))
      tree
  in
  Lwt.return tree

(** Simple test checking get_info after the initialization. Note that we also
    check that if the tree has no last_input_read set the response to [get_info]
    has [None] as [last_input_read] *)
let test_get_info () =
  let open Lwt_syntax in
  let* tree = initialise_tree () in
  let expected_info ~inbox_level ~message_counter =
    let open Wasm_pvm_state in
    let last_input_read =
      Some (make_inbox_info ~inbox_level ~message_counter)
    in
    {
      current_tick = Z.one;
      last_input_read;
      input_request =
        Input_required
        (* While it shouldn't be Input_required after an input, `add_input_info`
           doesn't use the PVM interface but encodes it directly into the tree.
           The tree is in `Input_required` state since it is in snapshot state,
           waiting for the next_input. *);
    }
  in
  let* actual_info = Wasm.get_info tree in
  assert (actual_info.last_input_read = None) ;
  (* We're adding input info by writing directly to the tree. This is for
     testing that the encoder in [Wasm_pvm] reads the corresponding paths. *)
  let* tree = add_input_info ~inbox_level:5 ~message_counter:10 tree in
  let* actual_info = Wasm.get_info tree in
  assert (actual_info = expected_info ~inbox_level:5 ~message_counter:10) ;
  Lwt_result_syntax.return_unit

let encode_tick_state tree =
  let open Lwt_syntax in
  (* Encode the tag. *)
  let* tree =
    Tree_encoding_runner.encode
      (Tezos_tree_encoding.value ["wasm"; "tag"] Data_encoding.string)
      "snapshot"
      tree
  in
  (* Encode the value. *)
  let* tree =
    Tree_encoding_runner.encode
      (Tezos_tree_encoding.value ["wasm"; "value"] Data_encoding.unit)
      ()
      tree
  in
  return tree

(** Tests that, after set_input the resulting tree decodes to the correct values.
    In particular it does check that [get_info] produces the expected value. *)
let test_set_input () =
  let open Lwt_syntax in
  let* tree = initialise_tree () in
  let* tree = add_input_info tree ~inbox_level:5 ~message_counter:10 in
  let* tree = encode_tick_state tree in
  let* tree =
    Wasm.set_input_step
      {inbox_level = zero; message_counter = Z.of_int 1}
      "hello"
      tree
  in
  let* result_input = Tree_encoding_runner.decode inp_encoding tree in
  let* current_tick = Tree_encoding_runner.decode current_tick_encoding tree in
  let expected_info =
    let open Wasm_pvm_state in
    let last_input_read =
      Some (make_inbox_info ~inbox_level:5 ~message_counter:10)
    in
    {
      current_tick = Z.(succ one);
      last_input_read;
      input_request = No_input_required;
    }
  in
  let* actual_info = Wasm.get_info tree in
  assert (actual_info = expected_info) ;
  assert (current_tick = Z.one) ;
  assert (result_input = "hello") ;
  Lwt_result_syntax.return_unit

(** Given a [config] whose output has a given payload at position (0,0), if we
encode [config] into a tree [get_output output_info tree] produces the same
payload. Here the output_info is { outbox_level = 0; message_index = 0 } *)
let test_get_output () =
  let open Lwt_syntax in
  let* tree = initialise_tree () in
  let* tree = add_input_info tree ~inbox_level:5 ~message_counter:10 in
  let host_funcs = Tezos_webassembly_interpreter.Host_funcs.empty () in
  Host_funcs.register_host_funcs host_funcs ;
  let output = Output_buffer.alloc () in
  Output_buffer.set_level output 0l ;
  let* () = Output_buffer.set_value output @@ Bytes.of_string "hello" in
  let buffers = Eval.{input = Input_buffer.alloc (); output} in
  let* tree =
    Tree_encoding_runner.encode
      (Tezos_tree_encoding.option buffers_encoding)
      (Some buffers)
      tree
  in
  let output_info = make_output_info ~outbox_level:0 ~message_index:0 in
  let* payload = Wasm.get_output output_info tree in
  assert (payload = Some "hello") ;
  Lwt_result_syntax.return_unit

let tests =
  [
    tztest "Get info" `Quick test_get_info;
    tztest "Set input" `Quick test_set_input;
    tztest "Get output" `Quick test_get_output;
  ]
