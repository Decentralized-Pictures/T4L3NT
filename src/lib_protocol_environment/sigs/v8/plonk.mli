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

type scalar := Bls.Primitive.Fr.t

type public_parameters

type proof

val public_parameters_encoding : public_parameters Data_encoding.t

val proof_encoding : proof Data_encoding.t

val scalar_encoding : scalar Data_encoding.t

val scalar_array_encoding : scalar array Data_encoding.t

(** Verifier function: checks proof
   Inputs:
   - public_parameters: output of setup
   - public_inputs (scalar array): the first values of private_inputs that are public
   - proof: output of prove
   Outputs:
   - bool
*)
val verify : public_parameters -> public_inputs:scalar array -> proof -> bool

(**  Verifier function: checks a bunch of proofs for several circuits
   Inputs:
   - public_parameters: output of setup_multi_circuits for the circuits being checked
   - public_inputs: StringMap where the lists of public inputs are binded with the circuit to which they correspond
   - proof: the unique proof that correspond to all inputs
   Outputs:
   - bool
*)
val verify_multi_circuits :
  public_parameters ->
  public_inputs:(string * scalar array list) list ->
  proof ->
  bool
