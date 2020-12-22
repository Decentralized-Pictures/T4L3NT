(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs, <contact@nomadic-labs.com>               *)
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
      ~pp2:pp_print_error_first
      ("peer", P2p_peer.Id.encoding)
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
      ~pp2:pp_print_error_first
      ("point", P2p_point.Id.encoding)
      ("trace", Error_monad.trace_encoding)

  let swap_failed =
    declare_2
      ~section
      ~name:"swap_failed"
      ~msg:"swap to {point} failed: {trace}"
      ~level:Info
      ~pp2:pp_print_error_first
      ("point", P2p_point.Id.encoding)
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
      ~pp2:P2p_connection.Id.pp
      ("peer", P2p_peer.Id.encoding)
      ("point", P2p_connection.Id.encoding)

  let peer_rejected =
    declare_0
      ~section
      ~name:"peer_rejected"
      ~msg:"[private node] incoming connection from untrusted peer rejected"
      ~level:Notice
      ()

  let authenticate =
    declare_3
      ~section
      ~name:"authenticate"
      ~msg:"authenticate: {point} {type} -> {state}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("type", Data_encoding.(option string))
      ("state", Data_encoding.(option string))

  let authenticate_status =
    declare_3
      ~section
      ~name:"authenticate_status"
      ~msg:"authenticate: {point} {type} -> {peer}"
      ~level:Debug
      ("type", Data_encoding.string)
      ("point", P2p_point.Id.encoding)
      ("peer", P2p_peer.Id.encoding)

  let authenticate_error =
    declare_2
      ~section
      ~name:"authentication_error"
      ~msg:"authenticate: {point} {errors}"
      ~level:Debug
      ~pp2:pp_print_error_first
      ("point", P2p_point.Id.encoding)
      ("errors", Error_monad.trace_encoding)

  let connection_rejected_by_peers =
    declare_4
      ~section
      ~name:"connection_rejected_by_peers"
      ~msg:
        "connection to {point} rejected by peer {peer}. Reason {reason}. Peer \
         list received: {points}"
      ~level:Debug
      ~pp2:P2p_peer.Id.pp_short
      ~pp3:P2p_rejection.pp_short
      ("point", P2p_point.Id.encoding)
      ("peer", P2p_peer.Id.encoding)
      ("reason", P2p_rejection.encoding)
      ("points", Data_encoding.list P2p_point.Id.encoding)

  let connection_error =
    declare_2
      ~section
      ~name:"connection_error"
      ~msg:"connection to {point} rejected by peer : {errors}"
      ~level:Debug
      ~pp2:pp_print_error_first
      ("point", P2p_point.Id.encoding)
      ("errors", Error_monad.trace_encoding)

  let connect_status =
    declare_2
      ~section
      ~name:"connect_status"
      ~msg:"connect: {point} {state}"
      ~level:Debug
      ("state", Data_encoding.string)
      ("point", P2p_point.Id.encoding)

  let connect_error =
    declare_3
      ~section
      ~name:"connect_error"
      ~msg:"connect: {point} {state} : {errors}"
      ~level:Debug
      ~pp3:pp_print_error_first
      ("state", Data_encoding.string)
      ("point", P2p_point.Id.encoding)
      ("errors", Error_monad.trace_encoding)

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
      ("local_db_versions", Data_encoding.list Distributed_db_version.encoding)
      ("remote_db_version", Distributed_db_version.encoding)
      ("local_p2p_version", Data_encoding.list P2p_version.encoding)
      ("remote_p2p_version", P2p_version.encoding)
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
      ~pp1:pp_print_error_first
      ("errors", Error_monad.trace_encoding)

  let bytes_popped_from_queue =
    declare_2
      ~section
      ~name:"bytes_popped_from_queue"
      ~msg:"{bytes} bytes message popped from queue {peer}"
      ~level:Debug
      ("bytes", Data_encoding.int8)
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
      ~level:Debug
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
      ~pp1:pp_print_error_first
      ("error", Error_monad.trace_encoding)
      ("type", Data_encoding.string)

  let unexpected_error =
    declare_1
      ~section
      ~name:"unexpected_error_welcome"
      ~msg:"unexpected error"
      ~level:Error
      ~pp1:pp_print_error_first
      ("error", Error_monad.trace_encoding)

  let incoming_connection_error =
    declare_1
      ~section
      ~name:"incoming_connection_error"
      ~msg:"cannot accept incoming connections"
      ~level:Error
      ("exception", Error_monad.error_encoding)
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
        "unexpected error in connection ({direction}: \
         {connection_id},{name}): {error}"
      ~level:Error
      ~pp4:pp_print_error_first
      ("direction", Data_encoding.string)
      ("connection_id", Data_encoding.int31)
      ("name", Data_encoding.string)
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
      ~level:Debug
      ("name", Data_encoding.string)

  let shutdown_scheduler =
    declare_0
      ~section
      ~name:"shutdown_scheduler"
      ~msg:"shutdown scheduler"
      ~level:Debug
      ()
end
