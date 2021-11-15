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

module Make (Error : sig
  type error = ..

  include Sig.CORE with type error := error
end)
(Trace : Sig.TRACE)
(Monad : Tezos_lwt_result_stdlib.Lwtreslib.TRACED_MONAD
           with type 'error trace := 'error Trace.trace) :
  Sig.MONAD_EXTENSION
    with type error := Error.error
     and type 'error trace := 'error Trace.trace = struct
  open Monad

  (* we default to combined monad everywhere. Note that we include [LwtResult]
     rather than [LwtTracedResult] because [return] and [return_*] functions are
     more generic. The [fail] function is re-shadowed below for more specific
     [fail] default. *)
  include LwtResult

  (* we default to failing within the traced monad *)
  let fail = fail_trace

  let error = error_trace

  (* default (traced-everywhere) helper types *)
  type tztrace = Error.error Trace.trace

  type 'a tzresult = ('a, tztrace) result

  let trace_encoding = Trace.encoding Error.error_encoding

  let result_encoding a_encoding =
    let open Data_encoding in
    let trace_encoding = obj1 (req "error" trace_encoding) in
    let a_encoding = obj1 (req "result" a_encoding) in
    union
      ~tag_size:`Uint8
      [
        case
          (Tag 0)
          a_encoding
          ~title:"Ok"
          (function Ok x -> Some x | _ -> None)
          (function res -> Ok res);
        case
          (Tag 1)
          trace_encoding
          ~title:"Error"
          (function Error x -> Some x | _ -> None)
          (function x -> Error x);
      ]

  let pp_print_trace = Trace.pp_print Error.pp

  let pp_print_top_error_of_trace = Trace.pp_print_top Error.pp

  let classify_trace trace =
    Trace.fold
      (fun c e -> Sig.combine_category c (Error.classify_error e))
      `Temporary
      trace

  let record_trace err result =
    match result with
    | Ok _ as res -> res
    | Error trace -> Error (Trace.cons err trace)

  let trace err f =
    f >>= function
    | Error trace -> Lwt.return_error (Trace.cons err trace)
    | ok -> Lwt.return ok

  let record_trace_eval mk_err = function
    | Error trace -> mk_err () >>? fun err -> Error (Trace.cons err trace)
    | ok -> ok

  let trace_eval mk_err f =
    f >>= function
    | Error trace ->
        mk_err () >>=? fun err -> Lwt.return_error (Trace.cons err trace)
    | ok -> Lwt.return ok

  let error_unless cond exn = if cond then Result.return_unit else error exn

  let error_when cond exn = if cond then error exn else Result.return_unit

  let fail_unless cond exn =
    if cond then LwtTracedResult.return_unit else fail exn

  let fail_when cond exn =
    if cond then fail exn else LwtTracedResult.return_unit

  let unless cond f = if cond then LwtResult.return_unit else f ()

  let when_ cond f = if cond then f () else LwtResult.return_unit

  let dont_wait f err_handler exc_handler =
    Lwt.dont_wait
      (fun () ->
        f () >>= function
        | Ok () -> Lwt.return_unit
        | Error trace ->
            err_handler trace ;
            Lwt.return_unit)
      exc_handler
end
