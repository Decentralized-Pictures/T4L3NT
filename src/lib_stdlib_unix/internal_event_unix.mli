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

(** Configure the event-logging framework for UNIx-based applications. *)

(** The JSON-file-friendly definition of the configuration of the
    internal-events framework. It allows one to activate registered
    event sinks.  *)

open Error_monad

module Configuration : sig
  type t

  (** The default configuration is empty (it doesn't activate any sink). *)
  val default : t

  (** The serialization format. *)
  val encoding : t RPC_encoding.t

  (** Parse a json file at [path] into a configuration. *)
  val of_file : string -> t tzresult Lwt.t

  (** Run {!Tezos_base.Internal_event.All_sinks.activate} for every
      URI in the configuration. *)
  val apply : t -> unit tzresult Lwt.t
end

(** Initialize the internal-event sinks by looking at the
    [?configuration] argument and then at the (whitespace separated) list
    of URIs in the ["TEZOS_EVENTS_CONFIG"] environment variable, if an URI
    does not have a scheme it is expected to be a path to a configuration
    JSON file (cf. {!Configuration.of_file}), e.g.:
    [export TEZOS_EVENTS_CONFIG="unix-files:///tmp/events-unix debug://"], or
    [export TEZOS_EVENTS_CONFIG="debug://  /path/to/config.json"].

    The function also initializes the {!Lwt_log_sink_unix} module
    (corresponding to the ["TEZOS_LOG"] environment variable).
*)
val init :
  ?lwt_log_sink:Lwt_log_sink_unix.cfg ->
  ?configuration:Configuration.t ->
  unit ->
  unit Lwt.t

(** Call [close] on all the sinks. *)
val close : unit -> unit Lwt.t
