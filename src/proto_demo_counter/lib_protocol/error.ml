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

type error += Demo_error of int

type error += Invalid_operation

type error += Failed_to_parse_parameter of MBytes.t

type error += Invalid_protocol_parameters

let () =
  let open Error_monad in
  let open Data_encoding in
  register_error_kind
    `Temporary
    ~id:"demo.proto.failed_to_parse_parameter"
    ~title:"Failed to parse parameter"
    ~description:"The protocol parameters are not valid JSON."
    ~pp:(fun ppf bytes ->
      Format.fprintf
        ppf
        "Cannot parse the protocol parameter: %s"
        (MBytes.to_string bytes))
    (obj1 (req "contents" bytes))
    (function Failed_to_parse_parameter data -> Some data | _ -> None)
    (fun data -> Failed_to_parse_parameter data) ;
  register_error_kind
    `Temporary
    ~id:"demo.proto.invalid_protocol_parameters"
    ~title:"Invalid protocol parameters"
    ~description:"Unexpected JSON object."
    ~pp:(fun ppf () -> Format.fprintf ppf "Invalid protocol parameters.")
    (obj1 (req "data" empty))
    (function Invalid_protocol_parameters -> Some () | _ -> None)
    (fun () -> Invalid_protocol_parameters) ;
  register_error_kind
    `Permanent
    ~id:"demo.proto.demo_error"
    ~title:"Demo Example Error"
    ~description:"Dummy error to illustrate error definition in the protocol."
    ~pp:(fun ppf i -> Format.fprintf ppf "Expected demo error: %d." i)
    (obj1 (req "data" int31))
    (function Demo_error x -> Some x | _ -> None)
    (fun x -> Demo_error x) ;
  register_error_kind
    `Temporary
    ~id:"demo.proto.invalid_operation"
    ~title:"Invalid Operation"
    ~description:"Operation can't be applied. A and B must remain positive."
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Operation can't be applied. A and B must remain positive.")
    (obj1 (req "data" empty))
    (function Invalid_operation -> Some () | _ -> None)
    (fun () -> Invalid_operation)
