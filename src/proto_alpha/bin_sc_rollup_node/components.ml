(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

module type S = sig
  module PVM : Pvm.S

  module Interpreter : Interpreter.S with module PVM = PVM

  module Commitment : Commitment_sig.S with module PVM = PVM

  module RPC_server : RPC_server.S with module PVM = PVM

  module Refutation_game : Refutation_game.S with module PVM = PVM
end

module Make (PVM : Pvm.S) : S with module PVM = PVM = struct
  module PVM = PVM
  module Interpreter = Interpreter.Make (PVM)
  module Commitment = Commitment.Make (PVM)
  module RPC_server = RPC_server.Make (PVM)
  module Refutation_game = Refutation_game.Make (Interpreter)
end

let pvm_of_kind : Protocol.Alpha_context.Sc_rollup.Kind.t -> (module Pvm.S) =
  function
  | Example_arith -> (module Arith_pvm)
  | Wasm_2_0_0 -> (module Wasm_2_0_0_pvm)
