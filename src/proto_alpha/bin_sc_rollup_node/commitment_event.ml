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

open Protocol
open Alpha_context

module Simple = struct
  include Internal_event.Simple

  let section = ["sc_rollup_node"; "commitment"]

  let starting =
    declare_0
      ~section
      ~name:"sc_rollup_commitment_publisher_starting"
      ~msg:"Starting commitment publisher for the smart contract rollup node"
      ~level:Notice
      ()

  let stopping =
    declare_0
      ~section
      ~name:"sc_rollup_node_commitment_publisher_stopping"
      ~msg:"Stopping commitment publisher for the smart contract rollup node"
      ~level:Notice
      ()

  let commitment_will_not_be_published =
    declare_5
      ~section
      ~name:"sc_rollup_node_commitment_will_not_be_published"
      ~msg:
        "Commitment will not be published: its inbox level is less or equal \
         than the last cemented commitment level {lcc_level} - predecessor: \
         {predecessor}, inbox_level: {inbox_level}, compressed_state: \
         {compressed_state}, number_of_ticks: {number_of_ticks}"
      ~level:Notice
      ("lcc_level", Raw_level.encoding)
      ("predecessor", Sc_rollup.Commitment.Hash.encoding)
      ("inbox_level", Raw_level.encoding)
      ("compressed_state", Sc_rollup.State_hash.encoding)
      ("number_of_ticks", Sc_rollup.Number_of_ticks.encoding)

  let last_cemented_commitment_updated =
    declare_2
      ~section
      ~name:"sc_rollup_node_lcc_updated"
      ~msg:
        "Last cemented commitment was updated to hash {hash} at inbox level \
         {level}"
      ~level:Notice
      ("hash", Sc_rollup.Commitment.Hash.encoding)
      ("level", Raw_level.encoding)

  let compute_commitment =
    declare_2
      ~section
      ~name:"sc_rollup_node_commitment_process_head"
      ~msg:
        "Computing and storing new commitment for head {head} at level {level}"
      ~level:Notice
      ("head", Block_hash.encoding)
      ("level", Raw_level.encoding)

  let commitment_parent_is_not_lcc =
    declare_3
      ~section
      ~name:"sc_rollup_commitment_parent_is_not_lcc"
      ~msg:
        "Trying to publish a commitment at inbox level {level} whose parent is \
         the last cemented commitment, but the commitment's predecessor hash \
         {predecessor_hash} differs from the last cemented commitment hash \
         {lcc_hash}. This is a critical error, and the rollup node will be \
         terminated."
      ~level:Fatal
      ("level", Raw_level.encoding)
      ("predecessor_hash", Sc_rollup.Commitment.Hash.encoding)
      ("lcc_hash", Sc_rollup.Commitment.Hash.encoding)

  let commitment_stored =
    declare_5
      ~section
      ~name:"sc_rollup_node_commitment_stored"
      ~msg:
        "Commitment {commitment_hash} was stored - predecessor: {predecessor}, \
         inbox_level: {inbox_level}, compressed_state: {compressed_state}, \
         number_of_ticks: {number_of_ticks}"
      ~level:Notice
      ("commitment_hash", Sc_rollup.Commitment.Hash.encoding)
      ("predecessor", Sc_rollup.Commitment.Hash.encoding)
      ("inbox_level", Raw_level.encoding)
      ("compressed_state", Sc_rollup.State_hash.encoding)
      ("number_of_ticks", Sc_rollup.Number_of_ticks.encoding)
end

let starting = Simple.(emit starting)

let stopping = Simple.(emit stopping)

open Sc_rollup.Commitment

let emit_commitment_event f commitment_hash
    {predecessor; inbox_level; compressed_state; number_of_ticks} =
  Simple.(
    emit
      f
      ( commitment_hash,
        predecessor,
        inbox_level,
        compressed_state,
        number_of_ticks ))

let commitment_will_not_be_published lcc_level
    {predecessor; inbox_level; compressed_state; number_of_ticks} =
  Simple.(
    emit
      commitment_will_not_be_published
      (lcc_level, predecessor, inbox_level, compressed_state, number_of_ticks))

let commitment_stored = emit_commitment_event Simple.commitment_stored

let last_cemented_commitment_updated head level =
  Simple.(emit last_cemented_commitment_updated (head, level))

let compute_commitment head level =
  Simple.(emit compute_commitment (head, level))

let commitment_parent_is_not_lcc level predecessor_hash lcc_hash =
  Simple.(emit commitment_parent_is_not_lcc (level, predecessor_hash, lcc_hash))
