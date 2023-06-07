(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2023 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(** Mocked values used until we can retrieve the specific values from an EVM kernel. *)

open Ethereum_types

module Conv = struct
  let pow_18 = String.make 18 '0'

  (** WEI is the smallest denomination of ether.
        1 ETH = 1,000,000,000,000,000,000 WEI (10^18). *)
  let to_wei x = Z.of_string @@ Int.to_string x ^ pow_18
end

let hash_f = hash_of_string

let qty_f = quantity_of_z

(* Default chain_id for ethereum custom networks with Ganache. *)
let id = Z.of_int 1337

let chain_id = qty_f id

let net_version = Z.to_string id

let block_height_counter = ref 0

let block_height () = block_height_of_z @@ Z.of_int !block_height_counter

let balance = qty_f @@ Conv.to_wei 1000

let code = hash_f "0x"

(* Gas limit must be at least 21000 *)
let gas_price = qty_f @@ Z.of_int 21000

let transaction_counter = ref 0

let transaction_count () = qty_f @@ Z.of_int !transaction_counter

(* Transaction's hash must be an alphanumeric 66 utf8 byte
   hex (chars: a-fA-F) string *)
let transaction_hash =
  hash_f @@ "f837c23ac7150b486be21fc00e3e2ad118e12bec1e2bca401b999f544eabc402"

let block_hash =
  Block_hash "d28d009fef5019bd9b353d7d9d881bde4870d3c5e418b1faf05fd9f7540994d8"

let block () =
  {
    number = Some (block_height ());
    hash = Some block_hash;
    parent = Block_hash (String.make 32 'a');
    nonce = hash_f @@ String.make 8 'a';
    sha3Uncles = hash_f @@ String.make 32 'a';
    logsBloom = Some (hash_f @@ String.make 256 'a');
    transactionRoot = hash_f @@ String.make 32 'a';
    stateRoot = hash_f @@ String.make 32 'a';
    receiptRoot = hash_f @@ String.make 32 'a';
    miner = hash_f @@ String.make 20 'b';
    difficulty = qty_f Z.one;
    totalDifficulty = qty_f Z.one;
    extraData = "";
    size = qty_f @@ Z.of_int 12345;
    gasLimit = qty_f @@ Z.of_int 1111111;
    gasUsed = qty_f Z.zero;
    timestamp = qty_f Z.zero;
    transactions = [transaction_hash];
    uncles = [];
  }

let transaction_receipt () =
  {
    transactionHash = transaction_hash;
    transactionIndex = qty_f Z.zero;
    blockHash = block_hash;
    blockNumber = qty_f @@ Z.of_int !block_height_counter;
    from = address_of_string "6F4d14B90C48bEFb49CA3fe6663dEC70731A8bC7";
    to_ = address_of_string "A5A5bf58c7Dc91cBE5005A7E5c6314998Eda479E";
    contractAddress = None;
    cumulativeGasUsed = gas_price;
    effectiveGasPrice = gas_price;
    gasUsed = gas_price;
    logs = [];
    logsBloom = hash_f @@ String.make 256 'a';
    type_ = qty_f Z.zero;
    status = qty_f Z.one;
  }

let transaction_object =
  {
    blockHash = block_hash;
    blockNumber = qty_f @@ Z.of_int 42;
    from = Address "0x6F4d14B90C48bEFb49CA3fe6663dEC70731A8bC7";
    gas = qty_f Z.zero;
    gasPrice = qty_f Z.zero;
    hash = transaction_hash;
    input = None;
    nonce = qty_f Z.zero;
    to_ = Address "0xA5A5bf58c7Dc91cBE5005A7E5c6314998Eda479E";
    transactionIndex = qty_f Z.zero;
    value = qty_f Z.zero;
    v = qty_f Z.zero;
    r = qty_f Z.zero;
    s = qty_f Z.zero;
  }

let call = hash_f "0x"

let return = Lwt_result_syntax.return

let smart_rollup_address = return "foo"

let balance _addr = return balance

let nonce _addr = return (transaction_count ())

let inject_raw_transaction ~smart_rollup_address:_ _tx =
  incr block_height_counter ;
  incr transaction_counter ;
  return transaction_hash

let current_block ~full_transaction_object:_ = return (block ())

let current_block_number () = return (block_height ())

let nth_block ~full_transaction_object:_ _n = return (block ())

let transaction_receipt _tx_hash = return (transaction_receipt ())
