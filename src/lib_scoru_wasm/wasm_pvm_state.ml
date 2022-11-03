(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
(* Copyright (c) 2022 Marigold <contact@marigold.dev>                        *)
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

(** Represents the location of an input message. *)
type input_info = {
  inbox_level : Tezos_base.Bounded.Non_negative_int32.t;
      (** The inbox level at which the message exists.*)
  message_counter : Z.t;  (** The index of the message in the inbox. *)
}

(** Represents the location of an output message. *)
type output_info = {
  outbox_level : Tezos_base.Bounded.Non_negative_int32.t;
      (** The outbox level at which the message exists.*)
  message_index : Z.t;  (** The index of the message in the outbox. *)
}

type input_hash = Tezos_webassembly_interpreter.Reveal.input_hash

let input_hash_to_string =
  Tezos_webassembly_interpreter.Reveal.input_hash_to_string

type reveal = Tezos_webassembly_interpreter.Reveal.reveal =
  | Reveal_raw_data of Tezos_webassembly_interpreter.Reveal.input_hash

(** Represents the state of input requests. *)
type input_request =
  | No_input_required  (** The VM does not expect any input. *)
  | Input_required  (** The VM needs input in order to progress. *)
  | Reveal_required of reveal

(** Represents the state of the VM. *)
type info = {
  current_tick : Z.t;
      (** The number of ticks processed by the VM, zero for the initial state.
          [current_tick] must be incremented for each call to [step] *)
  last_input_read : input_info option;
      (** The last message to be read by the VM, if any. *)
  input_request : input_request;  (** The current VM input request. *)
}

(** This module type defines the state for the PVM.
    For use in lib_scoru_wasm only. *)
module Internal_state = struct
  type tick_state =
    | Decode of Tezos_webassembly_interpreter.Decode.decode_kont
    | Link of {
        ast_module : Tezos_webassembly_interpreter.Ast.module_;
        externs :
          Tezos_webassembly_interpreter.Instance.extern
          Tezos_webassembly_interpreter.Instance.Vector.t;
        imports_offset : int32;
      }
    | Init of {
        self : Tezos_webassembly_interpreter.Instance.module_key;
        ast_module : Tezos_webassembly_interpreter.Ast.module_;
        init_kont : Tezos_webassembly_interpreter.Eval.init_kont;
        module_reg : Tezos_webassembly_interpreter.Instance.module_reg;
      }
    | Eval of Tezos_webassembly_interpreter.Eval.config
    | Stuck of Wasm_pvm_errors.t
    | Snapshot

  type pvm_state = {
    last_input_info : input_info option;  (** Info about last read input. *)
    current_tick : Z.t;  (** Current tick of the PVM. *)
    reboot_counter : Z.t;  (** Number of reboots for the current input. *)
    durable : Durable.t;  (** The durable storage of the PVM. *)
    buffers : Tezos_webassembly_interpreter.Eval.buffers;
        (** Input and outut buffers used by the PVM host functions. *)
    tick_state : tick_state;  (** The current tick state. *)
    last_top_level_call : Z.t;
        (** Last tick corresponding to a top-level call. *)
    max_nb_ticks : Z.t;  (** Number of ticks between top level call. *)
    maximum_reboots_per_input : Z.t;
        (** Number of reboots between two inputs. *)
  }
end
