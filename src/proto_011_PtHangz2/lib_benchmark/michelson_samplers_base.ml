(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs, <contact@nomadic-labs.com>               *)
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
open Sampling_helpers

(* Samplers for basic Michelson types. *)

module type Base_S = sig
  val int : Alpha_context.Script_int.z Alpha_context.Script_int.num sampler

  val nat : Alpha_context.Script_int.n Alpha_context.Script_int.num sampler

  val signature : Tezos_crypto.Signature.t sampler

  val string : Alpha_context.Script_string.t sampler

  val bytes : bytes sampler

  val tez : Alpha_context.Tez.tez sampler

  val timestamp : Alpha_context.Script_timestamp.t sampler

  val bool : bool sampler
end

module type Full_S = sig
  val sampling_parameters : Michelson_samplers_parameters.t

  module Crypto_samplers : Crypto_samplers.Finite_key_pool_S

  module Michelson_base : Base_S
end

module Make_base (P : Michelson_samplers_parameters.S) : Base_S = struct
  let int rng_state =
    let i = Base_samplers.int ~size:P.parameters.int_size rng_state in
    Alpha_context.Script_int.of_zint i

  let nat rng_state =
    let i = Base_samplers.nat ~size:P.parameters.int_size rng_state in
    Alpha_context.Script_int.abs (Alpha_context.Script_int.of_zint i)

  let signature rng_state =
    let i = Random.State.int rng_state 4 in
    match i with
    | 0 -> (
        let open Ed25519 in
        let bytes = Base_samplers.uniform_bytes ~nbytes:size rng_state in
        match of_bytes_opt bytes with
        | None -> assert false
        | Some s -> Signature.of_ed25519 s)
    | 1 -> (
        let open Secp256k1 in
        let bytes = Base_samplers.uniform_bytes ~nbytes:size rng_state in
        match of_bytes_opt bytes with
        | None -> assert false
        | Some s -> Signature.of_secp256k1 s)
    | 2 -> (
        let open P256 in
        let bytes = Base_samplers.uniform_bytes ~nbytes:size rng_state in
        match of_bytes_opt bytes with
        | None -> assert false
        | Some s -> Signature.of_p256 s)
    | _ -> (
        let open Signature in
        let bytes = Base_samplers.uniform_bytes ~nbytes:size rng_state in
        match of_bytes_opt bytes with None -> assert false | Some s -> s)

  let string rng_state =
    let s =
      Base_samplers.readable_ascii_string
        ~size:P.parameters.string_size
        rng_state
    in
    match Protocol.Alpha_context.Script_string.of_string s with
    | Ok s -> s
    | Error _ -> assert false

  let bytes = Base_samplers.bytes ~size:P.parameters.bytes_size

  let tez rng_state =
    let i = Random.State.int64 rng_state (Int64.of_int max_int) in
    match Protocol.Alpha_context.Tez.of_mutez i with
    | Some res -> res
    | None -> assert false

  let timestamp rng_state =
    let i = Base_samplers.int ~size:P.parameters.int_size rng_state in
    Protocol.Alpha_context.Script_timestamp.of_zint i

  let bool rng_state = Base_samplers.uniform_bool rng_state
end

module Make_full (P : Michelson_samplers_parameters.S) : Full_S = struct
  let sampling_parameters = P.parameters

  module Crypto_samplers = Crypto_samplers.Make_finite_key_pool (P)
  module Michelson_base = Make_base (P)
end
