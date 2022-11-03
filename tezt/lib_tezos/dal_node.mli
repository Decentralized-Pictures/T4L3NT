(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

(** Spawn Data-availability-layer (DAL) nodes and control them *)

(** DAL Node state *)
type t

(** Creates a DAL node *)

val create :
  ?path:string ->
  ?name:string ->
  ?color:Log.Color.t ->
  ?data_dir:string ->
  ?event_pipe:string ->
  ?rpc_host:string ->
  ?rpc_port:int ->
  node:Node.t ->
  unit ->
  t

(** Get the name of an dal node. *)
val name : t -> string

(** Get the RPC host given as [--rpc-addr] to an dal node. *)
val rpc_host : t -> string

(** Get the RPC port given as [--rpc-addr] to an dal node. *)
val rpc_port : t -> int

(** Return the endpoint of the dal node, i.e., http://rpc_host:rpc_port. *)
val endpoint : t -> string

(** Get the data-dir of an dal node. *)
val data_dir : t -> string

(** [run ?wait_ready ?env node] launches the given dal node where env is a map
    of environment variable.

    If [wait_ready] is [true], the promise waits for the dal node to be ready.
    [true] by default *)
val run : ?wait_ready:bool -> ?env:string String_map.t -> t -> unit Lwt.t

(** Send SIGTERM to a sc node and wait for it to terminate. With [kill] set, a
    SIGKILL is sent instead of a SIGTERM. *)
val terminate : ?kill:bool -> t -> unit Lwt.t

(** Shows in stdout every events sent by the node *)
val log_events : t -> unit

(** See [Daemon.Make.wait_for]. *)
val wait_for : ?where:string -> t -> string -> (JSON.t -> 'a option) -> 'a Lwt.t

(** [is_running_not_ready dal_node] returns true if the given node is
    running but its status is not ready *)
val is_running_not_ready : t -> bool

(** Wait until a node terminates and return its status. If the node is not
    running, make the test fail. *)
val wait : t -> Unix.process_status Lwt.t

(** Run [octez-dal-node init-config]. Returns the name of the resulting
    configuration file.

    If [use_unsafe_srs] is [true], the dal node runs with unsafe computed SRS
    allowing tests to run faster, without the need of large file. Default is
    [true] in tezt.
*)

val init_config : ?use_unsafe_srs:bool -> t -> string Lwt.t
