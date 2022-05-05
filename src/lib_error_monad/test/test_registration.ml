(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
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
    Component:    Error Monad
    Invocation:   dune build @src/lib_error_monad/runtest
    Subject:      On the registration and query of errors.
*)

module MakeExtractInfos () = struct
  open TzCore

  type error += A

  let () =
    register_error_kind
      `Permanent
      ~id:"test.extractinfo"
      ~title:"test-extractinfo"
      ~description:"Test Extract Infos"
      Data_encoding.unit
      (function A -> Some () | _ -> None)
      (fun () -> A)

  let () =
    let infos = find_info_of_error A in
    assert (infos.id = "test.extractinfo") ;
    assert (infos.title = "test-extractinfo")

  let main () = ()
end

let test_extract_infos () =
  let module M = MakeExtractInfos () in
  M.main ()

let tests_extract_infos =
  [Alcotest.test_case "extract-infos" `Quick test_extract_infos]

let () =
  Alcotest.run "error-registration" [("extract-info", tests_extract_infos)]
