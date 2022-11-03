(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020-2022 Nomadic Labs, <contact@nomadic-labs.com>          *)
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

let pp_first_element elem_enc ppf l =
  let open Format in
  pp_print_string ppf "[ " ;
  (match l with
  | [] -> ()
  | [element] -> elem_enc ppf element
  | element :: _ ->
      elem_enc ppf element ;
      pp_print_string ppf "; ...") ;
  pp_print_string ppf " ]"

module P2p_protocol = struct
  include Internal_event.Simple

  let section = ["p2p"; "protocol"]

  let private_node_new_peers =
    declare_1
      ~section
      ~name:"private_node_new_peers"
      ~msg:"received new peers addresses from private peer {peer}"
      ~level:Warning
      ("peer", P2p_peer.Id.encoding)

  let private_node_peers_request =
    declare_1
      ~section
      ~name:"private_node_peers_request"
      ~msg:"received requests for peers addresses from private peer {peer}"
      ~level:Warning
      ("peer", P2p_peer.Id.encoding)

  let private_node_swap_request =
    declare_1
      ~section
      ~name:"private_node_swap_request"
      ~msg:"received swap requests from private peer {peer}"
      ~level:Warning
      ("peer", P2p_peer.Id.encoding)

  let private_node_swap_ack =
    declare_1
      ~section
      ~name:"private_node_swap_ack"
      ~msg:"received swap ack from private peer {peer}"
      ~level:Warning
      ("peer", P2p_peer.Id.encoding)

  let private_node_request =
    declare_1
      ~section
      ~name:"private_node_request"
      ~msg:"private peer ({peer}) asked other peer's addresses"
      ~level:Warning
      ("peer", P2p_peer.Id.encoding)

  let advertise_sending_failed =
    declare_2
      ~section
      ~name:"advertise_sending_failed"
      ~msg:"sending advertise to {peer} failed: {trace}"
      ~level:Warning
      ("peer", P2p_peer.Id.encoding)
      ~pp2:pp_print_top_error_of_trace
      ("trace", Error_monad.trace_encoding)

  let swap_succeeded =
    declare_1
      ~section
      ~name:"swap_succeeded"
      ~msg:"swap to {point} succeeded"
      ~level:Info
      ("point", P2p_point.Id.encoding)

  let swap_interrupted =
    declare_2
      ~section
      ~name:"swap_interrupted"
      ~msg:"swap to {point} was interrupted: {trace}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ~pp2:pp_print_top_error_of_trace
      ("trace", Error_monad.trace_encoding)

  let swap_failed =
    declare_2
      ~section
      ~name:"swap_failed"
      ~msg:"swap to {point} failed: {trace}"
      ~level:Info
      ("point", P2p_point.Id.encoding)
      ~pp2:pp_print_top_error_of_trace
      ("trace", Error_monad.trace_encoding)

  let swap_ack_received =
    declare_1
      ~section
      ~name:"swap_ack_received"
      ~msg:"swap ack received from {peer}"
      ~level:Info
      ("peer", P2p_peer.Id.encoding)

  let swap_request_received =
    declare_1
      ~section
      ~name:"swap_request_received"
      ~msg:"swap request received from {peer}"
      ~level:Info
      ("peer", P2p_peer.Id.encoding)

  let swap_request_ignored =
    declare_1
      ~section
      ~name:"swap_request_ignored"
      ~msg:"swap request ignored from {peer}"
      ~level:Info
      ("peer", P2p_peer.Id.encoding)

  let no_swap_candidate =
    declare_1
      ~section
      ~name:"no_swap_candidate"
      ~msg:"no swap candidate for {peer}"
      ~level:Info
      ("peer", P2p_peer.Id.encoding)
end

module P2p_connect_handler = struct
  include Internal_event.Simple

  let section = ["p2p"; "connect_handler"]

  let disconnected =
    declare_2
      ~section
      ~name:"disconnected"
      ~msg:"disconnected: {peer} ({point})"
      ~level:Debug
      ("peer", P2p_peer.Id.encoding)
      ~pp2:P2p_connection.Id.pp
      ("point", P2p_connection.Id.encoding)

  let peer_rejected =
    declare_0
      ~section
      ~name:"peer_rejected"
      ~msg:"[private node] incoming connection from untrusted peer rejected"
      ~level:Notice
      ()

  let authenticate_start =
    declare_2
      ~section
      ~name:"authenticate_start"
      ~msg:"start authentication for point {point} ({direction})"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("direction", Data_encoding.string)

  let authenticate =
    declare_3
      ~section
      ~name:"authenticate"
      ~msg:"authentication for point {point}. direction:{direction} -> {state}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("direction", Data_encoding.string)
      ("state", Data_encoding.string)

  let authenticate_status =
    declare_3
      ~section
      ~name:"authenticate_status"
      ~msg:"authentication status for point {point} {type} -> {peer}"
      ~level:Debug
      ("type", Data_encoding.string)
      ("point", P2p_point.Id.encoding)
      ("peer", P2p_peer.Id.encoding)

  let authenticate_status_peer_id_correct =
    declare_2
      ~section
      ~name:"authenticate_status_peer_id_correct"
      ~msg:"expected peer id {peer} for this point {point}"
      ~level:Notice
      ("point", P2p_point.Id.encoding)
      ("peer", P2p_peer.Id.encoding)

  let authenticate_status_peer_id_incorrect =
    declare_4
      ~section
      ~name:"authenticate_status_peer_id_incorrect"
      ~msg:
        "authenticate failed: {point} {type}. Expected '{expected_peer_id}', \
         got '{peer_id}'"
      ~level:Warning
      ("type", Data_encoding.string)
      ("point", P2p_point.Id.encoding)
      ("expected_peer_id", P2p_peer.Id.encoding)
      ("peer_id", P2p_peer.Id.encoding)

  let authenticate_error =
    declare_2
      ~section
      ~name:"authentication_error"
      ~msg:"authentication error for {point}: {errors}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ~pp2:pp_print_top_error_of_trace
      ("errors", Error_monad.trace_encoding)

  let connection_rejected_by_peers =
    declare_4
      ~section
      ~name:"connection_rejected_by_peers"
      ~msg:
        "connection to {point} rejected by peer {peer}. Reason {reason}. Peer \
         list received: {points}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ~pp2:P2p_peer.Id.pp_short
      ("peer", P2p_peer.Id.encoding)
      ~pp3:P2p_rejection.pp_short
      ("reason", P2p_rejection.encoding)
      ~pp4:(pp_first_element P2p_point.Id.pp)
      ("points", Data_encoding.list P2p_point.Id.encoding)

  let connection_error =
    declare_2
      ~section
      ~name:"connection_error"
      ~msg:"connection to {point} rejected by peer : {errors}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ~pp2:pp_print_top_error_of_trace
      ("errors", Error_monad.trace_encoding)

  let connect_status =
    declare_2
      ~section
      ~name:"connect_status"
      ~msg:"connection status for {point}: {state}"
      ~level:Debug
      ("state", Data_encoding.string)
      ("point", P2p_point.Id.encoding)

  let connect_error =
    declare_2
      ~section
      ~name:"connect_error"
      ~msg:"connection error for point {point}, disconnecting : {errors}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("errors", Data_encoding.(conv Lazy.force Lazy.from_val string))

  let connect_close_error =
    declare_2
      ~section
      ~name:"connect_close_error"
      ~msg:"connection error while closing for point {point}: {errors}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("errors", Data_encoding.(conv Lazy.force Lazy.from_val string))

  let authenticate_reject_protocol_mismatch =
    declare_8
      ~section
      ~name:"authenticate_reject_protocol_mismatch"
      ~msg:"no common protocol with {peer}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("peer", P2p_peer.Id.encoding)
      ("local_chain", Distributed_db_version.Name.encoding)
      ("remote_chain", Distributed_db_version.Name.encoding)
      ~pp5:(pp_first_element Distributed_db_version.pp)
      ("local_db_versions", Data_encoding.list Distributed_db_version.encoding)
      ("remote_db_version", Distributed_db_version.encoding)
      ~pp7:(pp_first_element P2p_version.pp)
      ("local_p2p_version", Data_encoding.list P2p_version.encoding)
      ("remote_p2p_version", P2p_version.encoding)

  let new_connection =
    declare_3
      ~section
      ~name:"new_connection"
      ~msg:"new connection to {addr}:{port}#{peer}"
      ~level:Info
      ("addr", P2p_addr.encoding)
      ("port", Data_encoding.option Data_encoding.int16)
      ("peer", P2p_peer.Id.encoding)

  let trigger_maintenance_too_many_connections =
    declare_2
      ~section
      ~name:"trigger_maintenance_too_many_connections"
      ~msg:
        "Too many connections : trigger maintenance \
         (active_connections={active_connections} / \
         max_connections={max_connections})"
      ~level:Debug
      ("active_connections", Data_encoding.int16)
      ("max_connections", Data_encoding.int16)

  let trigger_maintenance_too_few_connections =
    declare_2
      ~section
      ~name:"trigger_maintenance_too_few_connections"
      ~msg:
        "Too few connections : trigger maintenance \
         (active_connections={active_connections} / \
         min_connections={min_connections})"
      ~level:Debug
      ("active_connections", Data_encoding.int16)
      ("min_connections", Data_encoding.int16)
end

module P2p_conn = struct
  include Internal_event.Simple

  let section = ["p2p"; "conn"]

  let unexpected_error =
    declare_1
      ~section
      ~name:"unexpected_error_answerer"
      ~msg:"answerer unexpected error: {errors}"
      ~level:Error
      ~pp1:pp_print_top_error_of_trace
      ("errors", Error_monad.trace_encoding)

  let bytes_popped_from_queue =
    declare_2
      ~section
      ~name:"bytes_popped_from_queue"
      ~msg:"{bytes} bytes message popped from queue {peer}"
      ~level:Debug
      ("bytes", Data_encoding.int31)
      ("peer", P2p_peer.Id.encoding)
end

module P2p_fd = struct
  include Internal_event.Simple

  let section = ["p2p"; "fd"]

  let create_fd =
    declare_1
      ~section
      ~name:"create_fd"
      ~msg:"cnx:{connection_id}:create fd"
      ~level:Debug
      ("connection_id", Data_encoding.int31)

  let close_fd =
    declare_3
      ~section
      ~name:"close_fd"
      ~msg:"cnx:{connection_id}:close fd (stats : {nread}/{nwrit})"
      ~level:Debug
      ("connection_id", Data_encoding.int31)
      ("nread", Data_encoding.int31)
      ("nwrit", Data_encoding.int31)

  let try_read =
    declare_2
      ~section
      ~name:"try_read"
      ~msg:"cnx:{connection_id}:try read {length}"
      ~level:Debug
      ("connection_id", Data_encoding.int31)
      ("length", Data_encoding.int31)

  let try_write =
    declare_2
      ~section
      ~name:"try_write"
      ~msg:"cnx:{connection_id}:try write {length}"
      ~level:Debug
      ("connection_id", Data_encoding.int31)
      ("length", Data_encoding.int31)

  let read_fd =
    declare_3
      ~section
      ~name:"read_fd"
      ~msg:"cnx:{connection_id}:read {nread} ({nread_total})"
      ~level:Debug
      ("connection_id", Data_encoding.int31)
      ("nread", Data_encoding.int31)
      ("nread_total", Data_encoding.int31)

  let written_fd =
    declare_3
      ~section
      ~name:"written_fd"
      ~msg:"cnx:{connection_id}:written {nwrit} ({nwrit_total})"
      ~level:Debug
      ("connection_id", Data_encoding.int31)
      ("nwrit", Data_encoding.int31)
      ("nwrit_total", Data_encoding.int31)

  let connect_fd =
    declare_2
      ~section
      ~name:"connect"
      ~msg:"cnx:{connection_id}:connect {socket}"
      ~level:Debug
      ("connection_id", Data_encoding.int31)
      ("socket", Data_encoding.string)

  let accept_fd =
    declare_2
      ~section
      ~name:"accept"
      ~msg:"cnx:{connection_id}:accept {socket}"
      ~level:Debug
      ("connection_id", Data_encoding.int31)
      ("socket", Data_encoding.string)
end

module P2p_maintainance = struct
  include Internal_event.Simple

  let section = ["p2p"; "maintenance"]

  let maintenance_ended =
    declare_0
      ~section
      ~name:"maintenance_ended"
      ~msg:"maintenance step ended"
      ~level:Info
      ()

  let too_few_connections =
    declare_1
      ~section
      ~name:"too_few_connections_maintenance"
      ~msg:"too few connections ({connections})"
      ~level:Notice
      ("connections", Data_encoding.int31)

  let too_many_connections =
    declare_1
      ~section
      ~name:"too_many_connections_maintenance"
      ~msg:"too many connections (will kill {connections})"
      ~level:Debug
      ("connections", Data_encoding.int31)
end

module P2p_welcome = struct
  include Internal_event.Simple

  let section = ["p2p"; "welcome"]

  let incoming_error =
    declare_2
      ~section
      ~name:"incoming_error"
      ~msg:"incoming connection failed with {error}. Ignoring"
      ~level:Debug
      ~pp1:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)
      ("type", Data_encoding.string)

  let unexpected_error =
    declare_1
      ~section
      ~name:"unexpected_error_welcome"
      ~msg:"unexpected error: {error}"
      ~level:Error
      ~pp1:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)

  let unexpected_error_closing_socket =
    declare_1
      ~section
      ~name:"unexpected_error_closing_socket"
      ~msg:"unexpected error while closing socket: {error}"
      ~level:Error
      ~pp1:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)

  let incoming_connection_error =
    declare_1
      ~section
      ~name:"incoming_connection_error"
      ~msg:"cannot accept incoming connections"
      ~level:Error
      ("exception", Error_monad.error_encoding)
end

module P2p_socket = struct
  include Internal_event.Simple

  let section = ["p2p"; "socket"]

  let nack_point_with_list =
    declare_2
      ~section
      ~name:"nack_point_with_list"
      ~msg:"nack point {point} with point list {points}"
      ~level:Debug
      ("point", P2p_connection.Id.encoding)
      ~pp2:(pp_first_element P2p_point.Id.pp)
      ("points", Data_encoding.list P2p_point.Id.encoding)

  let nack_point_no_point =
    declare_1
      ~section
      ~name:"nack_point_no_point"
      ~msg:"nack point {point} (no point list due to p2p version)"
      ~level:Debug
      ("point", P2p_connection.Id.encoding)

  let sending_authentication =
    declare_1
      ~section
      ~name:"sending_authentication"
      ~msg:"sending authentication to {point}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)

  let connection_closed =
    declare_1
      ~section
      ~name:"connection_closed"
      ~msg:"connection closed to {peer}"
      ~level:Debug
      ("peer", P2p_peer.Id.encoding)

  let read_event =
    declare_2
      ~section
      ~name:"socket_read"
      ~level:Debug
      ~msg:"reading {bytes} bytes from {peer}"
      ("bytes", Data_encoding.int31)
      ("peer", P2p_peer.Id.encoding)

  let read_error =
    declare_0
      ~section
      ~name:"socket_read_error"
      ~level:Debug
      ~msg:"[read message] incremental decoding error"
      ()

  let write_event =
    declare_2
      ~section
      ~name:"socket_write"
      ~level:Debug
      ~msg:"writing {bytes} to {peer}"
      ("bytes", Data_encoding.int31)
      ("peer", P2p_peer.Id.encoding)

  let write_error =
    declare_2
      ~section
      ~name:"socket_write_error"
      ~level:Error
      ~msg:"unexpected error when writing to {peer}: {error}"
      ~pp1:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)
      ("peer", P2p_peer.Id.encoding)
end

module P2p_io_scheduler = struct
  include Internal_event.Simple

  let section = ["p2p"; "io-scheduler"]

  let connection_closed =
    declare_3
      ~section
      ~name:"connection_closed_scheduler"
      ~msg:"connection closed {direction} ({connection_id},{name})"
      ~level:Debug
      ("direction", Data_encoding.string)
      ("connection_id", Data_encoding.int31)
      ("name", Data_encoding.string)

  let unexpected_error =
    declare_4
      ~section
      ~name:"unexpected_error_scheduler"
      ~msg:
        "unexpected error in connection ({direction}: {connection_id},{name}): \
         {error}"
      ~level:Error
      ("direction", Data_encoding.string)
      ("connection_id", Data_encoding.int31)
      ("name", Data_encoding.string)
      ~pp4:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)

  let wait_quota =
    declare_1
      ~section
      ~name:"scheduler_wait_quota"
      ~msg:"wait_quota ({name})"
      ~level:Debug
      ("name", Data_encoding.string)

  let wait =
    declare_1
      ~section
      ~name:"scheduler_wait"
      ~msg:"wait ({name})"
      ~level:Debug
      ("name", Data_encoding.string)

  let handle_connection =
    declare_3
      ~section
      ~name:"handle_connection"
      ~msg:"handle {len} ({connection_id},{name})"
      ~level:Debug
      ("len", Data_encoding.int31)
      ("connection_id", Data_encoding.int31)
      ("name", Data_encoding.string)

  let create_connection =
    declare_2
      ~section
      ~name:"create_connection_scheduler"
      ~msg:"create connection ({connection_id},{name})"
      ~level:Debug
      ("connection_id", Data_encoding.int31)
      ("name", Data_encoding.string)

  let update_quota =
    declare_1
      ~section
      ~name:"update_quota"
      ~msg:"update quota {name}"
      ~level:Debug
      ("name", Data_encoding.string)

  let reset_quota =
    declare_0 ~section ~name:"reset_quota" ~msg:"reset quota" ~level:Debug ()

  let create =
    declare_0 ~section ~name:"create_connection" ~msg:"create" ~level:Debug ()

  let register =
    declare_1
      ~section
      ~name:"register_connection"
      ~msg:"register_connection {connection_id}"
      ~level:Debug
      ("connection_id", Data_encoding.int31)

  let close_error =
    declare_2
      ~section
      ~name:"close_connection_error"
      ~msg:"close {connection_id} failed with {error}"
      ~level:Warning
      ("connection_id", Data_encoding.int31)
      ("error", Error_monad.error_encoding)

  let close =
    declare_1
      ~section
      ~name:"close_connection"
      ~msg:"close {connection_id}"
      ~level:Debug
      ("connection_id", Data_encoding.int31)

  let shutdown =
    declare_1
      ~section
      ~name:"shutdown_connection"
      ~msg:"shutdown {name}"
      ~level:Info
      ("name", Data_encoding.string)

  let shutdown_scheduler =
    declare_0
      ~section
      ~name:"shutdown_io_scheduler"
      ~msg:"shutdown scheduler"
      ~level:Info
      ()
end

module P2p_pool = struct
  include Internal_event.Simple

  let section = ["p2p"; "pool"]

  let get_points =
    declare_3
      ~section
      ~name:"get_points"
      ~msg:"getting points from {medium} of {source}: {point_list}"
      ~level:Debug
      ("medium", Data_encoding.string)
      ("source", P2p_peer.Id.encoding)
      ~pp3:(pp_first_element P2p_point.Id.pp)
      ("point_list", Data_encoding.list P2p_point.Id.encoding)

  let create_pool =
    declare_1
      ~section
      ~name:"create_pool"
      ~msg:"create pool: known points {point_list}"
      ~level:Debug
      ~pp1:(pp_first_element P2p_point.Id.pp)
      ("point_list", Data_encoding.list P2p_point.Id.encoding)

  let parse_error =
    declare_1
      ~section
      ~name:"parse_error_peers"
      ~msg:"failed to parse peers file: {error}"
      ~level:Error
      ~pp1:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)

  let saving_metadata =
    declare_1
      ~section
      ~name:"save_metadata"
      ~msg:"saving metadata in {file}"
      ~level:Info
      ("file", Data_encoding.string)

  let save_peers_error =
    declare_1
      ~section
      ~name:"save_error_peers"
      ~msg:"failed to save peers file: {error}"
      ~level:Error
      ~pp1:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)
end

module Discovery = struct
  include Internal_event.Simple

  let section = ["p2p"; "discovery"]

  let create_socket_error =
    declare_0
      ~section
      ~name:"create_socket_error"
      ~msg:"error creating a socket"
      ~level:Debug
      ()

  let message_received =
    declare_0
      ~section
      ~name:"message_received"
      ~msg:"received discovery message"
      ~level:Debug
      ()

  let parse_error =
    declare_1
      ~section
      ~name:"parse_error"
      ~msg:"failed to parse ({address})"
      ~level:Debug
      ("address", Data_encoding.string)

  let register_new =
    declare_1
      ~section
      ~name:"register_new"
      ~msg:"registering new point {point}"
      ~level:Notice
      ("point", P2p_point.Id.encoding)

  let unexpected_error =
    declare_2
      ~section
      ~name:"unexpected_error"
      ~msg:"unexpected error in {worker} worker: {error}"
      ~level:Error
      ("worker", Data_encoding.string)
      ~pp2:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)

  let unexpected_exit =
    declare_0
      ~section
      ~name:"unexpected_exit"
      ~msg:"Answer worker exited unexpectedly"
      ~level:Error
      ()

  let broadcast_message =
    declare_0
      ~section
      ~name:"broadcast_message"
      ~msg:"Broadcasting discovery message"
      ~level:Debug
      ()

  let broadcast_error =
    declare_0
      ~section
      ~name:"broadcast_error"
      ~msg:"Error broadcasting a discovery request"
      ~level:Debug
      ()
end

module P2p = struct
  include Internal_event.Simple

  let section = ["p2p"]

  let activate_layer =
    declare_0
      ~section
      ~name:"activate_layer"
      ~level:Info
      ~msg:"activate P2P layer"
      ()

  let activate_network =
    declare_0 ~section ~name:"activate_network" ~level:Info ~msg:"activate" ()

  let message_read =
    declare_1
      ~section
      ~name:"message_read"
      ~level:Debug
      ~msg:"message read from {peer}"
      ("peer", P2p_peer.Id.encoding)

  let message_read_error =
    declare_1
      ~section
      ~name:"message_read_error"
      ~level:Debug
      ~msg:"error reading message from {peer}"
      ("peer", P2p_peer.Id.encoding)

  let shutdown_welcome_worker =
    declare_0
      ~section
      ~name:"shutdown_welcome_worker"
      ~level:Notice
      ~msg:"shutting down the p2p's welcome worker..."
      ()

  let shutdown_maintenance_worker =
    declare_0
      ~section
      ~name:"shutdown_maintenance_worker"
      ~level:Notice
      ~msg:"shutting down the p2p's network maintenance worker..."
      ()

  let shutdown_connection_pool =
    declare_0
      ~section
      ~name:"shutdown_connection_pool"
      ~level:Notice
      ~msg:"shutting down the p2p connection pool..."
      ()

  let shutdown_connection_handler =
    declare_0
      ~section
      ~name:"shutdown_connection_handler"
      ~level:Notice
      ~msg:"shutting down the p2p connection handler..."
      ()

  let shutdown_scheduler =
    declare_0
      ~section
      ~name:"shutdown_scheduler"
      ~level:Notice
      ~msg:"shutting down the p2p scheduler..."
      ()

  let message_sent =
    declare_1
      ~section
      ~name:"message_to_send"
      ~level:Debug
      ~msg:"message sent to {peer}"
      ("peer", P2p_peer.Id.encoding)

  let sending_message_error =
    declare_2
      ~section
      ~name:"sending_message_error"
      ~level:Debug
      ~msg:"error sending message to {peer}: {error}"
      ("peer", P2p_peer.Id.encoding)
      ~pp2:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)

  let message_trysent =
    declare_1
      ~section
      ~name:"message_trysent"
      ~level:Debug
      ~msg:"message trysent to {peer}"
      ("peer", P2p_peer.Id.encoding)

  let trysending_message_error =
    declare_2
      ~section
      ~name:"trysending_message_error"
      ~level:Debug
      ~msg:"error trysending message to {peer}: {error}"
      ("peer", P2p_peer.Id.encoding)
      ~pp2:pp_print_top_error_of_trace
      ("error", Error_monad.trace_encoding)

  let broadcast =
    declare_0
      ~section
      ~name:"broadcast"
      ~level:Debug
      ~msg:"message broadcast"
      ()
end
