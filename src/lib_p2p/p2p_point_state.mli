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

open P2p_point

type 'conn t =
  | Requested of {cancel : Lwt_canceler.t}  (** We initiated a connection. *)
  | Accepted of {current_peer_id : P2p_peer.Id.t; cancel : Lwt_canceler.t}
      (** We accepted a incoming connection. *)
  | Running of {data : 'conn; current_peer_id : P2p_peer.Id.t}
      (** Successfully authenticated connection, normal business. *)
  | Disconnected  (** No connection established currently. *)

type 'conn state = 'conn t

val pp : Format.formatter -> 'conn t -> unit

module Info : sig
  type 'conn t

  (** Type of info associated to a point. *)
  type 'conn point_info = 'conn t

  val compare : 'conn point_info -> 'conn point_info -> int

  type reconnection_config = {
    factor : float;
    initial_delay : Time.System.Span.t;
    disconnection_delay : Time.System.Span.t;
    increase_cap : Time.System.Span.t;
  }

  val default_reconnection_config : reconnection_config

  val reconnection_config_encoding : reconnection_config Data_encoding.encoding

  (** [create ~trusted addr port] is a freshly minted point_info. If
      [trusted] is true, this point is considered trusted and will
      be treated as such. *)
  val create : ?trusted:bool -> P2p_addr.t -> P2p_addr.port -> 'conn point_info

  (** [trusted pi] is [true] iff [pi] has is trusted,
      i.e. "whitelisted". *)
  val trusted : 'conn point_info -> bool

  (** Points can announce themselves as  either public or private.
      Private points will not be advertised to other nodes. *)
  val known_public : 'conn point_info -> bool

  val set_trusted : 'conn point_info -> unit

  val unset_trusted : 'conn point_info -> unit

  val last_failed_connection : 'conn point_info -> Time.System.t option

  val last_rejected_connection :
    'conn point_info -> (P2p_peer.Id.t * Time.System.t) option

  val last_established_connection :
    'conn point_info -> (P2p_peer.Id.t * Time.System.t) option

  val last_disconnection :
    'conn point_info -> (P2p_peer.Id.t * Time.System.t) option

  (** [last_seen pi] is the most recent of:

      * last established connection
      * last rejected connection
      * last disconnection
  *)
  val last_seen : 'conn point_info -> (P2p_peer.Id.t * Time.System.t) option

  (** [last_miss pi] is the most recent of:

      * last failed connection
      * last rejected connection
      * last disconnection
  *)
  val last_miss : 'conn point_info -> Time.System.t option

  (* [reset_reconnection_delay] Reset the reconnection_delay for this point
     practically allowing the node to try the connection immediately *)
  val reset_reconnection_delay : 'conn point_info -> unit

  (* [can_reconnect] Check if a point is greylisted w.r.t. the current time *)
  val can_reconnect : now:Time.System.t -> 'conn point_info -> bool

  (* [reconnection_time] Return the time at which the node can try to 
     reconnect with this point, Or None if the point is already in state 
     running or can be recontacted immediately *)
  val reconnection_time : 'conn point_info -> Time.System.t option

  val point : 'conn point_info -> Id.t

  val log_incoming_rejection :
    timestamp:Time.System.t -> 'conn point_info -> P2p_peer.Id.t -> unit

  val fold : 'conn t -> init:'a -> f:('a -> Pool_event.t -> 'a) -> 'a

  val watch : 'conn t -> Pool_event.t Lwt_stream.t * Lwt_watcher.stopper
end

val get : 'conn Info.t -> 'conn t

val is_disconnected : 'conn Info.t -> bool

val set_requested :
  timestamp:Time.System.t -> 'conn Info.t -> Lwt_canceler.t -> unit

val set_accepted :
  timestamp:Time.System.t ->
  'conn Info.t ->
  P2p_peer.Id.t ->
  Lwt_canceler.t ->
  unit

val set_running :
  timestamp:Time.System.t -> 'conn Info.t -> P2p_peer.Id.t -> 'conn -> unit

val set_private : 'conn Info.t -> bool -> unit

(* [set_disconnected] Change the state of a peer upon disconnection and
   set the reconnection delay accordingly *)
val set_disconnected :
  timestamp:Time.System.t ->
  ?requested:bool ->
  Info.reconnection_config ->
  'conn Info.t ->
  unit
