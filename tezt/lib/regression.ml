(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Metastate AG <hello@metastate.dev>                     *)
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

open Base

let capture_output : out_channel option ref = ref None

(* Capture a string into a regression output. *)
let capture line =
  match !capture_output with
  | None ->
      ()
  | Some channel ->
      output_string channel line ; output_string channel "\n"

let hooks =
  Process.
    {
      on_spawn =
        (fun command arguments ->
          let message = Log.quote_shell_command command arguments in
          capture "" ; capture message);
      on_log = capture;
    }

(* Replace variables that may change between different runs by constants *)
let replace_variables string =
  let replacements =
    [ ("tz[123]\\w{33}", "[PUBLIC_KEY_HASH]");
      ("edpk\\w{50}", "[PUBLIC_KEY]");
      ("KT1\\w{33}", "[CONTRACT_HASH]");
      ("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z", "[TIMESTAMP]") ]
  in
  List.fold_left
    (fun string (replace, by) ->
      replace_string ~all:true (rex replace) ~by string)
    string
    replacements

let scrubbing_hooks =
  Process.
    {
      on_spawn =
        (fun command arguments ->
          (* remove arguments that shouldn't be captured in regression output *)
          let (arguments, _) =
            List.fold_left
              (fun (acc, scrub_next) arg ->
                if scrub_next then (acc, false)
                else
                  match arg with
                  (* scrub client global options *)
                  | "--base-dir" | "-d" | "--endpoint" | "-E" ->
                      (acc, true)
                  | _ ->
                      (acc @ [replace_variables arg], false))
              ([], (* scrub_next *) false)
              arguments
          in
          let message = Log.quote_shell_command command arguments in
          capture "" ; capture message);
      on_log = (fun output -> replace_variables output |> capture);
    }

(* Run [f] and capture the output of ran processes into the [output_file]. *)
let run_and_capture_output ~output_file (f : unit -> 'a Lwt.t) =
  let rec create_parent filename =
    let parent = Filename.dirname filename in
    if String.length parent < String.length filename then (
      create_parent parent ;
      if not (Sys.file_exists parent) then Unix.mkdir parent 0o755 )
  in
  create_parent output_file ;
  let channel = open_out output_file in
  capture_output := Option.some channel ;
  Lwt.finalize f (fun () ->
      capture_output := None ;
      close_out channel ;
      unit)

(* Log regression output diff, with colors if enabled. *)
let log_regression_diff diff =
  List.iter
    (fun line ->
      if String.length line = 0 then Log.log ~level:Error ""
      else
        let color =
          match line.[0] with
          | '+' ->
              Log.Color.FG.green
          | '-' ->
              Log.Color.FG.red
          | '@' ->
              Log.Color.FG.cyan
          | _ ->
              Log.Color.reset
        in
        Log.log ~level:Error ~color "%s" line)
    (String.split_on_char '\n' diff)

let register ~__FILE__ ~title ~tags ~output_file
    ?(regression_output_path = "tezt/_regressions") f =
  let tags = "regression" :: tags in
  let output_file = Format.asprintf "%s.out" output_file in
  let stored_output_file = regression_output_path // output_file in
  Test.register ~__FILE__ ~title ~tags (fun () ->
      (* when the stored output doesn't already exists, must reset regressions *)
      if
        not
          (Sys.file_exists stored_output_file || Cli.options.reset_regressions)
      then
        Test.fail
          "No existing regression output file found (%s). To generate it, run \
           with option \"--reset-regressions\""
          stored_output_file ;
      let capture_f ~output_file =
        run_and_capture_output ~output_file
        @@ fun () -> capture stored_output_file ; f ()
      in
      if Cli.options.reset_regressions then
        capture_f ~output_file:stored_output_file
      else
        (* store the current run into a temp file *)
        let temp_output_file = Temp.file output_file in
        let* () = capture_f ~output_file:temp_output_file in
        (* compare the captured output with the stored output *)
        let diff_process =
          Process.spawn
            ~log_status_on_exit:false
            ~log_output:false
            "diff"
            [ "--unified=0";
              "--label";
              "stored";
              "--label";
              "actual";
              stored_output_file;
              temp_output_file ]
        in
        let* status = Process.wait diff_process in
        match status with
        | WEXITED 0 ->
            unit
        | _ ->
            let stream = Lwt_io.read_lines (Process.stdout diff_process) in
            let buffer = Buffer.create 1024 in
            let* () =
              Lwt_stream.iter
                (fun line ->
                  Buffer.add_string buffer line ;
                  Buffer.add_string buffer "\n")
                stream
            in
            let diff = Buffer.contents buffer in
            Buffer.reset buffer ;
            log_regression_diff diff ;
            Test.fail "The regression test output contains differences")
