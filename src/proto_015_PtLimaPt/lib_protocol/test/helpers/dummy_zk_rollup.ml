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

(** Dummy ZK Rollup for testing the ZKRU integration in the protocol.
    The library Plompiler is used to build the circuits (in a module V as
    verifier) and the corresponding functions to produce the inputs for the
    circuits (in a module P as prover).

    The state of this rollup is a boolean value, which will be
    represented with a scalar value of [zero] for [false] and
    [one] for [true].

    This RU has only one operation, with [op_code] 0. In addition to the
    common header (see {!Zk_rollup_operation_repr}), this operation has
    as payload one scalar representing a boolean value.

    The transition function [f] for this rollup is:

    {[
      f : operation -> state -> state
      f (Op b) s = if b = s then not s else s
    ]}

    That is, the state bool is flipped only if the operation's payload is
    equal to the current state.

    The operation can be used publicly or in a private batch. The circuits
    that describe the RU are:
    - ["op"]: for a single public operation.
    - ["batch-"[N]]: for a batch of [N] private operations. [N] is determined
      by the [batch_size] parameter to the [Operator] functor.
    - ["fee"]: the trivial fees circuit, since this RU has no concept of fees.

    NB: the "op" circuit does not add any constraints over the operation's
    [exit_validity] other than it being in {0, 1}. This means that the dummy
    rollup can be used to test deposits/withdrawals, but the rollup will not
    perform any monetary bookkeeping.
*)

open Plompiler

(** Helper types and modules *)

(** Empty types to represent bounds *)

type balance

type amount

type fee

type op_code

(** Bounds required for the dummy rollup.  *)
module Bound : sig
  type 'a t = private Z.t

  val bound_balance : balance t

  val bound_amount : amount t

  val bound_fee : fee t

  val bound_op_code : op_code t

  val v : 'a t -> Z.t
end = struct
  type 'a t = Z.t

  (** These bounds are exclusive. *)

  (** Upper bound for ticket balance, as found in the price field of an
      operation's header *)
  let bound_balance = Z.(shift_left one 20)

  (** Upper bound for ticket amount, used for fee circuit *)
  let bound_amount = Z.(shift_left one 20)

  (** Upper bound for fee amount of one public operation *)
  let bound_fee = Z.(shift_left one 10)

  (** Upper bound for op code *)
  let bound_op_code = Z.one

  let v x = x
end

(** Modules to manipulate bounded integers, both as OCaml values and in circuit
    representation.
*)
module Bounded = Bounded.Make (Bound)

(** Types used for the Dummy Rollup circuits.
    This module is split into:
    - P: concrete OCaml version of the types,
    - V: Plompiler's circuit representation for P's types, and
    - Encodings: conversion between P and V.
*)
module Types = struct
  module P = struct
    type state = bool

    module Bounded = Bounded.P

    type 'a ticket = {id : S.t; amount : 'a Bounded.t}

    type tezos_pkh = Environment.Signature.Public_key_hash.t

    type header = {
      op_code : op_code Bounded.t;
      price : balance ticket;
      l1_dst : tezos_pkh;
      rollup_id : tezos_pkh;
    }

    type op = {header : header; payload : bool}

    (** Dummy values for these types. Useful to get the circuit without having
        the actual inputs. *)
    module Dummy = struct
      let op_code = Bounded.make ~bound:Bound.bound_op_code Z.zero

      let balance = Bounded.make ~bound:Bound.bound_balance Z.zero

      let tezos_pkh = Environment.Signature.Public_key_hash.zero

      let ticket_balance = {id = S.zero; amount = balance}

      let header =
        {
          op_code;
          price = ticket_balance;
          l1_dst = tezos_pkh;
          rollup_id = tezos_pkh;
        }
    end
  end

  module V (L : LIB) = struct
    open L
    module Bounded_u = Bounded.V (L)

    type 'a ticket_u = {id : scalar repr; amount : 'a Bounded_u.t}

    type tezos_pkh_u = scalar repr

    type header_u = {
      op_code : op_code Bounded_u.t;
      price : balance ticket_u;
      l1_dst : tezos_pkh_u;
      rollup_id : tezos_pkh_u;
    }

    type op_u = {header : header_u; payload : bool repr}
  end

  module Encodings (L : LIB) = struct
    module Bounded_e = Bounded.Encoding (L)
    open P

    open V (L)

    open Encodings (L)

    let op_code_encoding ~safety =
      Bounded_e.encoding ~safety Bound.bound_op_code

    let encoding_to_scalar e x =
      let bs = Data_encoding.Binary.to_bytes_exn e x in
      let z = Z.of_bits @@ Bytes.to_string bs in
      Bls12_381.Fr.of_z z

    let encoding_of_scalar e x =
      let z = Bls12_381.Fr.to_z x in
      let bs = Bytes.of_string @@ Z.to_bits z in
      Data_encoding.Binary.of_bytes_exn e bs

    let tezos_pkh_encoding : (tezos_pkh, tezos_pkh_u, _) encoding =
      conv
        (fun pkhu -> pkhu)
        (fun w -> w)
        (encoding_to_scalar Signature.Public_key_hash.encoding)
        (encoding_of_scalar Signature.Public_key_hash.encoding)
        scalar_encoding

    let amount_encoding ~safety = Bounded_e.encoding ~safety Bound.bound_amount

    let fee_encoding ~safety = Bounded_e.encoding ~safety Bound.bound_fee

    let ticket_encoding ~safety (bound : 'a Bound.t) :
        ('a ticket, 'a ticket_u, _) encoding =
      conv
        (fun {id; amount} -> (id, amount))
        (fun (id, amount) -> {id; amount})
        (fun ({id; amount} : 'a ticket) -> (id, amount))
        (fun (id, amount) -> {id; amount})
        (obj2_encoding scalar_encoding (Bounded_e.encoding ~safety bound))

    let ticket_balance_encoding ~safety =
      ticket_encoding ~safety Bound.bound_balance

    let header_encoding ~safety : (header, header_u, _) encoding =
      conv
        (fun {op_code; price; l1_dst; rollup_id} ->
          (op_code, (price, (l1_dst, rollup_id))))
        (fun (op_code, (price, (l1_dst, rollup_id))) ->
          {op_code; price; l1_dst; rollup_id})
        (fun ({op_code; price; l1_dst; rollup_id} : header) ->
          (op_code, (price, (l1_dst, rollup_id))))
        (fun (op_code, (price, (l1_dst, rollup_id))) ->
          {op_code; price; l1_dst; rollup_id})
        (obj4_encoding
           (op_code_encoding ~safety)
           (ticket_balance_encoding ~safety)
           tezos_pkh_encoding
           tezos_pkh_encoding)

    let op_encoding : (op, op_u, _) encoding =
      conv
        (fun {header; payload} -> (header, payload))
        (fun (header, payload) -> {header; payload})
        (fun ({header; payload} : op) -> (header, payload))
        (fun (header, payload) -> {header; payload})
        (obj2_encoding (header_encoding ~safety:NoCheck) bool_encoding)
  end
end

(** Plompiler circuits for the dummy rollup  *)
module V (L : LIB) = struct
  open L
  module E = Types.Encodings (L)
  module Encodings = Encodings (L)
  open Encodings

  open Types.V (L)

  let coerce (type a) (x : a Bounded_u.t) =
    fst (x : a Bounded_u.t :> scalar repr * Z.t)

  (** Common logic for the state transition function *)
  let logic_op ~old_state ~rollup_id op =
    ignore rollup_id ;
    let* valid = equal old_state op.payload in
    let* new_state = Bool.bnot old_state in
    let* expected_new_state = Bool.ifthenelse valid new_state old_state in
    Num.assert_eq_const (coerce op.header.op_code) S.zero
    (* >* assert_equal rollup_id op.header.rollup_id *)
    >* ret expected_new_state

  (** Circuit definition for one public operation *)
  let predicate_op ?(public = true) ~old_state ~new_state ~fee ~exit_validity
      ~rollup_id op =
    let* old_state = input ~public:true @@ Input.bool old_state in
    let* new_state = input ~public:true @@ Input.bool new_state in
    let* _fee =
      input ~public:true
      @@ E.((fee_encoding ~safety:Bounded_e.Unsafe).input) fee
    in
    let* _exit_validity = input ~public:true @@ Input.bool exit_validity in
    let* rollup_id =
      input ~public:true @@ E.(tezos_pkh_encoding.input) rollup_id
    in
    let* op = input ~public @@ E.op_encoding.input op in
    let op = E.op_encoding.decode op in
    let* expected_new_state = logic_op ~old_state ~rollup_id op in
    assert_equal expected_new_state new_state

  (** Circuit definition for a batch of private operations *)
  let predicate_batch ~old_state ~new_state ~fees ~rollup_id ops =
    let* old_state = input ~public:true @@ Input.bool old_state in
    let* new_state = input ~public:true @@ Input.bool new_state in
    let* _fees =
      input ~public:true
      @@ E.((amount_encoding ~safety:Bounded_e.Unsafe).input) fees
    in
    let* rollup_id =
      input ~public:true @@ E.(tezos_pkh_encoding.input) rollup_id
    in
    let* ops = input @@ (Encodings.list_encoding E.op_encoding).input ops in
    let ops = (Encodings.list_encoding E.op_encoding).decode ops in
    let* computed_final_state =
      foldM
        (fun old_state op -> logic_op ~old_state ~rollup_id op)
        old_state
        ops
    in
    assert_equal computed_final_state new_state

  (** Fee circuit *)
  let predicate_fees ~old_state ~new_state ~fees =
    let* old_state = input ~public:true @@ Input.bool old_state in
    let* new_state = input ~public:true @@ Input.bool new_state in
    let* _fees =
      input ~public:true
      @@ E.((amount_encoding ~safety:Bounded_e.Unsafe).input) fees
    in
    assert_equal old_state new_state
end

(** Basic rollup operator for generating Updates.  *)
module Operator (Params : sig
  val batch_size : int
end) : sig
  open Protocol.Alpha_context

  (** Initial state of the rollup  *)
  val init_state : Zk_rollup.State.t

  (** Map associating every circuit identifier to a boolean representing
      whether the circuit can be part of a private batch *)
  val circuits : bool Plonk.Main_protocol.SMap.t

  (** Commitment to the circuits  *)
  val public_parameters :
    Plonk.Main_protocol.verifier_public_parameters
    * Plonk.Main_protocol.transcript

  module Internal_for_tests : sig
    val true_op : Zk_rollup.Operation.t

    val false_op : Zk_rollup.Operation.t

    val pending : Zk_rollup.Operation.t list

    val private_ops : Zk_rollup.Operation.t list list
  end
end = struct
  open Protocol.Alpha_context
  module SMap = Plonk.Main_protocol.SMap
  module Dummy = Types.P.Dummy
  module T = Types.P
  module VC = V (LibCircuit)

  let srs =
    let open Bls12_381_polynomial.Polynomial in
    (Srs.generate_insecure 8 1, Srs.generate_insecure 1 1)

  let dummy_l1_dst =
    Hex.to_bytes_exn (`Hex "0002298c03ed7d454a101eb7022bc95f7e5f41ac78")

  let dummy_rollup_id =
    (* zkr1PxS4vgvBsf6XVHRSB7UJKcrTWee8Dp7Wx *)
    Hex.to_bytes_exn (`Hex "c9a524d4db6514471775c380231afc10f2ef6ba3")

  let dummy_ticket_hash = Bytes.make 32 '0'

  let _of_proto_state : Zk_rollup.State.t -> Types.P.state =
   fun s -> Bls12_381.Fr.is_one s.(0)

  let to_proto_state : Types.P.state -> Zk_rollup.State.t =
   fun s -> if s then [|Bls12_381.Fr.one|] else [|Bls12_381.Fr.zero|]

  let dummy_op = T.{header = Dummy.header; payload = false}

  let batch_name = "batch-" ^ string_of_int Params.batch_size

  (* Circuits that define the rollup, alongside their public input size and
     solver *)
  let circuit_map =
    let get_circuit _name c =
      let r = LibCircuit.get_cs ~optimize:true c in
      let _initial, public_input_size = LibCircuit.get_inputs c in
      ( Plonk.Circuit.to_plonk ~public_input_size r.cs,
        public_input_size,
        r.solver )
    in
    SMap.of_list
    @@ List.map
         (fun (n, c) -> (n, get_circuit n c))
         [
           ( "op",
             VC.predicate_op
               ~old_state:false
               ~new_state:true
               ~fee:(T.Bounded.make ~bound:Bound.bound_fee Z.zero)
               ~exit_validity:false
               ~rollup_id:Dummy.tezos_pkh
               dummy_op );
           ( batch_name,
             VC.predicate_batch
               ~old_state:false
               ~new_state:true
               ~fees:(T.Bounded.make ~bound:Bound.bound_amount Z.zero)
               ~rollup_id:Dummy.tezos_pkh
               (Stdlib.List.init Params.batch_size (Fun.const dummy_op)) );
           ( "fee",
             VC.predicate_fees
               ~old_state:false
               ~new_state:false
               ~fees:(T.Bounded.make ~bound:Bound.bound_amount Z.zero) );
         ]

  let circuits =
    SMap.(add "op" false @@ add batch_name true @@ add "fee" false empty)

  let public_parameters, _prover_pp =
    let (ppp, vpp), t =
      Plonk.Main_protocol.setup_multi_circuits
        ~zero_knowledge:false
        (SMap.map (fun (a, b, _) -> (a, b)) circuit_map)
        ~srs
    in
    ((vpp, t), ppp)

  let _insert s x m =
    match SMap.find_opt s m with
    | None -> SMap.add s [x] m
    | Some l -> SMap.add s (x :: l) m

  let init_state = to_proto_state false

  module Internal_for_tests = struct
    let true_op =
      Zk_rollup.Operation.
        {
          op_code = 0;
          price =
            (let id =
               Data_encoding.Binary.of_bytes_exn
                 Ticket_hash.encoding
                 dummy_ticket_hash
             in
             {id; amount = Z.zero});
          l1_dst =
            Data_encoding.Binary.of_bytes_exn
              Signature.Public_key_hash.encoding
              dummy_l1_dst;
          rollup_id =
            Data_encoding.Binary.of_bytes_exn
              Zk_rollup.Address.encoding
              dummy_rollup_id;
          payload = [|Bls12_381.Fr.one|];
        }

    let false_op = {true_op with payload = [|Bls12_381.Fr.zero|]}

    let pending = [false_op; true_op; true_op]

    let n_batches = 10

    let private_ops =
      Stdlib.List.init n_batches @@ Fun.const
      @@ Stdlib.List.init Params.batch_size (fun i ->
             if i mod 2 = 0 then false_op else true_op)
  end
end
