open Internal_pervasives
(** Wrapper around the main ["tezos-client"] application. *)

type t = {id : string; port : int; exec : Tezos_executable.t}

type client = t

(** Create a client which is meant to communicate with a given node. *)
val of_node : exec:Tezos_executable.t -> Tezos_node.t -> t

(** Create a client not connected to a node (e.g. for ledger interaction). *)
val no_node_client : exec:Tezos_executable.t -> t

(** Get the path to the ["--base-dir"] option of the client. *)
val base_dir : t -> state:< paths : Paths.t ; .. > -> string

(** {3 Build Scripts } *)

val client_command :
  t -> state:< paths : Paths.t ; .. > -> string list -> unit Genspio.EDSL.t

val bootstrapped_script :
  t -> state:< paths : Paths.t ; .. > -> unit Genspio.EDSL.t

val import_secret_key_script :
  t ->
  state:< paths : Paths.t ; .. > ->
  string ->
  string ->
  unit Genspio.EDSL.t

val activate_protocol_script :
  t ->
  state:< paths : Paths.t ; .. > ->
  Tezos_protocol.t ->
  unit Genspio.EDSL.t

(** {3 Run Specific Client Commands } *)

(** Wait for the node to be bootstrapped. *)
val bootstrapped :
  t ->
  state:< paths : Paths.t ; runner : Running_processes.State.t ; .. >
        Base_state.t ->
  (unit, [> `Lwt_exn of exn]) Asynchronous_result.t

val import_secret_key :
  t ->
  state:< paths : Paths.t ; runner : Running_processes.State.t ; .. >
        Base_state.t ->
  string ->
  string ->
  (unit, [> `Lwt_exn of exn]) Asynchronous_result.t

val register_as_delegate :
  t ->
  state:< paths : Paths.t ; runner : Running_processes.State.t ; .. >
        Base_state.t ->
  string ->
  (unit, [> `Lwt_exn of exn]) Asynchronous_result.t

val activate_protocol :
  t ->
  state:< paths : Paths.t ; runner : Running_processes.State.t ; .. >
        Base_state.t ->
  Tezos_protocol.t ->
  (unit, [> `Lwt_exn of exn]) Asynchronous_result.t

module Command_error : sig
  type t = [`Client_command_error of string * string list option]

  val failf :
    ?args:string list ->
    ('a, unit, string, ('b, [> t]) Asynchronous_result.t) format4 ->
    'a

  val pp : Format.formatter -> t -> unit
end

val client_cmd :
  < application_name : string
  ; console : Console.t
  ; paths : Paths.t
  ; runner : Running_processes.State.t
  ; .. > ->
  client:client ->
  string list ->
  (bool * Process_result.t, [> `Lwt_exn of exn]) Asynchronous_result.t

val successful_client_cmd :
  < application_name : string
  ; console : Console.t
  ; paths : Paths.t
  ; runner : Running_processes.State.t
  ; .. >
  Base_state.t ->
  client:t ->
  string list ->
  ( < err : string list ; out : string list ; status : Unix.process_status >,
    [> Command_error.t | `Lwt_exn of exn] )
  Asynchronous_result.t

val rpc :
  < application_name : string
  ; console : Console.t
  ; paths : Paths.t
  ; runner : Running_processes.State.t
  ; .. >
  Base_state.t ->
  client:t ->
  [< `Get | `Post of string] ->
  path:string ->
  (Ezjsonm.value, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

(** Use RPCs to find an operation matching [~f] in the node's mempool. *)
val find_applied_in_mempool :
  < application_name : string
  ; console : Console.t
  ; paths : Paths.t
  ; runner : Running_processes.State.t
  ; .. > ->
  client:client ->
  f:(Ezjsonm.value -> bool) ->
  ( Ezjsonm.value option,
    [> Command_error.t | `Lwt_exn of exn] )
  Asynchronous_result.t

(** Use RPCs to find an operation of kind [~kind] in the node's mempool. *)
val mempool_has_operation :
  < application_name : string
  ; console : Console.t
  ; paths : Paths.t
  ; runner : Running_processes.State.t
  ; .. > ->
  client:t ->
  kind:string ->
  (bool, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

(** Use RPCs to find an operation of kind [~kind] in the node's chain
    at a given level. *)
val block_has_operation :
  < application_name : string
  ; console : Console.t
  ; paths : Paths.t
  ; runner : Running_processes.State.t
  ; .. > ->
  client:t ->
  level:int ->
  kind:string ->
  (bool, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

(** Call the RPC ["/chains/main/blocks/<block>/header"]. *)
val get_block_header :
  < application_name : string
  ; console : Console.t
  ; paths : Paths.t
  ; runner : Running_processes.State.t
  ; .. > ->
  client:t ->
  [`Head | `Level of int] ->
  (Ezjsonm.value, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

val list_known_addresses :
  < application_name : string
  ; console : Console.t
  ; paths : Paths.t
  ; runner : Running_processes.State.t
  ; .. > ->
  client:t ->
  ( (string * string) list,
    [> Command_error.t | `Lwt_exn of exn] )
  Asynchronous_result.t

module Ledger : sig
  type hwm = {main : int; test : int; chain : Tezos_crypto.Chain_id.t option}

  val get_hwm :
    < application_name : string
    ; console : Console.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    client:t ->
    uri:string ->
    (hwm, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

  val set_hwm :
    < application_name : string
    ; console : Console.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    client:t ->
    uri:string ->
    level:int ->
    (unit, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

  val show_ledger :
    < application_name : string
    ; console : Console.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    client:t ->
    uri:string ->
    ( Tezos_protocol.Account.t,
      [> Command_error.t | `Lwt_exn of exn] )
    Asynchronous_result.t

  val deauthorize_baking :
    < application_name : string
    ; console : Console.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    client:t ->
    uri:string ->
    (unit, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

  val get_authorized_key :
    < application_name : string
    ; console : Console.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    client:t ->
    uri:string ->
    ( string option,
      [> Command_error.t | `Lwt_exn of exn] )
    Asynchronous_result.t
end

module Keyed : sig
  type t = {client : client; key_name : string; secret_key : string}

  val make : client -> key_name:string -> secret_key:string -> t

  val initialize :
    < application_name : string
    ; console : Console.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    t ->
    ( < err : string list ; out : string list ; status : Unix.process_status >,
      [> Command_error.t | `Lwt_exn of exn] )
    Asynchronous_result.t

  val bake :
    ?chain:string ->
    < application_name : string
    ; console : Console.t
    ; operations_log : Log_recorder.Operations.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    t ->
    string ->
    (unit, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

  val endorse :
    < application_name : string
    ; console : Console.t
    ; operations_log : Log_recorder.Operations.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    t ->
    string ->
    (unit, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

  val generate_nonce :
    < application_name : string
    ; console : Console.t
    ; operations_log : Log_recorder.Operations.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    t ->
    string ->
    (string, [> Command_error.t | `Lwt_exn of exn]) Asynchronous_result.t

  val forge_and_inject :
    < application_name : string
    ; console : Console.t
    ; paths : Paths.t
    ; runner : Running_processes.State.t
    ; .. > ->
    t ->
    json:Ezjsonm.t ->
    ( Ezjsonm.value,
      [> `Client_command_error of string * string list option | `Lwt_exn of exn]
    )
    Asynchronous_result.t
end
