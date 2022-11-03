(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

include Plonk.Main_protocol

type public_parameters = verifier_public_parameters * transcript

let public_parameters_encoding =
  Data_encoding.tup2 verifier_public_parameters_encoding transcript_encoding

let scalar_array_encoding = Data_encoding.array scalar_encoding

let verify pp ~public_inputs proof =
  Result.value ~default:false
  @@ Tezos_lwt_result_stdlib.Lwtreslib.Bare.Result.catch (fun () ->
         fst @@ verify pp ~public_inputs proof)

let verify_multi_circuits pp ~public_inputs proof =
  Result.value ~default:false
  @@ Tezos_lwt_result_stdlib.Lwtreslib.Bare.Result.catch (fun () ->
         fst
         @@ verify_multi_circuits
              pp
              ~public_inputs:(SMap.of_list public_inputs)
              proof)
