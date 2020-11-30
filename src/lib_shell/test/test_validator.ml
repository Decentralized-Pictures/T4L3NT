(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

(** Unit tests for validator. Currently only tests that
   events are emitted. *)

(** [init_validator f] setups a mock validator, a mock block validator and
 ** mock chain and passes it them to the test function [f]. *)
let init_validator
    (f :
      Validator.t ->
      Block_validator_process.t ->
      State.Chain.t ->
      'a ->
      unit ->
      unit Lwt.t) test_dir switch () : unit Lwt.t =
  Shell_test_helpers.init_chain test_dir
  >>= (fun (state, chain, idx, _) ->
        Shell_test_helpers.init_mock_p2p Distributed_db_version.Name.zero
        >>=? fun p2p ->
        let db = Distributed_db.create state p2p in
        let validator_environment =
          {
            Block_validator_process.genesis = Shell_test_helpers.genesis;
            user_activated_upgrades = [];
            user_activated_protocol_overrides = [];
          }
        in
        Block_validator_process.init
          validator_environment
          (Block_validator_process.Internal idx)
        >>=? fun block_validator ->
        Validator.create
          state
          db
          Node.default_peer_validator_limits
          Node.default_block_validator_limits
          block_validator
          Node.default_prevalidator_limits
          Node.default_chain_validator_limits
          ~start_testchain:false
        >>=? fun validator ->
        Lwt.return (ok (block_validator, validator, chain)))
  >>= function
  | Ok (block_validator, validator, chain) ->
      f validator block_validator chain switch ()
  | Error errors ->
      Format.printf
        "Could not initialize validator:\n   %a\n"
        pp_print_error
        errors ;
      Format.print_flush () ;
      Lwt.return_unit

(** [wrap f _switch] wraps a test function [f] by setting up a Mock_sink if
   necessary, initializing a mock p2p network, an empty chain state and a
   validator. It passes the validator to the test function [f] *)
let wrap f _switch () =
  Shell_test_helpers.with_empty_mock_sink (fun _ ->
      Lwt_utils_unix.with_tempdir "tezos_test_" (fun test_dir ->
          init_validator f test_dir _switch ()))

(** Start tests *)

(** [validator_events] tests that validator emits activation and shutdown
   events. *)
let validator_events validator block_validator chain _switch () =
  (* activate validator and check that the corresponding event is emitted *)
  let open Shell_test_helpers in
  Validator.activate
    ~start_prevalidator:false
    validator
    ~validator_process:block_validator
    chain
  >>= function
  | Error trace ->
      Format.printf "Error:\n   %a\n" pp_print_error trace ;
      Format.print_flush () ;
      Lwt.return_unit
  | Ok _ ->
      let section =
        Some (Internal_event.Section.make_sanitized ["node"; "validator"])
      in
      let filter = Some section in
      Mock_sink.assert_has_event
        "Should have an activate_chain event"
        ~filter
        ( Internal_event.Notice,
          section,
          `O [("activate_chain.v0", `String "NetXJCwCkKLtb7s")] ) ;
      Mock_sink.clear_events () ;
      (* now shutdown the validator and verify that shutdown events are emitted
        *)
      Validator.shutdown validator
      >>= fun () ->
      Mock_sink.assert_has_events
        "Should have an shutdown_block_validator"
        ~filter
        [ ( Internal_event.Notice,
            section,
            `O [("shutdown_chain_validator.v0", `String "NetXJCwCkKLtb7s")] );
          ( Internal_event.Notice,
            section,
            `O [("shutdown_block_validator.v0", `O [])] ) ] ;
      Lwt.return_unit

let tests =
  [Alcotest_lwt.test_case "validator_events" `Quick (wrap validator_events)]
