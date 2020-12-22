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

module Make (Monad : Sigs.Monad.S) : Sigs.Seq.S with module Monad = Monad =
struct
  module Monad = Monad
  open Lwt.Infix
  open Monad
  include Stdlib.Seq

  let ok_nil = Ok Nil

  let return_nil = Lwt.return ok_nil

  let ok_empty = Ok empty

  let return_empty = Lwt.return ok_empty

  let lwt_empty = Lwt.return empty

  (* Like Lwt.apply but specialised for three parameters *)
  let apply3 f x y = try f x y with exn -> Lwt.fail exn

  let rec fold_left_e f acc seq =
    match seq () with
    | Nil ->
        Ok acc
    | Cons (item, seq) ->
        f acc item >>? fun acc -> fold_left_e f acc seq

  let rec fold_left_s f acc seq =
    match seq () with
    | Nil ->
        Lwt.return acc
    | Cons (item, seq) ->
        f acc item >>= fun acc -> fold_left_s f acc seq

  let fold_left_s f acc seq =
    match seq () with
    | Nil ->
        Lwt.return acc
    | Cons (item, seq) ->
        apply3 f acc item >>= fun acc -> fold_left_s f acc seq

  let rec fold_left_es f acc seq =
    match seq () with
    | Nil ->
        Monad.return acc
    | Cons (item, seq) ->
        f acc item >>=? fun acc -> fold_left_es f acc seq

  let fold_left_es f acc seq =
    match seq () with
    | Nil ->
        Monad.return acc
    | Cons (item, seq) ->
        apply3 f acc item >>=? fun acc -> fold_left_es f acc seq

  let rec iter_e f seq =
    match seq () with
    | Nil ->
        ok_unit
    | Cons (item, seq) ->
        f item >>? fun () -> iter_e f seq

  let rec iter_s f seq =
    match seq () with
    | Nil ->
        Lwt.return_unit
    | Cons (item, seq) ->
        f item >>= fun () -> iter_s f seq

  let iter_s f seq =
    match seq () with
    | Nil ->
        Lwt.return_unit
    | Cons (item, seq) ->
        Lwt.apply f item >>= fun () -> iter_s f seq

  let rec iter_es f seq =
    match seq () with
    | Nil ->
        return_unit
    | Cons (item, seq) ->
        f item >>=? fun () -> iter_es f seq

  let iter_es f seq =
    match seq () with
    | Nil ->
        return_unit
    | Cons (item, seq) ->
        Lwt.apply f item >>=? fun () -> iter_es f seq

  let iter_p f seq =
    let rec iter_p f seq acc =
      match seq () with
      | Nil ->
          join_p acc
      | Cons (item, seq) ->
          iter_p f seq (Lwt.apply f item :: acc)
    in
    iter_p f seq []

  let iter_ep f seq =
    let rec iter_ep f seq acc =
      match seq () with
      | Nil ->
          join_ep acc
      | Cons (item, seq) ->
          iter_ep f seq (Lwt.apply f item :: acc)
    in
    iter_ep f seq []

  let rec map_e f seq =
    match seq () with
    | Nil ->
        ok_empty
    | Cons (item, seq) ->
        f item
        >>? fun item ->
        map_e f seq >>? fun seq -> ok (fun () -> Cons (item, seq))

  let rec map_s f seq =
    match seq () with
    | Nil ->
        lwt_empty
    | Cons (item, seq) ->
        f item
        >>= fun item ->
        map_s f seq >>= fun seq -> Lwt.return (fun () -> Cons (item, seq))

  let map_s f seq =
    match seq () with
    | Nil ->
        lwt_empty
    | Cons (item, seq) ->
        Lwt.apply f item
        >>= fun item ->
        map_s f seq >>= fun seq -> Lwt.return (fun () -> Cons (item, seq))

  let rec map_es f seq =
    match seq () with
    | Nil ->
        return_empty
    | Cons (item, seq) ->
        f item
        >>=? fun item ->
        map_es f seq >>=? fun seq -> Monad.return (fun () -> Cons (item, seq))

  let map_es f seq =
    match seq () with
    | Nil ->
        return_empty
    | Cons (item, seq) ->
        Lwt.apply f item
        >>=? fun item ->
        map_es f seq >>=? fun seq -> Monad.return (fun () -> Cons (item, seq))

  let map_p f seq =
    all_p (fold_left (fun acc x -> Lwt.apply f x :: acc) [] seq)
    >|= (* this is equivalent to rev |> to_seq but more direct *)
        Stdlib.List.fold_left (fun s x () -> Cons (x, s)) empty

  let map_ep f seq =
    all_ep (fold_left (fun acc x -> Lwt.apply f x :: acc) [] seq)
    >|=? (* this is equivalent to rev |> to_seq but more direct *)
         Stdlib.List.fold_left (fun s x () -> Cons (x, s)) empty

  let rec filter_e f seq =
    match seq () with
    | Nil ->
        ok_empty
    | Cons (item, seq) -> (
        f item
        >>? function
        | false ->
            filter_e f seq
        | true ->
            filter_e f seq >>? fun seq -> ok (fun () -> Cons (item, seq)) )

  let rec filter_s f seq =
    match seq () with
    | Nil ->
        lwt_empty
    | Cons (item, seq) -> (
        f item
        >>= function
        | false ->
            filter_s f seq
        | true ->
            filter_s f seq
            >>= fun seq -> Lwt.return (fun () -> Cons (item, seq)) )

  let filter_s f seq =
    match seq () with
    | Nil ->
        lwt_empty
    | Cons (item, seq) -> (
        Lwt.apply f item
        >>= function
        | false ->
            filter_s f seq
        | true ->
            filter_s f seq
            >>= fun seq -> Lwt.return (fun () -> Cons (item, seq)) )

  let rec filter_es f seq =
    match seq () with
    | Nil ->
        return_empty
    | Cons (item, seq) -> (
        f item
        >>=? function
        | false ->
            filter_es f seq
        | true ->
            filter_es f seq
            >>=? fun seq -> Monad.return (fun () -> Cons (item, seq)) )

  let filter_es f seq =
    match seq () with
    | Nil ->
        return_empty
    | Cons (item, seq) -> (
        Lwt.apply f item
        >>=? function
        | false ->
            filter_es f seq
        | true ->
            filter_es f seq
            >>=? fun seq -> Monad.return (fun () -> Cons (item, seq)) )

  let rec filter_map_e f seq =
    match seq () with
    | Nil ->
        ok_empty
    | Cons (item, seq) -> (
        f item
        >>? function
        | None ->
            filter_map_e f seq
        | Some item ->
            filter_map_e f seq >>? fun seq -> ok (fun () -> Cons (item, seq)) )

  let rec filter_map_s f seq =
    match seq () with
    | Nil ->
        lwt_empty
    | Cons (item, seq) -> (
        f item
        >>= function
        | None ->
            filter_map_s f seq
        | Some item ->
            filter_map_s f seq
            >>= fun seq -> Lwt.return (fun () -> Cons (item, seq)) )

  let filter_map_s f seq =
    match seq () with
    | Nil ->
        lwt_empty
    | Cons (item, seq) -> (
        Lwt.apply f item
        >>= function
        | None ->
            filter_map_s f seq
        | Some item ->
            filter_map_s f seq
            >>= fun seq -> Lwt.return (fun () -> Cons (item, seq)) )

  let rec filter_map_es f seq =
    match seq () with
    | Nil ->
        return_empty
    | Cons (item, seq) -> (
        f item
        >>=? function
        | None ->
            filter_map_es f seq
        | Some item ->
            filter_map_es f seq
            >>=? fun seq -> Monad.return (fun () -> Cons (item, seq)) )

  let filter_map_es f seq =
    match seq () with
    | Nil ->
        return_empty
    | Cons (item, seq) -> (
        Lwt.apply f item
        >>=? function
        | None ->
            filter_map_es f seq
        | Some item ->
            filter_map_es f seq
            >>=? fun seq -> Monad.return (fun () -> Cons (item, seq)) )

  let rec find f seq =
    match seq () with
    | Nil ->
        None
    | Cons (item, seq) ->
        if f item then Some item else find f seq

  let rec find_e f seq =
    match seq () with
    | Nil ->
        ok_none
    | Cons (item, seq) -> (
        f item >>? function true -> ok_some item | false -> find_e f seq )

  let rec find_s f seq =
    match seq () with
    | Nil ->
        Lwt.return_none
    | Cons (item, seq) -> (
        f item
        >>= function true -> Lwt.return_some item | false -> find_s f seq )

  let find_s f seq =
    match seq () with
    | Nil ->
        Lwt.return_none
    | Cons (item, seq) -> (
        Lwt.apply f item
        >>= function true -> Lwt.return_some item | false -> find_s f seq )

  let rec find_es f seq =
    match seq () with
    | Nil ->
        return_none
    | Cons (item, seq) -> (
        f item
        >>=? function true -> return_some item | false -> find_es f seq )

  let find_es f seq =
    match seq () with
    | Nil ->
        return_none
    | Cons (item, seq) -> (
        Lwt.apply f item
        >>=? function true -> return_some item | false -> find_es f seq )
end
