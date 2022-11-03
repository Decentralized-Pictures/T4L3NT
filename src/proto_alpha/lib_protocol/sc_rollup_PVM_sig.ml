(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(** This module introduces the semantics of Proof-generating Virtual Machines.

    A PVM defines an operational semantics for some computational model. The
    specificity of PVMs, in comparison with standard virtual machines, is their
    ability to generate and to validate a *compact* proof that a given atomic
    execution step turned a given state into another one.

    In the smart-contract rollups, PVMs are used for two purposes:

    - They allow for the externalization of rollup execution by completely
      specifying the operational semantics of a given rollup. This
      standardization of the semantics gives a unique and executable source of
      truth about the interpretation of smart-contract rollup inboxes, seen as a
      transformation of a rollup state.

    - They allow for the validation or refutation of a claim that the processing
      of some messages led to a given new rollup state (given an actual source
      of truth about the nature of these messages).
*)

(** An input to a PVM is the [message_counter] element of an inbox at
    a given [inbox_level] and contains a given [payload].

    According the rollup management protocol, the payload must be obtained
    through {!Sc_rollup_inbox_message_repr.serialize} which follows a documented
    format.

    FIXME: https://gitlab.com/tezos/tezos/-/issues/3649

    This type cannot be extended in a retro-compatible way. It should
    be put into a variant.
*)

type inbox_message = {
  inbox_level : Raw_level_repr.t;
  message_counter : Z.t;
  payload : Sc_rollup_inbox_message_repr.serialized;
}

type reveal_data = Raw_data of string | Metadata of Sc_rollup_metadata_repr.t

type input = Inbox_message of inbox_message | Reveal of reveal_data

(** [inbox_message_encoding] encoding value for {!inbox_message}. *)
let inbox_message_encoding =
  let open Data_encoding in
  conv
    (fun {inbox_level; message_counter; payload} ->
      (inbox_level, message_counter, (payload :> string)))
    (fun (inbox_level, message_counter, payload) ->
      let payload = Sc_rollup_inbox_message_repr.unsafe_of_string payload in
      {inbox_level; message_counter; payload})
    (obj3
       (req "inbox_level" Raw_level_repr.encoding)
       (req "message_counter" n)
       (req "payload" string))

let reveal_data_encoding =
  let open Data_encoding in
  let case_raw_data =
    case
      ~title:"raw data"
      (Tag 0)
      (obj2
         (req "reveal_data_kind" (constant "raw_data"))
         (req
            "raw_data"
            (check_size Constants_repr.sc_rollup_message_size_limit bytes)))
      (function Raw_data m -> Some ((), Bytes.of_string m) | _ -> None)
      (fun ((), m) -> Raw_data (Bytes.to_string m))
  and case_metadata =
    case
      ~title:"metadata"
      (Tag 1)
      (obj2
         (req "reveal_data_kind" (constant "metadata"))
         (req "metadata" Sc_rollup_metadata_repr.encoding))
      (function Metadata md -> Some ((), md) | _ -> None)
      (fun ((), md) -> Metadata md)
  in
  union [case_raw_data; case_metadata]

let input_encoding =
  let open Data_encoding in
  let case_inbox_message =
    case
      ~title:"inbox msg"
      (Tag 0)
      (obj2
         (req "input_kind" (constant "inbox_message"))
         (req "inbox_message" inbox_message_encoding))
      (function Inbox_message m -> Some ((), m) | _ -> None)
      (fun ((), m) -> Inbox_message m)
  and case_reveal_revelation =
    case
      ~title:"reveal"
      (Tag 1)
      (obj2
         (req "input_kind" (constant "reveal_revelation"))
         (req "reveal_data" reveal_data_encoding))
      (function Reveal d -> Some ((), d) | _ -> None)
      (fun ((), d) -> Reveal d)
  in
  union [case_inbox_message; case_reveal_revelation]

(** [input_equal i1 i2] return whether [i1] and [i2] are equal. *)
let inbox_message_equal a b =
  let {inbox_level; message_counter; payload} = a in
  (* To be robust to the addition of fields in [input] *)
  Raw_level_repr.equal inbox_level b.inbox_level
  && Z.equal message_counter b.message_counter
  && String.equal (payload :> string) (b.payload :> string)

let reveal_data_equal a b =
  match (a, b) with
  | Raw_data a, Raw_data b -> String.equal a b
  | Raw_data _, _ -> false
  | Metadata a, Metadata b -> Sc_rollup_metadata_repr.equal a b
  | Metadata _, _ -> false

let input_equal a b =
  match (a, b) with
  | Inbox_message a, Inbox_message b -> inbox_message_equal a b
  | Inbox_message _, _ -> false
  | Reveal a, Reveal b -> reveal_data_equal a b
  | Reveal _, _ -> false

module Input_hash =
  Blake2B.Make
    (Base58)
    (struct
      let name = "Sc_rollup_input_hash"

      let title = "A smart contract rollup input hash"

      let b58check_prefix =
        "\001\118\125\135" (* "scd1(37)" decoded from base 58. *)

      let size = Some 20
    end)

type reveal = Reveal_raw_data of Input_hash.t | Reveal_metadata

let reveal_encoding =
  let open Data_encoding in
  let case_raw_data =
    case
      ~title:"Reveal_raw_data"
      (Tag 0)
      (obj2
         (req "reveal_kind" (constant "reveal_raw_data"))
         (req "input_hash" Input_hash.encoding))
      (function Reveal_raw_data s -> Some ((), s) | _ -> None)
      (fun ((), s) -> Reveal_raw_data s)
  and case_metadata =
    case
      ~title:"Reveal_metadata"
      (Tag 1)
      (obj1 (req "reveal_kind" (constant "reveal_metadata")))
      (function Reveal_metadata -> Some () | _ -> None)
      (fun () -> Reveal_metadata)
  in
  union [case_raw_data; case_metadata]

(** The PVM's current input expectations:
    - [No_input_required] if the machine is busy and has no need for new input.

    - [Initial] if the machine has never received an input so expects the very
      first item in the inbox.

    - [First_after (level, counter)] expects whatever comes next after that
      position in the inbox.

    - [Needs_metadata] if the machine needs the metadata to continue
      its execution.
*)
type input_request =
  | No_input_required
  | Initial
  | First_after of Raw_level_repr.t * Z.t
  | Needs_reveal of reveal

(** [input_request_encoding] encoding value for {!input_request}. *)
let input_request_encoding =
  let open Data_encoding in
  union
    ~tag_size:`Uint8
    [
      case
        ~title:"No_input_required"
        (Tag 0)
        (obj1 (req "input_request_kind" (constant "no_input_required")))
        (function No_input_required -> Some () | _ -> None)
        (fun () -> No_input_required);
      case
        ~title:"Initial"
        (Tag 1)
        (obj1 (req "input_request_kind" (constant "initial")))
        (function Initial -> Some () | _ -> None)
        (fun () -> Initial);
      case
        ~title:"First_after"
        (Tag 2)
        (obj3
           (req "input_request_kind" (constant "first_after"))
           (req "level" Raw_level_repr.encoding)
           (req "counter" n))
        (function
          | First_after (level, counter) -> Some ((), level, counter)
          | _ -> None)
        (fun ((), level, counter) -> First_after (level, counter));
      case
        ~title:"Needs_reveal"
        (Tag 3)
        (obj2
           (req "input_request_kind" (constant "needs_reveal"))
           (req "reveal" reveal_encoding))
        (function Needs_reveal p -> Some ((), p) | _ -> None)
        (fun ((), p) -> Needs_reveal p);
    ]

let pp_reveal fmt = function
  | Reveal_raw_data hash -> Input_hash.pp fmt hash
  | Reveal_metadata -> Format.pp_print_string fmt "Reveal metadata"

(** [pp_input_request fmt i] pretty prints the given input [i] to the formatter
    [fmt]. *)
let pp_input_request fmt request =
  match request with
  | No_input_required -> Format.fprintf fmt "No_input_required"
  | Initial -> Format.fprintf fmt "Initial"
  | First_after (l, n) ->
      Format.fprintf
        fmt
        "First_after (level = %a, counter = %a)"
        Raw_level_repr.pp
        l
        Z.pp_print
        n
  | Needs_reveal reveal ->
      Format.fprintf fmt "Needs reveal of %a" pp_reveal reveal

let reveal_equal p1 p2 =
  match (p1, p2) with
  | Reveal_raw_data h1, Reveal_raw_data h2 -> Input_hash.equal h1 h2
  | Reveal_raw_data _, _ -> false
  | Reveal_metadata, Reveal_metadata -> true
  | Reveal_metadata, _ -> false

(** [input_request_equal i1 i2] return whether [i1] and [i2] are equal. *)
let input_request_equal a b =
  match (a, b) with
  | No_input_required, No_input_required -> true
  | No_input_required, _ -> false
  | Initial, Initial -> true
  | Initial, _ -> false
  | First_after (l, n), First_after (m, o) ->
      Raw_level_repr.equal l m && Z.equal n o
  | First_after _, _ -> false
  | Needs_reveal p1, Needs_reveal p2 -> reveal_equal p1 p2
  | Needs_reveal _, _ -> false

(** Type that describes output values. *)
type output = {
  outbox_level : Raw_level_repr.t;
      (** The outbox level containing the message. The level corresponds to the
          inbox level for which the message was produced.  *)
  message_index : Z.t;  (** The message index. *)
  message : Sc_rollup_outbox_message_repr.t;  (** The message itself. *)
}

(** [output_encoding] encoding value for {!output}. *)
let output_encoding =
  let open Data_encoding in
  conv
    (fun {outbox_level; message_index; message} ->
      (outbox_level, message_index, message))
    (fun (outbox_level, message_index, message) ->
      {outbox_level; message_index; message})
    (obj3
       (req "outbox_level" Raw_level_repr.encoding)
       (req "message_index" n)
       (req "message" Sc_rollup_outbox_message_repr.encoding))

(** [pp_output fmt o] pretty prints the given output [o] to the formatter
    [fmt]. *)
let pp_output fmt {outbox_level; message_index; message} =
  Format.fprintf
    fmt
    "@[%a@;%a@;%a@;@]"
    Raw_level_repr.pp
    outbox_level
    Z.pp_print
    message_index
    Sc_rollup_outbox_message_repr.pp
    message

module type S = sig
  (** The state of the PVM denotes a state of the rollup.

      The life cycle of the PVM is as follows. It starts its execution
      from an {!initial_state}. The initial state is specialized at
      origination with a [boot_sector], using the
      {!install_boot_sector} function. The resulting state is call the
      “genesis” of the rollup.

      Afterwards, we classify states into two categories: "internal
      states" do not require any external information to be executed
      while "input states" are waiting for some information from the
      inbox to be executable. *)
  type state

  val pp : state -> (Format.formatter -> unit -> unit) Lwt.t

  (** A state is initialized in a given context. A [context]
      represents the executable environment needed by the state to
      exist. Typically, the rollup node storage can be part of this
      context to allow the PVM state to be persistent. *)
  type context

  (** A [hash] characterizes the contents of a state. *)
  type hash = Sc_rollup_repr.State_hash.t

  (** During interactive refutation games, a player may need to provide a proof
      that a given execution step is valid. The PVM implementation is
      responsible for ensuring that this proof type has the correct semantics.

      A proof [p] has four parameters:

       - [start_hash := proof_start_state p]
       - [stop_hash := proof_stop_state p]
       - [input_requested := proof_input_requested p]
       - [input_given := proof_input_given p]

      The following predicate must hold of a valid proof:

      [exists start_state, stop_state.
              (state_hash start_state == start_hash)
          AND (Option.map state_hash stop_state == stop_hash)
          AND (is_input_state start_state == input_requested)
          AND (match (input_given, input_requested) with
              | (None, No_input_required) -> eval start_state == stop_state
              | (None, Initial) -> stop_state == None
              | (None, First_after (l, n)) -> stop_state == None
              | (Some input, No_input_required) -> true
              | (Some input, Initial) ->
                  set_input input_given start_state == stop_state
              | (Some input, First_after (l, n)) ->
                  set_input input_given start_state == stop_state)]

      In natural language---the two hash parameters [start_hash] and [stop_hash]
      must have actual [state] values (or possibly [None] in the case of
      [stop_hash]) of which they are the hashes. The [input_requested] parameter
      must be the correct request from the [start_hash], given according to
      [is_input_state]. Finally there are four possibilities of [input_requested]
      and [input_given].

      - if no input is required, or given, the proof is a simple [eval]
          step ;
      - if input was required but not given, the [stop_hash] must be
          [None] (the machine is blocked) ;
      - if no input was required but some was given, this makes no sense
          and it doesn't matter if the proof is valid or invalid (this
          case will be ruled out by the inbox proof anyway) ;
      - finally, if input was required and given, the proof is a
        [set_input] step. *)
  type proof

  (** [proof]s are embedded in L1 refutation game operations using
      [proof_encoding]. Given that the size of L1 operations are limited, it is
      of *critical* importance to make sure that no execution step of the PVM
      can generate proofs that do not fit in L1 operations when encoded. If such
      a proof existed, the rollup could get stuck. *)
  val proof_encoding : proof Data_encoding.t

  (** [proof_start_state proof] returns the initial state hash of the [proof]
      execution step. *)
  val proof_start_state : proof -> hash

  (** [proof_stop_state proof] returns the final state hash of the [proof]
      execution step. *)
  val proof_stop_state : proof -> hash

  (** [state_hash state] returns a compressed representation of [state]. *)
  val state_hash : state -> hash Lwt.t

  (** [initial_state context] is the initial state of the PVM, before
      its specialization with a given [boot_sector].

      The [context] argument is required for technical reasons and does
      not impact the result. *)
  val initial_state : context -> state Lwt.t

  (** [install_boot_sector state boot_sector] specializes the initial
      [state] of a PVM using a dedicated [boot_sector], submitted at
      the origination of the rollup. *)
  val install_boot_sector : state -> string -> state Lwt.t

  (** [is_input_state state] returns the input expectations of the
      [state]---does it need input, and if so, how far through the inbox
      has it read so far? *)
  val is_input_state : state -> input_request Lwt.t

  (** [set_input input state] sets [input] in [state] as the next
      input to be processed. This must answer the [input_request]
      from [is_input_state state]. *)
  val set_input : input -> state -> state Lwt.t

  (** [eval s0] returns a state [s1] resulting from the
      execution of an atomic step of the rollup at state [s0]. *)
  val eval : state -> state Lwt.t

  (** [verify_proof input p] checks the proof [p] with input [input] and returns
      the [input_request] before the evaluation of the proof. See the doc-string
      for the [proof] type.

      [verify_proof input p] fails when the proof is invalid in regards to the
      given input. *)
  val verify_proof : input option -> proof -> input_request tzresult Lwt.t

  (** [produce_proof ctxt input_given state] should return a [proof] for
      the PVM step starting from [state], if possible. This may fail for
      a few reasons:
        - the [input_given] doesn't match the expectations of [state] ;
        - the [context] for this instance of the PVM doesn't have access
        to enough of the [state] to build the proof. *)
  val produce_proof : context -> input option -> state -> proof tzresult Lwt.t

  (** [verify_origination_proof proof boot_sector] verifies a proof
      supposedly generated by [produce_origination_proof]. *)
  val verify_origination_proof : proof -> string -> bool Lwt.t

  (** [produce_origination_proof context boot_sector] produces a proof
      [p] covering the specialization of a PVM, from the
      [initial_state] up to the genesis state wherein the
      [boot_sector] has been installed. *)
  val produce_origination_proof : context -> string -> proof tzresult Lwt.t

  (** The following type is inhabited by the proofs that a given [output]
      is part of the outbox of a given [state]. *)
  type output_proof

  (** [output_proof_encoding] encoding value for [output_proof]s. *)
  val output_proof_encoding : output_proof Data_encoding.t

  (** [output_of_output_proof proof] returns the [output] that is referred to in
      [proof]'s statement. *)
  val output_of_output_proof : output_proof -> output

  (** [state_of_output_proof proof] returns the [state] hash that is referred to
      in [proof]'s statement. *)
  val state_of_output_proof : output_proof -> hash

  (** [verify_output_proof output_proof] returns [true] iff [proof] is a valid
      witness that its [output] is part of its [state]'s outbox. *)
  val verify_output_proof : output_proof -> bool Lwt.t

  (** [produce_output_proof ctxt state output] returns a proof that witnesses
      the fact that [output] is part of [state]'s outbox. *)
  val produce_output_proof :
    context -> state -> output -> (output_proof, error) result Lwt.t

  module Internal_for_tests : sig
    (** [insert_failure state] corrupts the PVM state. This is used in
        the loser mode of the rollup node. *)
    val insert_failure : state -> state Lwt.t
  end
end
