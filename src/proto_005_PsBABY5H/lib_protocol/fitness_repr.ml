(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

type error += Invalid_fitness (* `Permanent *)

let () =
  register_error_kind
    `Permanent
    ~id:"invalid_fitness"
    ~title:"Invalid fitness"
    ~description:"Fitness representation should be exactly 8 bytes long."
    ~pp:(fun ppf () -> Format.fprintf ppf "Invalid fitness")
    Data_encoding.empty
    (function Invalid_fitness -> Some () | _ -> None)
    (fun () -> Invalid_fitness)

let int64_to_bytes i =
  let b = MBytes.create 8 in
  MBytes.set_int64 b 0 i;
  b

let int64_of_bytes b =
  if Compare.Int.(MBytes.length b <> 8) then
    error Invalid_fitness
  else
    ok (MBytes.get_int64 b 0)

let from_int64 fitness =
  [ MBytes.of_string Constants_repr.version_number ;
    int64_to_bytes fitness ]

let to_int64 = function
  | [ version ;
      fitness ]
    when Compare.String.
           (MBytes.to_string version = Constants_repr.version_number) ->
      int64_of_bytes fitness
  | [ version ;
      _fitness (* ignored since higher version takes priority *) ]
    when Compare.String.
           (MBytes.to_string version = Constants_repr.version_number_004) ->
      ok 0L
  | [] -> ok 0L
  | _ -> error Invalid_fitness
