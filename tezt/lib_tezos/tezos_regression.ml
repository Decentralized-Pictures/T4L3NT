(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021-2022 Nomadic Labs <contact@nomadic-labs.com>           *)
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

(* Replace variables that may change between different runs by constants.

   Order them by length.
*)
let replace_variables string =
  let replacements =
    [
      ("sh1\\w{71}\\b", "[DAL_SLOT_HEADER]");
      (* TODO: https://gitlab.com/tezos/tezos/-/issues/3752
         Remove this regexp as soon as the WASM PVM stabilizes. *)
      ("scs\\w{51}\\b", "[SC_ROLLUP_PVM_STATE_HASH]");
      ("\\bB\\w{50}\\b", "[BLOCK_HASH]");
      ("Co\\w{50}\\b", "[CONTEXT_HASH]");
      ("txi\\w{50}\\b", "[TX_ROLLUP_INBOX_HASH]");
      ("txmr\\w{50}\\b", "[TX_ROLLUP_MESSAGE_RESULT_HASH]");
      ("txm\\w{50}\\b", "[TX_ROLLUP_MESSAGE_HASH]");
      ("txmr\\w{50}\\b", "[TX_ROLLUP_MESSAGE_RESULT_HASH]");
      ("txM\\w{50}\\b", "[TX_ROLLUP_MESSAGE_RESULT_LIST_HASH]");
      ("txc\\w{50}\\b", "[TX_ROLLUP_COMMITMENT_HASH]");
      ("scc1\\w{50}\\b", "[SC_ROLLUP_COMMITMENT_HASH]");
      ("scib1\\w{50}\\b", "[SC_ROLLUP_INBOX_HASH]");
      ("edpk\\w{50}\\b", "[PUBLIC_KEY]");
      ("\\bo\\w{50}\\b", "[OPERATION_HASH]");
      ("tz[123]\\w{33}\\b", "[PUBLIC_KEY_HASH]");
      ("txr1\\w{33}\\b", "[TX_ROLLUP_HASH]");
      ("tz4\\w{33}\\b", "[TX_ROLLUP_PUBLIC_KEY_HASH]");
      ("scr1\\w{33}\\b", "[SC_ROLLUP_HASH]");
      ("KT1\\w{33}\\b", "[CONTRACT_HASH]");
      ("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z", "[TIMESTAMP]");
      (* Ports are non-deterministic when using -j. *)
      ("/localhost:\\d{4,5}/", "/localhost:[PORT]/");
    ]
  in
  List.fold_left
    (fun string (replace, by) ->
      replace_string ~all:true (rex replace) ~by string)
    string
    replacements

let hooks =
  let on_spawn command arguments =
    (* Remove arguments that shouldn't be captured in regression output. *)
    let arguments, _ =
      List.fold_left
        (fun (acc, scrub_next) arg ->
          if scrub_next then (acc, false)
          else
            match arg with
            (* scrub client global options *)
            | "--base-dir" | "-d" | "--endpoint" | "-E" | "--sources" ->
                (acc, true)
            | _ -> (acc @ [replace_variables arg], false))
        ([], (* scrub_next *) false)
        arguments
    in
    let message = Log.quote_shell_command command arguments in
    Regression.capture ("\n" ^ message)
  in
  let on_log output = replace_variables output |> Regression.capture in
  {Process.on_spawn; on_log}
