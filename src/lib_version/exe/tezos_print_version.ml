(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

(* this is a script run at build time to print out the current version of the
   node *)

open Version
open Current_git_info

let help_string =
  "This script prints out the current version of the\n\
   node as it is deduced from the git tag of the current branch.\n\
   print_version [--major|--minor|--additional-info|--full]"

let () =
  match Sys.argv with
  | [|_; "--major"|] -> print_endline (string_of_int version.major)
  | [|_; "--minor"|] -> print_endline (string_of_int version.minor)
  | [|_; "--additional-info"|] ->
      print_endline (string_of_additional_info version.additional_info)
  | [|_; "--full"|] | [|_|] -> print_endline (Version.to_string version)
  | [|_; "--help"|] -> print_endline help_string
  | _ ->
      print_endline help_string ;
      prerr_endline
        ("invalid argument: " ^ String.concat " " (Array.to_list Sys.argv)) ;
      exit 1
