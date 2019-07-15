type args = private
  | Baker : string -> args
  | Endorser : string -> args
  | Accuser : args

type t = private
  { node: Tezos_node.t
  ; client: Tezos_client.t
  ; exec: Tezos_executable.t
  ; args: args
  ; name_tag: string option }

val of_node :
     ?name_tag:string
  -> Tezos_node.t
  -> args
  -> exec:Tezos_executable.t
  -> client:Tezos_client.t
  -> t

val baker_of_node :
     ?name_tag:string
  -> Tezos_node.t
  -> key:string
  -> exec:Tezos_executable.t
  -> client:Tezos_client.t
  -> t

val endorser_of_node :
     ?name_tag:string
  -> Tezos_node.t
  -> key:string
  -> exec:Tezos_executable.t
  -> client:Tezos_client.t
  -> t

val accuser_of_node :
     ?name_tag:string
  -> Tezos_node.t
  -> exec:Tezos_executable.t
  -> client:Tezos_client.t
  -> t

val arg_to_string : args -> string
val to_script : t -> state:< paths: Paths.t ; .. > -> unit Genspio.Language.t
val process : t -> state:< paths: Paths.t ; .. > -> Running_processes.Process.t
