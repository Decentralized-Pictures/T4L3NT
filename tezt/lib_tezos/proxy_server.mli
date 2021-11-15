(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(** A proxy server instance *)
type t

(** Get the RPC port of a proxy server. It's the port to
    do request to. *)
val rpc_port : t -> int

(** Get the runner associated to a proxy server.

    Return [None] if the proxy server runs on the local machine. *)
val runner : t -> Runner.t option

(** [init ?runner ?name ?rpc_port node] creates and starts a proxy server
    that serves the given port and delegates its queries to [node].

    [event_level] specifies the verbosity of the file descriptor sink.
    Possible values are: ["debug"], ["info"], ["notice"], ["warning"], ["error"],
    and ["fatal"]. *)
val init :
  ?runner:Runner.t ->
  ?name:string ->
  ?rpc_port:int ->
  ?event_level:string ->
  Node.t ->
  t Lwt.t

(** Raw events. *)
type event = {name : string; value : JSON.t}

(** Add a callback to be called whenever the proxy_server emits an event.

    This callback is never removed.

    You can have multiple [on_event] handlers, although
    the order in which they trigger is unspecified. *)
val on_event : t -> (event -> unit) -> unit
