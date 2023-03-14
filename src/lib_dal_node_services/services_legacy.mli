(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

val split_slot :
  ( [`POST],
    unit,
    unit,
    unit,
    Tezos_crypto_dal.Cryptobox.slot,
    string * Tezos_crypto_dal.Cryptobox.commitment_proof )
  Tezos_rpc.Service.service

val slot :
  ( [`GET],
    unit,
    unit * Tezos_crypto_dal.Cryptobox.commitment,
    unit,
    unit,
    Tezos_crypto_dal.Cryptobox.slot )
  Tezos_rpc.Service.service

val slot_pages :
  ( [`GET],
    unit,
    unit * Tezos_crypto_dal.Cryptobox.commitment,
    unit,
    unit,
    Tezos_crypto_dal.Cryptobox.page list )
  Tezos_rpc.Service.service

val shard :
  ( [`GET],
    unit,
    (unit * Tezos_crypto_dal.Cryptobox.commitment) * int,
    unit,
    unit,
    Tezos_crypto_dal.Cryptobox.shard )
  Tezos_rpc.Service.service

val shards :
  ( [`POST],
    unit,
    unit * Tezos_crypto_dal.Cryptobox.commitment,
    unit,
    int trace,
    Tezos_crypto_dal.Cryptobox.shard list )
  Tezos_rpc.Service.service

val monitor_slot_headers :
  ( [`GET],
    unit,
    unit,
    unit,
    unit,
    Tezos_crypto_dal.Cryptobox.commitment )
  Tezos_rpc.Service.service
