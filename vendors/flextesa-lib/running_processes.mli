(** Run and monitor processes. *)

open Internal_pervasives

(** The definition of a process, for now, a process within a
    process-group or a Docker container. *)
module Process : sig
  type kind =
    [`Process_group | `Docker of string | `Process_group_script of string]

  type t = private {
    id : string;
    binary : string option;
    command : string list;
    kind : kind;
  }

  val make_in_session : ?binary:string -> string -> kind -> string list -> t

  val genspio : string -> 'a Genspio.EDSL.t -> t

  val docker_run :
    string -> image:string -> options:string list -> args:string list -> t
end

(** The container for a list of running or not processes. *)
module State : sig
  type process_state = private {
    process : Process.t;
    lwt : Lwt_process.process_none;
  }

  type t = private {processes : (string, process_state) Hashtbl.t}

  val pp : Format.formatter -> t -> unit

  val make : unit -> t
end

(** Return the path (within {!Paths}'s root-path) where the process
    writes its output or metadata. *)
val output_path :
  < paths : Paths.t ; .. > ->
  Process.t ->
  [`Meta | `Stderr | `Stdout] ->
  string

val ef_procesess :
  < paths : Paths.t ; .. > -> State.process_state list -> Easy_format.t

val ef : ?all:bool -> < runner : State.t ; .. > -> Easy_format.t

val start :
  < application_name : string ; paths : Paths.t ; runner : State.t ; .. > ->
  Process.t ->
  (State.process_state, [> `Lwt_exn of exn]) Asynchronous_result.t

val wait :
  < runner : State.t ; .. > ->
  State.process_state ->
  (Lwt_unix.process_status, [> `Lwt_exn of exn]) Asynchronous_result.t

val kill :
  < runner : State.t ; .. > ->
  State.process_state ->
  (unit, [> `Lwt_exn of exn]) Asynchronous_result.t

val wait_all :
  < runner : State.t ; .. > ->
  (unit, [> `Lwt_exn of exn]) Asynchronous_result.t

val kill_all :
  < runner : State.t ; .. > ->
  (unit, [> `Lwt_exn of exn]) Asynchronous_result.t

val find_process_by_id :
  ?only_running:bool ->
  < runner : State.t ; .. > ->
  f:(string -> bool) ->
  (State.process_state list, [> ]) Asynchronous_result.t

(** Run a shell command and wait for its end. *)
val run_cmdf :
  < paths : Paths.t ; runner : State.t ; .. > Base_state.t ->
  ( 'a,
    unit,
    string,
    (Process_result.t, [> `Lwt_exn of exn]) Asynchronous_result.t )
  format4 ->
  'a

(** Run a shell command and run a function over the process data before waiting for its end. *)
val run_async_cmdf :
  < runner : State.t ; .. > ->
  (Lwt_process.process_full ->
  ('a, ([> `Lwt_exn of exn] as 'b)) Asynchronous_result.t) ->
  ( 'c,
    unit,
    string,
    (Unix.process_status * 'a, 'b) Asynchronous_result.t )
  format4 ->
  'c

val run_successful_cmdf :
  < paths : Paths.t ; runner : State.t ; .. > Base_state.t ->
  ( 'a,
    unit,
    string,
    ( Process_result.t,
      [> `Lwt_exn of exn | Process_result.Error.t] )
    Asynchronous_result.t )
  format4 ->
  'a

val run_genspio :
  < paths : Paths.t ; runner : State.t ; .. > Base_state.t ->
  string ->
  'a Genspio.Language.t ->
  (Lwt_unix.process_status, [> `Lwt_exn of exn]) Asynchronous_result.t
