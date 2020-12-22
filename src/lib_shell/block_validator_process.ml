(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018 Nomadic Labs. <contact@nomadic-labs.com>               *)
(* Copyright (c) 2020 Metastate AG <hello@metastate.dev>                     *)
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

type validator_environment = {
  genesis : Genesis.t;
  user_activated_upgrades : User_activated.upgrades;
  user_activated_protocol_overrides : User_activated.protocol_overrides;
}

type validator_kind =
  | Internal : Context.index -> validator_kind
  | External : {
      data_dir : string;
      context_root : string;
      protocol_root : string;
      process_path : string;
      sandbox_parameters : Data_encoding.json option;
    }
      -> validator_kind

(* A common interface for the two type of validation *)
module type S = sig
  type t

  val close : t -> unit Lwt.t

  val restore_context_integrity : t -> int option tzresult Lwt.t

  val apply_block :
    t ->
    predecessor:State.Block.t ->
    max_operations_ttl:int ->
    Block_header.t ->
    Operation.t list list ->
    Block_validation.result tzresult Lwt.t

  val commit_genesis :
    t -> chain_id:Chain_id.t -> Context_hash.t tzresult Lwt.t

  (** [init_test_chain] must only be called on a forking block. *)
  val init_test_chain : t -> State.Block.t -> Block_header.t tzresult Lwt.t
end

(* We hide the validator (of type [S.t]) and the according module in a GADT.
   This way, we avoid one pattern matching. *)
type t =
  | E : {validator_process : (module S with type t = 'a); validator : 'a} -> t

(** The standard block validation method *)
module Internal_validator_process = struct
  module Events = struct
    open Internal_event.Simple

    let section = ["sequential_block_validator"]

    let init =
      declare_0
        ~section
        ~level:Notice
        ~name:"seq_initialized"
        ~msg:"initialized"
        ()

    let close =
      declare_0
        ~section
        ~level:Notice
        ~name:"seq_close"
        ~msg:"shutting down"
        ()

    let validation_request =
      declare_2
        ~section
        ~level:Debug
        ~name:"seq_validation_request"
        ~msg:"requesting validation of {block} for chain {chain}"
        ~pp1:Block_hash.pp
        ("block", Block_hash.encoding)
        ~pp2:Chain_id.pp
        ("chain", Chain_id.encoding)

    let validation_success =
      declare_2
        ~section
        ~level:Debug
        ~name:"seq_validation_success"
        ~msg:"block {block} successfully validated in {timespan}"
        ~pp1:Block_hash.pp
        ("block", Block_hash.encoding)
        ~pp2:Time.System.Span.pp_hum
        ("timespan", Time.System.Span.encoding)

    let emit = Internal_event.Simple.emit
  end

  type t = {
    context_index : Context.index;
    genesis : Genesis.t;
    user_activated_upgrades : User_activated.upgrades;
    user_activated_protocol_overrides : User_activated.protocol_overrides;
  }

  let init
      ({genesis; user_activated_upgrades; user_activated_protocol_overrides} :
        validator_environment) context_index =
    Events.(emit init ())
    >>= fun () ->
    return
      {
        context_index;
        genesis;
        user_activated_upgrades;
        user_activated_protocol_overrides;
      }

  let close _ = Events.(emit close ())

  let make_apply_environment
      { user_activated_upgrades;
        user_activated_protocol_overrides;
        context_index;
        _ } predecessor max_operations_ttl =
    let chain_state = State.Block.chain_state predecessor in
    let chain_id = State.Chain.id chain_state in
    let predecessor_block_header = State.Block.header predecessor in
    let context_hash = predecessor_block_header.shell.context in
    Context.checkout context_index context_hash
    >>= (function
          | None ->
              fail
                (Block_validator_errors.Failed_to_checkout_context context_hash)
          | Some ctx ->
              return ctx)
    >>=? fun predecessor_context ->
    State.Block.metadata_hash predecessor
    >>= fun predecessor_block_metadata_hash ->
    State.Block.all_operations_metadata_hash predecessor
    >>= fun predecessor_ops_metadata_hash ->
    return
      {
        Block_validation.max_operations_ttl;
        chain_id;
        predecessor_block_header;
        predecessor_block_metadata_hash;
        predecessor_ops_metadata_hash;
        predecessor_context;
        user_activated_upgrades;
        user_activated_protocol_overrides;
      }

  let apply_block validator ~predecessor ~max_operations_ttl block_header
      operations =
    make_apply_environment validator predecessor max_operations_ttl
    >>=? fun env ->
    let now = Systime_os.now () in
    let block_hash = Block_header.hash block_header in
    Events.(emit validation_request (block_hash, env.chain_id))
    >>= fun () ->
    Block_validation.apply env block_header operations
    >>=? fun result ->
    let timespan =
      let then_ = Systime_os.now () in
      Ptime.diff then_ now
    in
    Events.(emit validation_success (block_hash, timespan))
    >>= fun () -> return result

  let commit_genesis validator ~chain_id =
    Context.commit_genesis
      validator.context_index
      ~chain_id
      ~time:validator.genesis.time
      ~protocol:validator.genesis.protocol

  let init_test_chain _ forking_block =
    let forked_header = State.Block.header forking_block in
    State.Block.context forking_block
    >>=? fun context -> Block_validation.init_test_chain context forked_header

  let restore_context_integrity validator =
    Lwt.return (Context.restore_integrity validator.context_index)
end

(** Block validation using an external process *)
module External_validator_process = struct
  module Events = struct
    open Internal_event.Simple

    let section = ["external_block_validator"]

    let init =
      declare_0
        ~section
        ~level:Notice
        ~name:"proc_initialized"
        ~msg:"initialized"
        ()

    let close =
      declare_0
        ~section
        ~level:Notice
        ~name:"proc_close"
        ~msg:"shutting down"
        ()

    let process_exited_abnormally =
      let open Unix in
      let process_status_encoding =
        let open Data_encoding in
        union
          [ case
              (Tag 0)
              ~title:"wexited"
              int31
              (function WEXITED i -> Some i | _ -> None)
              (fun i -> WEXITED i);
            case
              (Tag 1)
              ~title:"wsignaled"
              int31
              (function WSIGNALED i -> Some i | _ -> None)
              (fun i -> WSIGNALED i);
            case
              (Tag 2)
              ~title:"wstopped"
              int31
              (function WSTOPPED i -> Some i | _ -> None)
              (fun i -> WSTOPPED i) ]
      in
      declare_1
        ~section
        ~level:Error
        ~name:"proc_status"
        ~msg:"{status_msg}"
        ~pp1:(fun fmt status ->
          match status with
          | WEXITED i ->
              Format.fprintf
                fmt
                "process terminated abnormally with exit code %i"
                i
          | WSIGNALED i ->
              Format.fprintf
                fmt
                "process was killed by signal %s"
                (Lwt_exit.signal_name i)
          | WSTOPPED i ->
              Format.fprintf
                fmt
                "process was stopped by signal %s"
                (Lwt_exit.signal_name i))
        ("status_msg", process_status_encoding)

    let process_exited_normally =
      declare_0
        ~section
        ~level:Notice
        ~name:"proc_exited_normally"
        ~msg:"process terminated normally"
        ()

    let validator_started =
      declare_1
        ~section
        ~level:Notice
        ~name:"proc_validator_started"
        ~msg:"block validator process started with pid {pid}"
        ~pp1:Format.pp_print_int
        ("pid", Data_encoding.int31)

    let request_for =
      declare_1
        ~section
        ~level:Debug
        ~name:"proc_request"
        ~msg:"request for {request}"
        ~pp1:External_validation.request_pp
        ("request", External_validation.request_encoding)

    let request_result =
      declare_2
        ~section
        ~level:Debug
        ~name:"proc_request_result"
        ~msg:"completion of {request_result} in {timespan}"
        ~pp1:External_validation.request_pp
        ("request_result", External_validation.request_encoding)
        ~pp2:Time.System.Span.pp_hum
        ("timespan", Time.System.Span.encoding)

    let emit = Internal_event.Simple.emit
  end

  type validator_process = {
    process : Lwt_process.process_none;
    stdin : Lwt_io.output_channel;
    stdout : Lwt_io.input_channel;
    canceler : Lwt_canceler.t;
  }

  type t = {
    data_dir : string;
    context_root : string;
    protocol_root : string;
    genesis : Genesis.t;
    user_activated_upgrades : User_activated.upgrades;
    user_activated_protocol_overrides : User_activated.protocol_overrides;
    process_path : string;
    mutable validator_process : validator_process option;
    lock : Lwt_mutex.t;
    sandbox_parameters : Data_encoding.json option;
  }

  (* Returns a temporary path for the socket to be
     spawned. $XDG_RUNTIME_DIR is returned if the environment variable
     is defined. Otherwise, the default temporary directory is used. *)
  let get_temporary_socket_dir () =
    match Sys.getenv_opt "XDG_RUNTIME_DIR" with
    | Some xdg_runtime_dir when xdg_runtime_dir <> "" ->
        xdg_runtime_dir
    | Some _ | None ->
        Filename.get_temp_dir_name ()

  let start_process vp =
    let canceler = Lwt_canceler.create () in
    (* We assume that there is only one validation process per socket *)
    (let socket_dir = get_temporary_socket_dir () in
     let process =
       Lwt_process.open_process_none
         (vp.process_path, [|"tezos-validator"; "--socket-dir"; socket_dir|])
     in
     let socket_path =
       External_validation.socket_path ~socket_dir ~pid:process#pid
     in
     (* Make sure that the mimicked anonymous file descriptor is
        removed if the spawn of the process is interupted. Thus, we
        avoid generating potential garbage in the [socket_dir].
        No interruption can occur since the resource was created
        because there are no yield points. *)
     let clean_process_fd socket_path =
       Lwt.catch
         (fun () -> Lwt_unix.unlink socket_path)
         (function
           | Unix.Unix_error (ENOENT, _, _) ->
               (* The file does not exist *)
               Lwt.return_unit
           | exn ->
               Lwt.fail exn)
     in
     let process_fd_cleaner =
       Lwt_exit.register_clean_up_callback ~loc:__LOC__ (fun _ ->
           clean_process_fd socket_path)
     in
     Lwt.finalize
       (fun () ->
         External_validation.create_socket_listen
           ~canceler
           ~max_requests:1
           ~socket_path
         >>= fun process_socket -> Lwt_unix.accept process_socket)
       (fun () ->
         (* As the external validation process is now started, we can
            unlink the named socket. Indeed, the file descriptor will
            remain valid as long as at least one process keeps it
            open. This method mimics an anonymous file descriptor
            without relying on Linux specific features. It also
            trigger the clean up procedure if some sockets related
            errors are thrown. *)
         clean_process_fd socket_path)
     >>= fun (process_socket, _) ->
     Lwt_exit.unregister_clean_up_callback process_fd_cleaner ;
     Lwt.return (process, process_socket))
    >>= fun (process, process_socket) ->
    let process_stdin = Lwt_io.of_fd ~mode:Output process_socket in
    let process_stdout = Lwt_io.of_fd ~mode:Input process_socket in
    Events.(emit validator_started process#pid)
    >>= fun () ->
    let parameters =
      {
        External_validation.context_root = vp.context_root;
        protocol_root = vp.protocol_root;
        sandbox_parameters = vp.sandbox_parameters;
        genesis = vp.genesis;
        user_activated_upgrades = vp.user_activated_upgrades;
        user_activated_protocol_overrides =
          vp.user_activated_protocol_overrides;
      }
    in
    vp.validator_process <-
      Some {process; stdin = process_stdin; stdout = process_stdout; canceler} ;
    External_validation.send
      process_stdin
      Data_encoding.Variable.bytes
      External_validation.magic
    >>= fun () ->
    External_validation.recv process_stdout Data_encoding.Variable.bytes
    >>= fun magic ->
    fail_when
      (not (Bytes.equal magic External_validation.magic))
      (Block_validator_errors.Validation_process_failed
         (Inconsistent_handshake "bad magic"))
    >>=? fun () ->
    External_validation.send
      process_stdin
      External_validation.parameters_encoding
      parameters
    >>= fun () -> return (process, process_stdin, process_stdout)

  let send_request vp request result_encoding =
    ( match vp.validator_process with
    | Some {process; stdin = process_stdin; stdout = process_stdout; canceler}
      -> (
      match process#state with
      | Running ->
          return (process, process_stdin, process_stdout)
      | Exited status ->
          Lwt_canceler.cancel canceler
          >>= fun () ->
          vp.validator_process <- None ;
          Events.(emit process_exited_abnormally status)
          >>= fun () -> start_process vp )
    | None ->
        start_process vp )
    >>=? fun (process, process_stdin, process_stdout) ->
    Lwt.catch
      (fun () ->
        (* Make sure that the promise is not canceled between a send and recv *)
        Lwt.protected
          (Lwt_mutex.with_lock vp.lock (fun () ->
               let now = Systime_os.now () in
               Events.(emit request_for request)
               >>= fun () ->
               External_validation.send
                 process_stdin
                 External_validation.request_encoding
                 request
               >>= fun () ->
               External_validation.recv_result process_stdout result_encoding
               >>= fun res ->
               let timespan =
                 let then_ = Systime_os.now () in
                 Ptime.diff then_ now
               in
               Events.(emit request_result (request, timespan))
               >>= fun () -> Lwt.return res))
        >>=? fun res ->
        match process#state with
        | Running ->
            return res
        | Exited status ->
            vp.validator_process <- None ;
            Events.(emit process_exited_abnormally status)
            >>= fun () -> return res)
      (function
        | errors ->
            ( match process#state with
            | Running ->
                Lwt.return_unit
            | Exited status ->
                Events.(emit process_exited_abnormally status)
                >>= fun () ->
                vp.validator_process <- None ;
                Lwt.return_unit )
            >>= fun () -> Lwt.return (error_exn errors))

  let init
      ({genesis; user_activated_upgrades; user_activated_protocol_overrides} :
        validator_environment) data_dir context_root protocol_root process_path
      sandbox_parameters =
    Events.(emit init ())
    >>= fun () ->
    let validator =
      {
        data_dir;
        context_root;
        protocol_root;
        genesis;
        user_activated_upgrades;
        user_activated_protocol_overrides;
        process_path;
        validator_process = None;
        lock = Lwt_mutex.create ();
        sandbox_parameters;
      }
    in
    send_request validator External_validation.Init Data_encoding.empty
    >>=? fun () -> return validator

  let apply_block validator ~predecessor ~max_operations_ttl block_header
      operations =
    let chain_state = State.Block.chain_state predecessor in
    let predecessor_block_header = State.Block.header predecessor in
    let chain_id = State.Chain.id chain_state in
    State.Block.metadata_hash predecessor
    >>= fun predecessor_block_metadata_hash ->
    State.Block.all_operations_metadata_hash predecessor
    >>= fun predecessor_ops_metadata_hash ->
    let request =
      External_validation.Validate
        {
          chain_id;
          block_header;
          predecessor_block_header;
          predecessor_block_metadata_hash;
          predecessor_ops_metadata_hash;
          operations;
          max_operations_ttl;
        }
    in
    send_request validator request Block_validation.result_encoding

  let commit_genesis validator ~chain_id =
    let request = External_validation.Commit_genesis {chain_id} in
    send_request validator request Context_hash.encoding

  let init_test_chain validator forking_block =
    let forked_header = State.Block.header forking_block in
    let context_hash = forked_header.shell.context in
    let request =
      External_validation.Fork_test_chain {context_hash; forked_header}
    in
    send_request validator request Block_header.encoding

  let restore_context_integrity validator =
    let request = External_validation.Restore_context_integrity in
    send_request validator request Data_encoding.(option int31)

  let close vp =
    Events.(emit close ())
    >>= fun () ->
    match vp.validator_process with
    | Some {process; stdin = process_stdin; canceler; _} ->
        let request = External_validation.Terminate in
        Events.(emit request_for request)
        >>= fun () ->
        External_validation.send
          process_stdin
          External_validation.request_encoding
          request
        >>= fun () ->
        process#status
        >>= (function
              | Unix.WEXITED 0 ->
                  Events.(emit process_exited_normally ())
                  >>= fun () -> Lwt.return_unit
              | status ->
                  Events.(emit process_exited_abnormally status)
                  >>= fun () -> process#terminate ; Lwt.return_unit)
        >>= fun () ->
        Lwt_canceler.cancel canceler
        >>= fun () ->
        vp.validator_process <- None ;
        Lwt.return_unit
    | None ->
        Lwt.return_unit
end

let init : validator_environment -> validator_kind -> t tzresult Lwt.t =
 fun validator_environment validator_kind ->
  match validator_kind with
  | Internal index ->
      Internal_validator_process.init validator_environment index
      >>=? fun (validator : 'a) ->
      let validator_process : (module S with type t = 'a) =
        (module Internal_validator_process)
      in
      return (E {validator_process; validator})
  | External
      {data_dir; context_root; protocol_root; process_path; sandbox_parameters}
    ->
      External_validator_process.init
        validator_environment
        data_dir
        context_root
        protocol_root
        process_path
        sandbox_parameters
      >>=? fun (validator : 'b) ->
      let validator_process : (module S with type t = 'b) =
        (module External_validator_process)
      in
      return (E {validator_process; validator})

let close (E {validator_process = (module VP); validator}) = VP.close validator

let restore_context_integrity (E {validator_process = (module VP); validator})
    =
  VP.restore_context_integrity validator

let apply_block (E {validator_process = (module VP); validator}) ~predecessor
    header operations =
  let chain_state = State.Block.chain_state predecessor in
  State.Block.max_operations_ttl predecessor
  >>=? fun max_operations_ttl ->
  Chain.data chain_state
  >>= fun chain_data ->
  ( if State.Block.equal chain_data.current_head predecessor then
    return (chain_data.live_blocks, chain_data.live_operations)
  else
    let hash = State.Block.hash predecessor in
    trace
      (Block_validator_errors.Failed_to_get_live_blocks hash)
      (Chain_traversal.live_blocks predecessor max_operations_ttl) )
  >>=? fun (live_blocks, live_operations) ->
  let block_hash = Block_header.hash header in
  Lwt.return
    (Block_validation.check_liveness
       ~live_operations
       ~live_blocks
       block_hash
       operations)
  >>=? fun () ->
  VP.apply_block validator ~predecessor ~max_operations_ttl header operations

let commit_genesis (E {validator_process = (module VP); validator}) ~chain_id =
  VP.commit_genesis validator ~chain_id

let init_test_chain (E {validator_process = (module VP); validator})
    forked_block =
  VP.init_test_chain validator forked_block
