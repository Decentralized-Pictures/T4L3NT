(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(** Testing
    -------
    Component:    PBT for the SCORU refutation game
    Invocation:   dune exec \
                  src/proto_alpha/lib_protocol/test/pbt/test_refutation_game.exe
    Subject:      SCORU refutation game
*)
open Protocol

open Alpha_context
open Sc_rollup
open Lwt_syntax
open Lib_test.Qcheck2_helpers

(**

   Helpers

*)

let hash_state state number =
  Digest.bytes @@ Bytes.of_string @@ state ^ string_of_int number

type dummy_proof = {
  start : State_hash.t;
  stop : State_hash.t option;
  valid : bool;
}

module Tick_map = Map.Make (Sc_rollup_tick_repr)

let dummy_proof_encoding : dummy_proof Data_encoding.t =
  let open Data_encoding in
  conv
    (fun {start; stop; valid} -> (start, stop, valid))
    (fun (start, stop, valid) -> {start; stop; valid})
    (obj3
       (req "start" State_hash.encoding)
       (req "stop" (option State_hash.encoding))
       (req "valid" bool))

let proof_start_state proof = proof.start

let proof_stop_state proof = proof.stop

let number_of_ticks_exn n =
  match Number_of_ticks.of_int32 n with
  | Some x -> x
  | None -> Stdlib.failwith "Bad Number_of_ticks"

let get_comm pred inbox_level ticks state =
  Commitment.
    {
      predecessor = pred;
      inbox_level = Raw_level.of_int32_exn inbox_level;
      number_of_ticks = number_of_ticks_exn ticks;
      compressed_state = state;
    }

let gen_random_hash =
  let open QCheck2.Gen in
  let* x = bytes_fixed_gen 32 in
  return @@ State_hash.of_bytes_exn x

let tick_of_int_exn n =
  match Tick.of_int n with None -> assert false | Some t -> t

let tick_to_int_exn t =
  match Tick.to_int t with None -> assert false | Some n -> n

(* Default number of sections in a dissection *)
let gen_num_sections =
  let open Tezos_protocol_alpha_parameters.Default_parameters in
  let testnet = constants_test.sc_rollup.number_of_sections_in_dissection in
  let mainnet = constants_mainnet.sc_rollup.number_of_sections_in_dissection in
  let sandbox = constants_sandbox.sc_rollup.number_of_sections_in_dissection in
  QCheck2.Gen.(
    frequency
      [
        (5, pure mainnet);
        (4, pure testnet);
        (2, pure sandbox);
        (1, int_range 4 100);
      ])

let mk_dissection_chunk (state_hash, tick) = Game.{state_hash; tick}

let random_dissection ~default_number_of_sections start_at start_hash stop_at
    stop_hash =
  let open QCheck2.Gen in
  let start_int = tick_to_int_exn start_at in
  let stop_int = tick_to_int_exn stop_at in
  let dist = stop_int - start_int in
  let branch = min (dist + 1) default_number_of_sections in
  let size = (dist + 1) / (branch - 1) in

  if dist = 1 then return None
  else
    let* random_hash = gen_random_hash in
    return
    @@ Result.to_option
         (List.init branch ~when_negative_length:"error" (fun i ->
              mk_dissection_chunk
              @@
              if i = 0 then (Some start_hash, start_at)
              else if i = branch - 1 then (stop_hash, stop_at)
              else (Some random_hash, tick_of_int_exn (start_int + (i * size)))))

(**
 `genlist` is a `correct list` generator. It generates a list of strings that
  are either integers or `+` to be consumed by the arithmetic PVM.
  If a `+` is found then the previous two element of the stack are poped
   then added and the result is pushed to the stack.
   In particular, lists like `[1 +]` are incorrect.

  To preserve the correctness invariant, genlist is a recursive generator that
  produce a pair `(stack_size, state_list)` where  state_list is a correct list
  of integers and `+` and consuming it will produce a `stack` of length
  `stack_size`.
  For example a result can be `(3, [1; 2; +; 3; +; 2; 2; +; 1;]).
  Consuming the list will produce the stack`[6; 4; 2]` which has length 3.
  The generator has two branches.
  1. with frequency 1 adds integers to state_list and increases the
  corresponding stack_size.
  2. With frequency 2, at each step, it looks at the inductive result
  `(self (n - 1))=(stack_size, state_list)`.
  If the stack_size is smaller than 2 then it adds an integer to the state_list
   and increases the stack_size
  Otherwise it adds a plus to the state_list and decreases the stack_size.
  Remark: The algorithm is linear in the size of the generated list and
  generates all kinds of inputs not only those that produce a stack of size 1.
*)
let gen_list ~size =
  QCheck2.Gen.(
    map (fun (_, l) -> List.rev l)
    @@ sized_size size
    @@ fix (fun self n ->
           match n with
           | 0 -> map (fun x -> (1, [string_of_int x])) small_nat
           | n ->
               frequency
                 [
                   ( 2,
                     map2
                       (fun x (stack_size, state_list) ->
                         if stack_size >= 2 then
                           (stack_size - 1, "+" :: state_list)
                         else (stack_size + 1, string_of_int x :: state_list))
                       small_nat
                       (self (n - 1)) );
                   ( 1,
                     map2
                       (fun x (i, y) -> (i + 1, string_of_int x :: y))
                       small_nat
                       (self (n - 1)) );
                 ]))

(** This uses the above generator to produce a correct program with at
    least 3 elements.  *)

let correct_program =
  let open QCheck2.Gen in
  gen_list ~size:(3 -- 1000)

module type TestPVM = sig
  include PVM.S with type hash = State_hash.t

  module Utils : sig
    (** This a post-boot state. It is used as default in many functions. *)
    val default_state : state

    (*TODO: These are not used in the current state. They are, however to be
      used in the incoming more sophisticated set of tests from Thomas Athorne
    *)

    (** [random_state n state] generates a random state. The integer n is
        used as a seed in the generation. *)
    val random_state : int -> state -> state QCheck2.Gen.t

    (** [make_proof start_state stop_state] produces a proof that the eval of
        [start_state] is the [stop_state].
        It will be used by the `verify_proof`. In the arithPVM we use
        `produce_tree_proof` which only requires a starting state (tree)
        and the transition function. *)
    val make_proof : state -> hash option -> proof Lwt.t

    (** Like [make_proof] but produces an invalid proof starting from
        any hash. *)
    val make_invalid_proof : hash -> hash option -> proof Lwt.t
  end
end

(**

   [MakeCountingPVM (P)] is a PVM whose state is an integer and that
   can count up to a certain [P.target].

   This PVM has no input states.

*)
module MakeCountingPVM (P : sig
  val target : int
end) : TestPVM with type state = int = struct
  let name = "countingPVM"

  let parse_boot_sector x = Some x

  let pp_boot_sector fmt x = Format.fprintf fmt "%s" x

  type state = int

  let pp x = Lwt.return @@ fun fmt _ -> Format.pp_print_int fmt x

  type hash = State_hash.t

  type context = unit

  type proof = dummy_proof

  let proof_start_state = proof_start_state

  let proof_stop_state = proof_stop_state

  let proof_input_given _ = None

  let proof_input_requested _ = No_input_required

  let state_hash_ (x : state) =
    State_hash.context_hash_to_state_hash
    @@ Context_hash.hash_string [Int.to_string x]

  let state_hash (x : state) = return (state_hash_ x)

  let is_input_state x =
    if x >= P.target then return Initial else return No_input_required

  let initial_state _ = return 0

  let install_boot_sector _ _ = return P.target

  let set_input _ s = return s

  module Utils = struct
    let default_state = P.target

    let random_state _ _ = QCheck2.Gen.int

    let make_proof s1 s2 =
      let* s1 = state_hash s1 in
      return {start = s1; stop = s2; valid = true}

    let make_invalid_proof s1 s2 = return {start = s1; stop = s2; valid = false}
  end

  let proof_encoding = dummy_proof_encoding

  let eval state = if state >= P.target then return state else return (state + 1)

  let verify_proof proof = return proof.valid

  let produce_proof _ _ _ = Stdlib.failwith "Dummy PVM can't produce proof"

  let verify_origination_proof proof _ = return proof.valid

  let produce_origination_proof _ _ =
    Stdlib.failwith "Dummy PVM can't produce proof"

  type output_proof = unit

  let output_proof_encoding = Data_encoding.unit

  let state_of_output_proof _ =
    Stdlib.failwith "Dummy PVM can't handle output proof"

  let output_of_output_proof _ =
    Stdlib.failwith "Dummy PVM can't handle output proof"

  let verify_output_proof _ =
    Stdlib.failwith "Dummy PVM can't handle output proof"

  let produce_output_proof _ _ _ =
    Stdlib.failwith "Dummy PVM can't handle output proof"

  module Internal_for_tests = struct
    let insert_failure _ = Stdlib.failwith "Dummy PVM does not insert failures"
  end
end

(** This is a random PVM. Its state is a pair of a string and a
    list of integers. An evaluation step consumes the next integer
    of the list and concatenates its representation to the string. *)
module MakeRandomPVM (P : sig
  val initial_prog : int list
end) : TestPVM with type state = string * int list = struct
  let name = "randomPVM"

  let parse_boot_sector x = Some x

  let pp_boot_sector fmt x = Format.fprintf fmt "%s" x

  type state = string * int list

  let pp (s, xs) =
    Lwt.return @@ fun fmt _ ->
    Format.fprintf
      fmt
      "%s / %s"
      s
      (String.concat ":" @@ List.map string_of_int xs)

  type context = unit

  type proof = dummy_proof

  type hash = State_hash.t

  let to_string (a, b) =
    Format.sprintf "(%s, [%s])" a (String.concat ";" @@ List.map Int.to_string b)

  let proof_start_state = proof_start_state

  let proof_stop_state = proof_stop_state

  let proof_input_given _ = None

  let proof_input_requested _ = No_input_required

  let state_hash_ x =
    State_hash.context_hash_to_state_hash
    @@ Context_hash.hash_string [to_string x]

  let state_hash (x : state) = return @@ state_hash_ x

  let initial_state _ = return ("", [])

  let install_boot_sector _ _ = return ("hello", P.initial_prog)

  let is_input_state (_, c) =
    match c with [] -> return Initial | _ -> return No_input_required

  let set_input _ state = return state

  module Utils = struct
    let default_state = ("hello", P.initial_prog)

    let random_state length ((_, program) : state) =
      let open QCheck2.Gen in
      let remaining_program = TzList.drop_n length program in
      let+ stop_state = int in
      (hash_state "" stop_state, remaining_program)

    let make_proof s1 s2 =
      let* s1 = state_hash s1 in
      return {start = s1; stop = s2; valid = true}

    let make_invalid_proof s1 s2 = return {start = s1; stop = s2; valid = false}
  end

  let proof_encoding = dummy_proof_encoding

  let eval (hash, continuation) =
    match continuation with
    | [] -> return (hash, continuation)
    | h :: tl -> return (hash_state hash h, tl)

  let verify_proof proof = return proof.valid

  let produce_proof _ _ _ = Stdlib.failwith "Dummy PVM can't produce proof"

  let verify_origination_proof proof _ = return proof.valid

  let produce_origination_proof _ _ =
    Stdlib.failwith "Dummy PVM can't produce proof"

  type output_proof = unit

  let output_proof_encoding = Data_encoding.unit

  let state_of_output_proof _ =
    Stdlib.failwith "Dummy PVM can't handle output proof"

  let output_of_output_proof _ =
    Stdlib.failwith "Dummy PVM can't handle output proof"

  let verify_output_proof _ =
    Stdlib.failwith "Dummy PVM can't handle output proof"

  let produce_output_proof _ _ _ =
    Stdlib.failwith "Dummy PVM can't handle output proof"

  module Internal_for_tests = struct
    let insert_failure _ = Stdlib.failwith "Dummy PVM does not insert failures"
  end
end

module ContextPVM = ArithPVM.Make (struct
  open Tezos_context_memory.Context

  module Tree = struct
    include Tezos_context_memory.Context.Tree

    type tree = Tezos_context_memory.Context.tree

    type t = Tezos_context_memory.Context.t

    type key = string list

    type value = bytes
  end

  type tree = Tree.tree

  let hash_tree tree =
    Sc_rollup.State_hash.context_hash_to_state_hash (Tree.hash tree)

  type proof = Proof.tree Proof.t

  let verify_proof proof f =
    Lwt.map Result.to_option (verify_tree_proof proof f)

  let produce_proof context state f =
    let* proof =
      produce_tree_proof (index context) (`Value (Tree.hash state)) f
    in
    return (Some proof)

  let kinded_hash_to_state_hash = function
    | `Value hash | `Node hash -> State_hash.context_hash_to_state_hash hash

  let proof_before proof = kinded_hash_to_state_hash proof.Proof.before

  let proof_after proof = kinded_hash_to_state_hash proof.Proof.after

  let proof_encoding =
    let open Data_encoding in
    conv (fun _ -> ()) (fun _ -> assert false) unit
end)

module TestArith (P : sig
  val inputs : string

  val evals : int
end) : TestPVM = struct
  include ContextPVM

  let init_context = Tezos_context_memory.make_empty_context ()

  module Utils = struct
    let make_external_inbox_message str =
      WithExceptions.Result.get_ok
        ~loc:__LOC__
        Inbox.Message.(External str |> serialize)

    let default_state =
      let promise =
        let* boot = initial_state init_context in
        let* boot = install_boot_sector boot "" in
        let* boot = eval boot in
        Format.printf "%s\n\n\n" P.inputs ;
        let input =
          {
            inbox_level = Raw_level.root;
            message_counter = Z.zero;
            payload = make_external_inbox_message P.inputs;
          }
        in
        let prelim = set_input input boot in
        List.fold_left (fun acc _ -> acc >>= fun acc -> eval acc) prelim
        @@ List.repeat P.evals ()
      in
      Lwt_main.run promise

    let random_state i state =
      let open QCheck2.Gen in
      let+ program = correct_program in
      let input =
        {
          inbox_level = Raw_level.root;
          message_counter = Z.zero;
          payload = make_external_inbox_message @@ String.concat " " program;
        }
      in
      let prelim = set_input input state in
      let open Lwt in
      Lwt_main.run
      @@ List.fold_left (fun acc _ -> acc >>= fun acc -> eval acc) prelim
      @@ List.repeat (min i (List.length program - 2) + 1) ()

    let make_proof s1 _s2 =
      let* proof_opt = produce_proof init_context None s1 in
      match proof_opt with Ok proof -> return proof | Error _ -> assert false

    let make_invalid_proof _ _ =
      let* state = initial_state init_context in
      let* state = install_boot_sector state "foooobaaar" in
      let* proof_opt = produce_proof init_context None state in
      match proof_opt with Ok proof -> return proof | Error _ -> assert false
  end
end

(**
   This module introduces some testing strategies for a game created
   from a PVM.
*)
module Strategies (PVM : TestPVM with type hash = State_hash.t) = struct
  (** [exec_all state tick] runs eval until the state machine reaches a
      state where it requires an input. It returns the new state and the
      final tick.
      *)
  let exec_all state tick =
    let rec loop state tick =
      let* isinp = PVM.is_input_state state in
      match isinp with
      | No_input_required ->
          let* s = PVM.eval state in
          let* hash1 = PVM.state_hash state in
          let* hash2 = PVM.state_hash s in

          if State_hash.equal hash1 hash2 then assert false
          else loop s (Tick.next tick)
      | _ -> return (state, tick)
    in
    loop state tick

  (** [state_at to_tick from_state from_tick] returns the state at tick
      [to_tick], or [None] if that's past the point at which the machine
      has stopped. *)
  let state_at to_tick from_state from_tick =
    let rec loop state tick =
      let* isinp = PVM.is_input_state state in
      if Tick.equal to_tick tick then return (Some state, tick)
      else
        match isinp with
        | No_input_required ->
            let* s = PVM.eval state in
            let* hash1 = PVM.state_hash state in
            let* hash2 = PVM.state_hash s in

            if State_hash.equal hash1 hash2 then assert false
            else loop s (Tick.next tick)
        | _ -> return (None, to_tick)
    in
    loop from_state from_tick

  (** [dissection_of_section start_tick start_state stop_tick] creates
     a dissection with at most {!default_number_of_sections} pieces
     that are (roughly) equal
     spaced and whose states are computed by running the eval function
     until the correct tick. Note that the last piece can be as much
     as {!default_number_of_sections} - 1 ticks longer than the others. *)
  let dissection_of_section ~default_number_of_sections start_tick start_state
      stop_tick =
    let start_int = tick_to_int_exn start_tick in
    let stop_int = tick_to_int_exn stop_tick in
    let dist = stop_int - start_int in
    if dist = 1 then return None
    else
      let branch = min (dist + 1) default_number_of_sections in
      let size = (dist + 1) / (branch - 1) in
      let tick_list =
        Result.to_option
        @@ List.init branch ~when_negative_length:"error" (fun i ->
               if i = branch - 1 then stop_tick
               else tick_of_int_exn (start_int + (i * size)))
      in
      let a =
        Option.map
          (fun a ->
            List.map
              (fun tick ->
                let hash =
                  Lwt_main.run
                  @@ let* state, (_ : Tick.t) =
                       state_at tick start_state start_tick
                     in
                     match state with
                     | None -> return None
                     | Some s ->
                         let* h = PVM.state_hash s in
                         return (Some h)
                in
                mk_dissection_chunk (hash, tick))
              a)
          tick_list
      in
      return a

  type client = {
    initial : (Tick.t * PVM.hash) option Lwt.t;
    gen_next_move : Game.t -> Game.refutation option Lwt.t QCheck2.Gen.t;
  }

  type outcome_for_tests = Defender_wins | Refuter_wins

  let equal_outcome a b =
    match (a, b) with
    | Defender_wins, Defender_wins -> true
    | Refuter_wins, Refuter_wins -> true
    | _ -> false

  let loser_to_outcome_for_tests loser alice_is_refuter =
    match loser with
    | Game.Bob -> if alice_is_refuter then Refuter_wins else Defender_wins
    | Game.Alice -> if alice_is_refuter then Defender_wins else Refuter_wins

  let run ~default_number_of_sections ~inbox ~refuter_client ~defender_client =
    let refuter, (_ : public_key), (_ : Signature.secret_key) =
      Signature.generate_key ()
    in
    let defender, (_ : public_key), (_ : Signature.secret_key) =
      Signature.generate_key ()
    in
    let alice_is_refuter = Staker.(refuter < defender) in
    let initial_game =
      let* start_hash = PVM.state_hash PVM.Utils.default_state in
      let* initial_data = defender_client.initial in
      let tick, initial_hash =
        match initial_data with None -> assert false | Some s -> s
      in
      let int_tick = tick_to_int_exn tick in
      let number_of_ticks = Int32.of_int int_tick in
      let parent = get_comm Commitment.Hash.zero 0l 1l start_hash in
      let child =
        get_comm Commitment.Hash.zero 0l number_of_ticks initial_hash
      in
      Lwt.return
      @@ Game.initial
           inbox
           ~pvm_name:PVM.name
           ~parent
           ~child
           ~refuter
           ~defender
           ~default_number_of_sections
    in

    let outcome =
      let rec loop game refuter_move =
        let open QCheck2.Gen in
        let* move =
          if refuter_move then refuter_client.gen_next_move game
          else defender_client.gen_next_move game
        in
        let move = Lwt_main.run move in
        match move with
        | None ->
            return
            @@ Lwt.return (if refuter_move then Defender_wins else Refuter_wins)
        | Some move -> (
            let game_result = Lwt_main.run @@ Game.play game move in
            match game_result with
            | Either.Left outcome ->
                return
                @@ Lwt.return
                     (loser_to_outcome_for_tests outcome.loser alice_is_refuter)
            | Either.Right game -> loop game (not refuter_move))
      in
      loop (Lwt_main.run initial_game) true
    in
    outcome

  let random_tick ?(from = 0) ~into () =
    let open QCheck2.Gen in
    let* x = from -- into in
    return @@ Option.value ~default:Tick.initial (Tick.of_int x)

  (**
  checks that the stop state of a section conflicts with the one computed by the
   evaluation.
  *)
  let conflicting_section tick state =
    let* new_state, (_ : Tick.t) =
      state_at tick PVM.Utils.default_state Tick.initial
    in
    let* new_hash =
      match new_state with
      | None -> return None
      | Some state ->
          let* state = PVM.state_hash state in
          return (Some state)
    in

    return @@ not (Option.equal ( = ) state new_hash)

  (** This function assembles a random decision from a given dissection.
    It first picks a random section from the dissection and modifies randomly
     its states.
    If the length of this section is one tick the returns a conclusion with
    the given modified states.
    If the length is longer it creates a random decision and outputs a Refine
     decision with this dissection.*)
  let random_decision ~default_number_of_sections d =
    let open QCheck2.Gen in
    let number_of_somes =
      List.length
        (List.filter (fun {Game.state_hash; _} -> Option.is_some state_hash) d)
    in
    let* x = int_range 0 (number_of_somes - 1) in
    let x = if x = number_of_somes - 1 then max 0 (x - 1) else x in
    let start_hash, start =
      match List.nth d x with
      | Some Game.{state_hash = Some s; tick = t} -> (s, t)
      | _ -> assert false
    in
    let (_ : State_hash.t option), stop =
      match List.nth d (x + 1) with
      | Some Game.{state_hash; tick} -> (state_hash, tick)
      | None -> assert false
    in
    let* stop_hash = gen_random_hash in

    let random_dissection =
      random_dissection
        ~default_number_of_sections
        start
        start_hash
        stop
        (Some stop_hash)
    in
    let* random_dissection = random_dissection and* hash = gen_random_hash in

    let game =
      match random_dissection with
      | None ->
          let open Lwt.Syntax in
          let* pvm_proof =
            PVM.Utils.make_invalid_proof start_hash (Some hash)
          in
          let wrapped =
            let module P = struct
              include PVM

              let proof = pvm_proof
            end in
            Unencodable (module P)
          in
          let proof = Proof.{pvm_step = wrapped; inbox = None} in
          Lwt.return (Some Game.{choice = start; step = Proof proof})
      | Some dissection ->
          Lwt.return (Some Game.{choice = start; step = Dissection dissection})
    in

    return game

  (** There are two kinds of strategies, random and machine-directed. *)
  type strategy = Random | MachineDirected

  (**
  [find_conflict dissection] finds the section (if it exists) in a dissection that
    conflicts  with the actual computation. *)
  let find_conflict dissection =
    let rec aux states =
      match states with
      | start :: next :: rest ->
          let Game.{state_hash = start_state; tick = start_tick} = start in
          let Game.{state_hash = next_state; tick = next_tick} = next in
          let* c0 = conflicting_section start_tick start_state in
          let* c = conflicting_section next_tick next_state in
          if c0 then assert false
          else if c then
            if next_state = None then return None
            else
              return (Some ((start_state, start_tick), (next_state, next_tick)))
          else aux (next :: rest)
      | _ -> return None
    in
    aux dissection

  (** [next_move  branching dissection] finds the next move based on a
  dissection.
  It finds the first section of dissection that conflicts with the evaluation.
  If the section has length one tick it returns a move with a Conclude
  conflict_resolution_step.
  If the section is longer it creates a new dissection with branching
  many pieces and returns
   a move with a Refine type conflict_resolution_step.
   *)
  let next_move ~default_number_of_sections dissection =
    let* conflict = find_conflict dissection in
    match conflict with
    | Some ((_, start_tick), (_, next_tick)) ->
        let* start_state, (_ : Tick.t) =
          state_at start_tick PVM.Utils.default_state Tick.initial
        in
        let* next_dissection =
          match start_state with
          | None -> return None
          | Some s ->
              dissection_of_section
                ~default_number_of_sections
                start_tick
                s
                next_tick
        in
        let* stop_state, (_ : Tick.t) =
          match start_state with
          | None -> return (None, next_tick)
          | Some s -> state_at next_tick s start_tick
        in
        let* refutation =
          match next_dissection with
          | None ->
              let* stop_hash =
                match stop_state with
                | None -> return None
                | Some state ->
                    let* s = PVM.state_hash state in
                    return (Some s)
              in
              let* pvm_proof =
                match start_state with
                | Some s -> PVM.Utils.make_proof s stop_hash
                | None -> assert false
              in
              let wrapped =
                let module P = struct
                  include PVM

                  let proof = pvm_proof
                end in
                Unencodable (module P)
              in
              let proof = Proof.{pvm_step = wrapped; inbox = None} in
              return Game.{choice = start_tick; step = Proof proof}
          | Some next_dissection ->
              return
                Game.{choice = start_tick; step = Dissection next_dissection}
        in

        return (Some refutation)
    | None -> return None

  (** This is an automatic client. It generates a "perfect" client. *)
  let machine_directed =
    let start_state = PVM.Utils.default_state in
    let initial =
      let* stop_state, stop_at = exec_all start_state Tick.initial in
      let* stop_hash = PVM.state_hash stop_state in
      return (Some (stop_at, stop_hash))
    in

    let gen_next_move (game : Game.t) =
      let dissection = game.dissection in
      let new_move =
        let* mv =
          next_move
            ~default_number_of_sections:game.default_number_of_sections
            dissection
        in
        match mv with Some move -> return (Some move) | None -> return None
      in
      QCheck2.Gen.return new_move
    in

    {initial; gen_next_move}

  (** This builds a client from a strategy. If the strategy is
     MachineDirected it uses the above constructions.  If the strategy
     is random then it uses a random section for the initial
     commitments and the random decision for the next move. *)
  let player_from_strategy ~default_number_of_sections = function
    | Random ->
        let open QCheck2.Gen in
        let* random_tick =
          random_tick ~from:1 ~into:(default_number_of_sections - 1) ()
        in
        let initial =
          Lwt.Syntax.(
            let random_state = PVM.Utils.default_state in
            let* stop_hash = PVM.state_hash random_state in
            Lwt.return (Some (random_tick, stop_hash)))
        in
        return
          {
            initial;
            gen_next_move =
              (fun game ->
                random_decision
                  ~default_number_of_sections:game.default_number_of_sections
                  game.dissection);
          }
    | MachineDirected -> QCheck2.Gen.return machine_directed

  (** [test_strategies defender_strategy refuter_strategy expectation inbox]
      runs a game based oin the two given strategies and checks that the
      resulting outcome fits the expectations. *)
  let test_strategies ~default_number_of_sections defender_strategy
      refuter_strategy expectation inbox =
    let open QCheck2.Gen in
    let* defender_client =
      player_from_strategy ~default_number_of_sections defender_strategy
    in
    let* refuter_client =
      player_from_strategy ~default_number_of_sections refuter_strategy
    in

    let* outcome =
      run ~default_number_of_sections ~inbox ~defender_client ~refuter_client
    in
    return
      Lwt.Syntax.(
        let* outcome = outcome in
        expectation outcome)

  (** the possible expectation functions *)
  let defender_wins x = Lwt.return @@ equal_outcome Defender_wins x

  let refuter_wins x = Lwt.return @@ equal_outcome Refuter_wins x

  let all_win _ = Lwt.return_true
end

(* just the snapshot of an empty inbox to start.*)
let empty_snapshot =
  let rollup = Address.hash_string [""] in
  let level = Raw_level.root in
  let context = Tezos_protocol_environment.Memory_context.empty in
  let inbox = Lwt_main.run @@ Inbox.empty context rollup level in
  Inbox.take_snapshot inbox

(** The following are the possible combinations of strategy generators. *)
let perfect_perfect (module P : TestPVM) default_number_of_sections :
    bool Lwt.t QCheck2.Gen.t =
  let module R = Strategies (P) in
  R.test_strategies
    ~default_number_of_sections
    MachineDirected
    MachineDirected
    R.defender_wins
    empty_snapshot

let random_random (module P : TestPVM) default_number_of_sections =
  let module R = Strategies (P) in
  R.test_strategies
    ~default_number_of_sections
    Random
    Random
    R.all_win
    empty_snapshot

let random_perfect (module P : TestPVM) default_number_of_sections =
  let module S = Strategies (P) in
  S.test_strategies
    Random
    MachineDirected
    S.refuter_wins
    empty_snapshot
    ~default_number_of_sections

let perfect_random (module P : TestPVM) default_number_of_sections =
  let module S = Strategies (P) in
  S.test_strategies
    MachineDirected
    Random
    S.defender_wins
    empty_snapshot
    ~default_number_of_sections

(* a generator for a randomPVM.*)
let gen_randomPVM =
  let open QCheck2.Gen in
  let* initial_prog = list_size small_int (int_range 1 100) in
  return
    (module MakeRandomPVM (struct
      let initial_prog = initial_prog
    end) : TestPVM)

(* a generator for a countPVM.*)
let gen_countPVM =
  let open QCheck2.Gen in
  let* target = small_int in
  return
    (module MakeCountingPVM (struct
      let target = target
    end) : TestPVM)

(* TODO: 3382 in the case that the inputs are generated with a large enough size
   (say 10000) the limits on encoding/decoding make the test fail.*)
(* a generator for an arithPVM.*)
let gen_arithPVM =
  let open QCheck2.Gen in
  let* inputs = gen_list ~size:(3 -- 100) in
  let* evals = small_int in
  return
    (module TestArith (struct
      let inputs = String.concat " " inputs

      let evals = evals
    end) : TestPVM)

(* [generate_strategy_response strategy_gen pvm_gen] generate the boolean
   response that you get by applying strategy_gen to pvm_gen. The strategy_gen
   is one of [perfect_perfect, perfect_random, random_perfect, random_random]
   and the pvm_gen is one of [gen_randomPVM, gen_countPVM, gen_arithPVM] *)
let generate_strategy_response func gen : bool Lwt.t QCheck2.Gen.t =
  let open QCheck2.Gen in
  let result1 = map func gen in
  let result = result1 <*> gen_num_sections in
  join result

(** This assembles a test from a RandomPVM generator and a strategy generator. *)
let testing_PVM func mod_gen name =
  let open QCheck2 in
  Test.make ~name (generate_strategy_response func mod_gen) (fun x ->
      Lwt_main.run x)

(* generator for a dissection produced from of a fixed section*)
let generate_dissection_of_section (module P : TestPVM) =
  let open P in
  let module S = Strategies (P) in
  let open QCheck2.Gen in
  let* start_at = int_range 1 10000
  and* length = int_range 5 100
  and* stop_hash = gen_random_hash
  and* default_number_of_sections = gen_num_sections in
  let section_start_state = Utils.default_state in
  let section_stop_at = tick_of_int_exn (start_at + length) in
  let section_start_at = tick_of_int_exn start_at in
  let result =
    let open Lwt.Syntax in
    let* option_dissection =
      S.dissection_of_section
        ~default_number_of_sections
        section_start_at
        section_start_state
        section_stop_at
    in
    let dissection =
      match option_dissection with
      | None -> raise (Invalid_argument "no dissection")
      | Some x -> x
    in

    let* start = state_hash section_start_state in

    let* check =
      Game.Internal_for_tests.check_dissection
        ~default_number_of_sections
        ~start_chunk:{state_hash = Some start; tick = section_start_at}
        ~stop_chunk:{state_hash = Some stop_hash; tick = section_stop_at}
        dissection
    in
    Lwt.return (Result.to_option check = Some ())
  in
  return result

let test_dissection_of_section =
  let open QCheck2 in
  let open Gen in
  [
    Test.make
      ~name:"randomVPN"
      (let* x = gen_randomPVM in
       generate_dissection_of_section x)
      (fun r -> Lwt_main.run r);
    Test.make
      ~name:"count"
      (let* x = gen_countPVM in
       generate_dissection_of_section x)
      (fun r -> Lwt_main.run r);
  ]

(* generator for a randomly produced dissection*)
let generate_random_dissection =
  let open QCheck2.Gen in
  let* start_at = int_range 1 10000
  and* length = int_range 5 100
  and* stop_hash = gen_random_hash
  and* default_number_of_sections = gen_num_sections in
  let* start_hash = gen_random_hash in
  let* new_stop_hash = gen_random_hash in
  let section_stop_at = tick_of_int_exn (start_at + length) in
  let section_start_at = tick_of_int_exn start_at in
  let* option_dissection =
    random_dissection
      ~default_number_of_sections
      section_start_at
      start_hash
      section_stop_at
      (Some stop_hash)
  in
  let result =
    let open Lwt.Syntax in
    let dissection =
      match option_dissection with
      | None -> raise (Invalid_argument "no dissection")
      | Some x -> x
    in
    let* check =
      Game.Internal_for_tests.check_dissection
        ~default_number_of_sections
        ~start_chunk:{state_hash = Some start_hash; tick = section_start_at}
        ~stop_chunk:{state_hash = Some new_stop_hash; tick = section_stop_at}
        dissection
    in
    Lwt.return (Result.to_option check = Some ())
  in
  return result

let test_random_dissection =
  let open QCheck2 in
  [Test.make ~name:"random_dissection" generate_random_dissection Lwt_main.run]

let () =
  Alcotest.run
    "Refutation Game"
    [
      ("Dissection tests", qcheck_wrap test_dissection_of_section);
      ("Random dissection", qcheck_wrap test_random_dissection);
      ( "RandomPVM",
        qcheck_wrap
          [
            testing_PVM perfect_perfect gen_randomPVM "perfect-perfect";
            testing_PVM random_random gen_randomPVM "random-random";
            testing_PVM random_perfect gen_randomPVM "random-perfect";
            testing_PVM perfect_random gen_randomPVM "perfect-random";
          ] );
      ( "CountingPVM",
        qcheck_wrap
          [
            testing_PVM perfect_perfect gen_countPVM "perfect-perfect";
            testing_PVM random_random gen_countPVM "random-random";
            testing_PVM random_perfect gen_countPVM "random-perfect";
            testing_PVM perfect_random gen_countPVM "perfect-random";
          ] );
      ( "ArithPVM",
        qcheck_wrap
          [
            testing_PVM perfect_perfect gen_arithPVM "perfect-perfect";
            testing_PVM random_random gen_arithPVM "random-random";
            testing_PVM random_perfect gen_arithPVM "random-perfect";
            testing_PVM perfect_random gen_arithPVM "perfect-random";
          ] );
    ]
