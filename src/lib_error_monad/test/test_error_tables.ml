(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Nomadic Labs <contact@nomadic-labs.com>                *)
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

open Lwt.Infix

module IntErrorTable = Error_table.Make (Hashtbl.Make (struct
  type t = int

  let equal x y = x = y

  let hash x = x
end))

let test_add_remove _ _ =
  let t = IntErrorTable.create 2 in
  IntErrorTable.find_or_make t 0 (fun () -> Error_monad.return 0)
  >>= function
  | Error _ ->
      Assert.fail "Ok 0" "Error _" "find_or_make"
  | Ok n -> (
      if not (n = 0) then
        Assert.fail "Ok 0" (Format.asprintf "Ok %d" n) "find_or_make"
      else
        match IntErrorTable.find_opt t 0 with
        | None ->
            Assert.fail "Some (Ok 0)" "None" "find_opt"
        | Some p -> (
            p
            >>= function
            | Error _ ->
                Assert.fail "Some (Ok 0)" "Some (Error _)" "find_opt"
            | Ok n ->
                if not (n = 0) then
                  Assert.fail
                    "Some (Ok 0)"
                    (Format.asprintf "Some (Ok %d)" n)
                    "find_opt"
                else (
                  IntErrorTable.remove t 0 ;
                  match IntErrorTable.find_opt t 0 with
                  | Some _ ->
                      Assert.fail "None" "Some _" "remove;find_opt"
                  | None ->
                      Lwt.return_unit ) ) )

let test_add_add _ _ =
  let t = IntErrorTable.create 2 in
  IntErrorTable.find_or_make t 0 (fun () -> Error_monad.return 0)
  >>= fun _ ->
  IntErrorTable.find_or_make t 0 (fun () -> Error_monad.return 1)
  >>= fun _ ->
  match IntErrorTable.find_opt t 0 with
  | None ->
      Assert.fail "Some (Ok 0)" "None" "find_opt"
  | Some p -> (
      p
      >>= function
      | Error _ ->
          Assert.fail "Some (Ok 0)" "Some (Error _)" "find_opt"
      | Ok n ->
          if not (n = 0) then
            Assert.fail
              "Some (Ok 0)"
              (Format.asprintf "Some (Ok %d)" n)
              "find_opt"
          else Lwt.return_unit )

let test_length _ _ =
  let t = IntErrorTable.create 2 in
  IntErrorTable.find_or_make t 0 (fun () -> Error_monad.return 0)
  >>= fun _ ->
  IntErrorTable.find_or_make t 1 (fun () -> Error_monad.return 1)
  >>= fun _ ->
  IntErrorTable.find_or_make t 2 (fun () -> Error_monad.return 2)
  >>= fun _ ->
  IntErrorTable.find_or_make t 3 (fun () -> Error_monad.return 3)
  >>= fun _ ->
  let l = IntErrorTable.length t in
  if not (l = 4) then Assert.fail "4" (Format.asprintf "%d" l) "length"
  else Lwt.return_unit

let test_self_clean _ _ =
  let t = IntErrorTable.create 2 in
  IntErrorTable.find_or_make t 0 (fun () -> Lwt.return (Ok 0))
  >>= fun _ ->
  IntErrorTable.find_or_make t 1 (fun () -> Lwt.return (Error []))
  >>= fun _ ->
  IntErrorTable.find_or_make t 2 (fun () -> Lwt.return (Error []))
  >>= fun _ ->
  IntErrorTable.find_or_make t 3 (fun () -> Lwt.return (Ok 3))
  >>= fun _ ->
  IntErrorTable.find_or_make t 4 (fun () -> Lwt.return (Ok 4))
  >>= fun _ ->
  IntErrorTable.find_or_make t 5 (fun () -> Lwt.return (Error []))
  >>= fun _ ->
  let l = IntErrorTable.length t in
  if not (l = 3) then Assert.fail "3" (Format.asprintf "%d" l) "length"
  else Lwt.return_unit

let test_order _ _ =
  let t = IntErrorTable.create 2 in
  let (wter, wker) = Lwt.task () in
  let world = ref [] in
  (* PROMISE A *)
  let p_a =
    IntErrorTable.find_or_make t 0 (fun () ->
        wter
        >>= fun r ->
        world := "a_inner" :: !world ;
        Lwt.return r)
    >>= fun r_a ->
    world := "a_outer" :: !world ;
    Lwt.return r_a
  in
  Lwt_main.yield ()
  >>= fun () ->
  (* PROMISE B *)
  let p_b =
    IntErrorTable.find_or_make t 0 (fun () ->
        world := "b_inner" :: !world ;
        Lwt.return (Ok 1024))
    >>= fun r_b ->
    world := "b_outer" :: !world ;
    Lwt.return r_b
  in
  Lwt_main.yield ()
  >>= fun () ->
  (* Wake up A *)
  Lwt.wakeup wker (Ok 0) ;
  (* Check that both A and B get expected results *)
  p_a
  >>= (function
        | Error _ ->
            Assert.fail "Ok 0" "Error _" "find_or_make(a)"
        | Ok n ->
            if not (n = 0) then
              Assert.fail "Ok 0" (Format.asprintf "Ok %d" n) "find_or_make(a)"
            else Lwt.return_unit)
  >>= fun () ->
  p_b
  >>= (function
        | Error _ ->
            Assert.fail "Ok 0" "Error _" "find_or_make(b)"
        | Ok n ->
            if not (n = 0) then
              Assert.fail "Ok 0" (Format.asprintf "Ok %d" n) "find_or_make(b)"
            else Lwt.return_unit)
  >>= fun () ->
  (* Check that the `world` record is as expected *)
  match !world with
  | ["b_outer"; "a_outer"; "a_inner"] | ["a_outer"; "b_outer"; "a_inner"] ->
      Lwt.return ()
  | world ->
      Assert.fail
        "[outers;a_inner]"
        Format.(asprintf "[%a]" (pp_print_list pp_print_string) world)
        "world"

let tests =
  [ Alcotest_lwt.test_case "add_remove" `Quick test_add_remove;
    Alcotest_lwt.test_case "add_add" `Quick test_add_add;
    Alcotest_lwt.test_case "length" `Quick test_length;
    Alcotest_lwt.test_case "self_clean" `Quick test_length;
    Alcotest_lwt.test_case "order" `Quick test_order ]

let () = Alcotest.run "error_tables" [("error_tables", tests)]
