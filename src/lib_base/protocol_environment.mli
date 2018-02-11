
open Error_monad


module type CONTEXT = sig
  type t
  type key = string list
  type value = MBytes.t
  val mem: t -> key -> bool Lwt.t
  val dir_mem: t -> key -> bool Lwt.t
  val get: t -> key -> value option Lwt.t
  val set: t -> key -> value -> t Lwt.t
  val del: t -> key -> t Lwt.t
  val remove_rec: t -> key -> t Lwt.t
  val fold:
    t -> key -> init:'a ->
    f:([ `Key of key | `Dir of key ] -> 'a -> 'a Lwt.t) ->
    'a Lwt.t
end

module type UPDATER = sig

  module Context : CONTEXT

  type validation_result = {
    context: Context.t ;
    fitness: Fitness.t ;
    message: string option ;
    max_operation_data_length: int ;
    max_operations_ttl: int ;
  }

  type quota = {
    max_size: int ;
    max_op: int option ;
  }

  type rpc_context = {
    block_hash: Block_hash.t ;
    block_header: Block_header.t ;
    operation_hashes: unit -> Operation_hash.t list list Lwt.t ;
    operations: unit -> Operation.t list list Lwt.t ;
    context: Context.t ;
  }

  val compile: Protocol_hash.t -> Protocol.t -> bool Lwt.t
  val activate: Context.t -> Protocol_hash.t -> Context.t Lwt.t
  val fork_test_network:
    Context.t -> protocol:Protocol_hash.t -> expiration:Time.t -> Context.t Lwt.t

end

module type T = sig
  type context
  type quota
  type validation_result
  type rpc_context
  type 'a tzresult
  val max_block_length: int
  val validation_passes: quota list
  type operation
  val parse_operation:
    Operation_hash.t -> Operation.t -> operation tzresult
  val acceptable_passes: operation -> int list
  val compare_operations: operation -> operation -> int
  type validation_state
  val current_context: validation_state -> context tzresult Lwt.t
  val precheck_block:
    ancestor_context: context ->
    ancestor_timestamp: Time.t ->
    Block_header.t ->
    unit tzresult Lwt.t
  val begin_application:
    predecessor_context: context ->
    predecessor_timestamp: Time.t ->
    predecessor_fitness: Fitness.t ->
    Block_header.t ->
    validation_state tzresult Lwt.t
  val begin_construction:
    predecessor_context: context ->
    predecessor_timestamp: Time.t ->
    predecessor_level: Int32.t ->
    predecessor_fitness: Fitness.t ->
    predecessor: Block_hash.t ->
    timestamp: Time.t ->
    ?proto_header: MBytes.t ->
    unit -> validation_state tzresult Lwt.t
  val apply_operation:
    validation_state -> operation -> validation_state tzresult Lwt.t
  val finalize_block:
    validation_state -> validation_result tzresult Lwt.t
  val rpc_services: rpc_context Lwt.t RPC_directory.t
  val configure_sandbox:
    context -> Data_encoding.json option -> context tzresult Lwt.t
end

module type V1 = sig

  include Tezos_protocol_environment_sigs.V1.T
    with type Format.formatter = Format.formatter
     and type 'a Data_encoding.t = 'a Data_encoding.t
     and type 'a Lwt.t = 'a Lwt.t
     and type ('a, 'b) Pervasives.result = ('a, 'b) result
     and type Block_hash.t = Block_hash.t
     and type Operation_hash.t = Operation_hash.t
     and type Operation_list_hash.t = Operation_list_hash.t
     and type Operation_list_list_hash.t = Operation_list_list_hash.t
     and type Context_hash.t = Context_hash.t
     and type Protocol_hash.t = Protocol_hash.t
     and type Time.t = Time.t
     and type MBytes.t = MBytes.t
     and type Operation.shell_header = Operation.shell_header
     and type Operation.t = Operation.t
     and type Block_header.shell_header = Block_header.shell_header
     and type Block_header.t = Block_header.t
     and type 'a RPC_directory.t = 'a RPC_directory.t
     and type Ed25519.Public_key_hash.t = Ed25519.Public_key_hash.t
     and type Ed25519.Public_key.t = Ed25519.Public_key.t
     and type Ed25519.Secret_key.t = Ed25519.Secret_key.t
     and type Ed25519.Signature.t = Ed25519.Signature.t
     and type 'a Micheline.canonical = 'a Micheline.canonical
     and type ('a, 'b) Micheline.node = ('a, 'b) Micheline.node
     and type Data_encoding.json_schema = Data_encoding.json_schema
     and type ('a, 'b) RPC_path.t = ('a, 'b) RPC_path.t
     and type RPC_service.meth = RPC_service.meth
     and type (+'m,'pr,'p,'q,'i,'o) RPC_service.t = ('m,'pr,'p,'q,'i,'o) RPC_service.t

  type error += Ecoproto_error of Error_monad.error list
  val wrap_error : 'a Error_monad.tzresult -> 'a tzresult

  module Lift (P : Updater.PROTOCOL) :
    T with type context := Context.t
       and type quota := Updater.quota
       and type validation_result := Updater.validation_result
       and type rpc_context := Updater.rpc_context
       and type 'a tzresult := 'a tzresult

end

module MakeV1
    (Param : sig val name: string end)
    (Context : CONTEXT)
    (Updater : UPDATER with module Context := Context)
    () : V1 with type Context.t = Context.t
             and type Updater.validation_result = Updater.validation_result
             and type Updater.quota = Updater.quota
             and type Updater.rpc_context = Updater.rpc_context

