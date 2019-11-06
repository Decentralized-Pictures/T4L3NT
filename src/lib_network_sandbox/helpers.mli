(** Generic testing helpers *)

open Internal_pervasives

(** Display all the P2P connections of a set of nodes, see
    {!Tezos_node.connections}. *)
val dump_connections :
  < application_name : string ; console : Console.t ; .. > ->
  Tezos_node.t list ->
  (unit, [> `Lwt_exn of exn]) Asynchronous_result.t

(** Remove (["rm -fr .."]) the root-path of the current [state]. *)
val clear_root :
  < paths : Paths.t ; .. > ->
  (unit, [> `Lwt_exn of exn | `Sys_error of string]) Asynchronous_result.t

(** Try to wait for an event. *)
val wait_for :
  < application_name : string ; console : Console.t ; .. > ->
  attempts:int ->
  seconds:float ->
  (int ->
  ( [`Done of 'a | `Not_done of string],
    ([> `Lwt_exn of exn | `Waiting_for of string * [`Time_out]] as 'errors) )
  Asynchronous_result.t) ->
  ('a, 'errors) Asynchronous_result.t

(** Kill a node's process. *)
val kill_node :
  < runner : Running_processes.State.t ; .. > ->
  Tezos_node.t ->
  (unit, [> `Lwt_exn of exn | `Sys_error of string]) Asynchronous_result.t

(** Restart a killed node. *)
val restart_node :
  client_exec:Tezos_executable.t ->
  < application_name : string
  ; console : Console.t
  ; paths : Paths.t
  ; runner : Running_processes.State.t
  ; .. > ->
  Tezos_node.t ->
  (unit, [> `Lwt_exn of exn]) Asynchronous_result.t

(** Stateful “message × count” log, see its use in, e.g.,
    ["./src/bin_flextesa/command_voting.ml"] where baked-levels
    are accumulated and then displayed. . *)
module Counter_log : sig
  type t

  val create : unit -> t

  val add : t -> string -> int -> unit

  val incr : t -> string -> unit

  val sum : t -> int

  val to_table_string : t -> string
end

module System_dependencies : sig
  module Error : sig
    type t = [`Precheck_failure of string]

    val pp : Format.formatter -> [< `Precheck_failure of string] -> unit
  end

  val precheck :
    ?using_docker:bool ->
    ?protocol_paths:string list ->
    ?executables:Tezos_executable.t list ->
    < application_name : string
    ; console : Console.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    [< `Or_fail] ->
    (unit, [> Lwt_exception.t | Error.t]) Asynchronous_result.t
end
