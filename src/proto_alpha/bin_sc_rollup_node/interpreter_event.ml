(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 TriliTech <contact@trili.tech>                         *)
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

open Protocol.Alpha_context.Sc_rollup

module Make (PVM : Pvm.S) = struct
  module Simple = struct
    include Internal_event.Simple

    let section = ["sc_rollup_node"; PVM.name; "interpreter"]

    let transitioned_pvm =
      declare_4
        ~section
        ~name:"sc_rollup_node_interpreter_transitioned_pvm"
        ~msg:
          "Transitioned PVM at inbox level {inbox_level} to {state_hash} at \
           tick {ticks} with {num_messages} messages"
        ~level:Notice
        ("inbox_level", Protocol.Alpha_context.Raw_level.encoding)
        ("state_hash", State_hash.encoding)
        ("ticks", Tick.encoding)
        ("num_messages", Data_encoding.z)

    let intended_failure =
      declare_4
        ~section
        ~name:"sc_rollup_node_interpreter_intended_failure"
        ~msg:
          "Intended failure at level {level} for message indexed \
           {message_index} and at the tick {message_tick} of message \
           processing (internal = {internal})."
        ~level:Notice
        ("level", Data_encoding.int31)
        ("message_index", Data_encoding.int31)
        ("message_tick", Data_encoding.int31)
        ("internal", Data_encoding.bool)
  end

  let transitioned_pvm inbox_level state num_messages =
    let open Lwt_syntax in
    let* hash = PVM.state_hash state in
    let* ticks = PVM.get_tick state in
    Simple.(emit transitioned_pvm (inbox_level, hash, ticks, num_messages))

  let intended_failure ~level ~message_index ~message_tick ~internal =
    Simple.(
      emit intended_failure (level, message_index, message_tick, internal))
end
