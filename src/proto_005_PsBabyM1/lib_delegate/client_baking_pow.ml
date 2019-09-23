(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

open Protocol

let default_constant = "\x00\x00\x00\x05"

let is_updated_constant =
  let commit_hash =
    if TzString.is_hex Tezos_version.Current_git_info.commit_hash then
      Hex.to_string (`Hex Tezos_version.Current_git_info.commit_hash)
    else Tezos_version.Current_git_info.commit_hash
  in
  if String.length commit_hash >= 4 then String.sub commit_hash 0 4
  else default_constant

let is_updated_cstruct = MBytes.of_string is_updated_constant

let is_updated_constant_len = String.length is_updated_constant

(* add a version to the pow *)
let generate_proof_of_work_nonce () =
  Bytes.concat
    (Bytes.of_string "")
    [ is_updated_cstruct;
      Rand.generate
        ( Alpha_context.Constants.proof_of_work_nonce_size
        - is_updated_constant_len ) ]

(* This was used before November 2018 *)
(* (\* Random proof of work *\)
 * let generate_proof_of_work_nonce () =
 *   Rand.generate Alpha_context.Constants.proof_of_work_nonce_size *)

let empty_proof_of_work_nonce =
  Bytes.of_string (String.make Constants_repr.proof_of_work_nonce_size '\000')

let mine cctxt chain block shell builder =
  Alpha_services.Constants.all cctxt (chain, block)
  >>=? fun constants ->
  let threshold = constants.parametric.proof_of_work_threshold in
  let rec loop () =
    let block = builder (generate_proof_of_work_nonce ()) in
    if Baking.check_header_proof_of_work_stamp shell block threshold then
      return block
    else loop ()
  in
  loop ()
