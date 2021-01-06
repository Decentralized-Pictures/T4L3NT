(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

(** Tezos Shell - Abstraction over all the disk storage.

    It encapsulates access to:

    - the index of validation contexts; and
    - the persistent state of the node:
    - the blockchain and its alternate heads ;
    - the pool of pending operations of a chain. *)

type t

type global_state = t

(** {2 Network} *)

(** Data specific to a given chain (e.g. the main chain or the current
    test chain).  *)
module Chain : sig
  type t

  type chain_state = t

  (** Initialize a chain for a given [genesis]. By default,
      the chain does accept forking test chain. When
      [~allow_forked_chain:true] is provided, test chain are allowed. *)
  val create :
    global_state ->
    ?allow_forked_chain:bool ->
    commit_genesis:(chain_id:Chain_id.t -> Context_hash.t tzresult Lwt.t) ->
    Genesis.t ->
    Chain_id.t ->
    chain_state tzresult Lwt.t

  (** Look up for a chain by the hash of its genesis block. *)
  val get : global_state -> Chain_id.t -> chain_state tzresult Lwt.t

  val get_opt : global_state -> Chain_id.t -> chain_state option Lwt.t

  val get_exn : global_state -> Chain_id.t -> chain_state Lwt.t

  val main : global_state -> Chain_id.t

  val test : chain_state -> Chain_id.t option Lwt.t

  (** Returns all the known chains. *)
  val all : global_state -> chain_state Seq.t Lwt.t

  (** Destroy a chain: this completely removes from the local storage all
      the data associated to the chain (this includes blocks and
      operations). *)
  val destroy : global_state -> chain_state -> unit Lwt.t

  (** Various accessors. *)
  val id : chain_state -> Chain_id.t

  val genesis : chain_state -> Genesis.t

  val global_state : chain_state -> global_state

  (** Hash of the faked block header of the genesis block. *)
  val faked_genesis_hash : chain_state -> Block_hash.t

  (** Return the expiration timestamp of a test chain. *)
  val expiration : chain_state -> Time.Protocol.t option

  val allow_forked_chain : chain_state -> bool

  val checkpoint : chain_state -> Block_header.t Lwt.t

  val save_point : chain_state -> (Int32.t * Block_hash.t) Lwt.t

  val caboose : chain_state -> (Int32.t * Block_hash.t) Lwt.t

  val store : chain_state -> Store.t Lwt.t

  (** Update the current checkpoint. The current head should be
      consistent (i.e. it should either have a lower level or pass
      through the checkpoint). In the process all the blocks from
      invalid alternate heads are removed from the disk, either
      completely (when `level <= checkpoint`) or still tagged as
      invalid (when `level > checkpoint`). *)
  val set_checkpoint : chain_state -> Block_header.t -> unit Lwt.t

  (** Apply [set_checkpoint] then [purge_full] (see {!History_mode.t}). *)
  val set_checkpoint_then_purge_full :
    chain_state -> Block_header.t -> unit tzresult Lwt.t

  (** Apply [set_checkpoint] then [purge_rolling] (see {!History_mode.t}). *)
  val set_checkpoint_then_purge_rolling :
    chain_state -> Block_header.t -> unit tzresult Lwt.t

  (** Check that a block is compatible with the current checkpoint.
      This function assumes that the predecessor is known valid. *)
  val acceptable_block : chain_state -> Block_header.t -> bool Lwt.t

  (** List all the indexed protocols in the chain. The resulting list
     contains elements of the form [<proto_level>, (<proto_hash>,
     <activation_level>)]. *)
  val all_indexed_protocols :
    chain_state -> (int * (Protocol_hash.t * int32)) list Lwt.t

  (** Get the level indexed chain protocol store for the given header. *)
  val get_level_indexed_protocol :
    chain_state -> Block_header.t -> Protocol_hash.t Lwt.t

  (** Update the level indexed chain protocol store so that the block can easily access
      its corresponding protocol hash from the protocol level in its header.
      Also stores the transition block level.
  *)
  val update_level_indexed_protocol_store :
    chain_state ->
    Chain_id.t ->
    int ->
    Protocol_hash.t ->
    Block_header.t ->
    unit Lwt.t
end

(** {2 Block database} *)

type error += Block_not_found of Block_hash.t

type error += Block_contents_not_found of Block_hash.t

module Block : sig
  type t

  type block = t

  (** Abstract view over block header storage.
      This module aims to abstract over block header's [read], [read_opt] and [known]
      functions by calling the adequate function depending on the block being pruned or not. *)
  module Header : sig
    val read :
      Store.Block.store * Block_hash.t -> Block_header.t tzresult Lwt.t

    val read_opt :
      Store.Block.store * Block_hash.t -> Block_header.t option Lwt.t

    val known : Store.Block.store * Block_hash.t -> bool Lwt.t
  end

  val known : Chain.t -> Block_hash.t -> bool Lwt.t

  val known_valid : Chain.t -> Block_hash.t -> bool Lwt.t

  val known_invalid : Chain.t -> Block_hash.t -> bool Lwt.t

  val read_invalid :
    Chain.t -> Block_hash.t -> Store.Block.invalid_block option Lwt.t

  val list_invalid : Chain.t -> (Block_hash.t * int32 * error list) list Lwt.t

  val unmark_invalid : Chain.t -> Block_hash.t -> unit tzresult Lwt.t

  val read : Chain.t -> Block_hash.t -> t tzresult Lwt.t

  val read_opt : Chain.t -> Block_hash.t -> t option Lwt.t

  (** Will return the full block if the block has never been cleaned
     (all blocks for nodes whose history-mode is set to archive), only
     the header for nodes below the save point (nodes in full or
     rolling history-mode). Will fail with `Not_found` if the given
     hash is unknown. *)
  val read_predecessor : Chain.t -> pred:int -> Block_hash.t -> t option Lwt.t

  val store :
    Chain.t ->
    Block_header.t ->
    Bytes.t ->
    Operation.t list list ->
    Bytes.t list list ->
    Block_metadata_hash.t option ->
    Operation_metadata_hash.t list list option ->
    Block_validation.validation_store ->
    forking_testchain:bool ->
    block option tzresult Lwt.t

  val store_invalid :
    Chain.t -> Block_header.t -> error list -> bool tzresult Lwt.t

  (** [remove block] deletes every occurrence of [block] in the
      different stores. If [block] is the current head, the head is
      also backtracked to the [block] predecessor *)
  val remove : t -> unit tzresult Lwt.t

  val compare : t -> t -> int

  val equal : t -> t -> bool

  val hash : t -> Block_hash.t

  val header : t -> Block_header.t

  val header_of_hash : Chain.t -> Block_hash.t -> Block_header.t option Lwt.t

  val shell_header : t -> Block_header.shell_header

  val timestamp : t -> Time.Protocol.t

  val fitness : t -> Fitness.t

  val validation_passes : t -> int

  val chain_id : t -> Chain_id.t

  val chain_state : t -> Chain.t

  val level : t -> Int32.t

  val message : t -> string option tzresult Lwt.t

  val max_operations_ttl : t -> int tzresult Lwt.t

  val metadata : t -> Bytes.t tzresult Lwt.t

  val last_allowed_fork_level : t -> Int32.t tzresult Lwt.t

  val is_genesis : t -> bool

  val predecessor : t -> t option Lwt.t

  val predecessor_n : t -> int -> Block_hash.t option Lwt.t

  val is_valid_for_checkpoint : t -> Block_header.t -> bool Lwt.t

  val context : t -> Context.t tzresult Lwt.t

  val context_opt : t -> Context.t option Lwt.t

  val context_exn : t -> Context.t Lwt.t

  val context_exists : t -> bool Lwt.t

  val protocol_hash : t -> Protocol_hash.t tzresult Lwt.t

  val protocol_hash_exn : t -> Protocol_hash.t Lwt.t

  val test_chain : t -> (Test_chain_status.t * t option) Lwt.t

  val protocol_level : t -> int

  val operation_hashes :
    t -> int -> (Operation_hash.t list * Operation_list_list_hash.path) Lwt.t

  val all_operation_hashes : t -> Operation_hash.t list list Lwt.t

  val operations :
    t -> int -> (Operation.t list * Operation_list_list_hash.path) Lwt.t

  val all_operations : t -> Operation.t list list Lwt.t

  val operations_metadata : t -> int -> Bytes.t list Lwt.t

  val all_operations_metadata : t -> Bytes.t list list Lwt.t

  val metadata_hash : t -> Block_metadata_hash.t option Lwt.t

  val operations_metadata_hashes :
    t -> int -> Operation_metadata_hash.t list option Lwt.t

  val all_operations_metadata_hashes :
    t -> Operation_metadata_hash.t list list option Lwt.t

  val all_operations_metadata_hash :
    t -> Operation_metadata_list_list_hash.t option Lwt.t

  val watcher : Chain.t -> block Lwt_stream.t * Lwt_watcher.stopper

  val known_ancestor :
    Chain.t ->
    Block_locator.t ->
    (Block_locator.validity * Block_locator.t) Lwt.t

  val get_rpc_directory : t -> t RPC_directory.t option Lwt.t

  val set_rpc_directory : t -> t RPC_directory.t -> unit Lwt.t

  val get_header_rpc_directory :
    Chain.t ->
    Block_header.t ->
    (Chain.t * Block_hash.t * Block_header.t) RPC_directory.t option Lwt.t

  val set_header_rpc_directory :
    Chain.t ->
    Block_header.t ->
    (Chain.t * Block_hash.t * Block_header.t) RPC_directory.t ->
    unit Lwt.t
end

val read_block : global_state -> Block_hash.t -> Block.t option Lwt.t

val read_block_exn : global_state -> Block_hash.t -> Block.t Lwt.t

val watcher : t -> Block.t Lwt_stream.t * Lwt_watcher.stopper

(** Computes the block with the best fitness amongst the known blocks
    which are compatible with the given checkpoint. *)
val best_known_head_for_checkpoint : Chain.t -> Block_header.t -> Block.t Lwt.t

val update_testchain : Block.t -> testchain_state:Chain.t -> unit Lwt.t

val fork_testchain :
  Block.t ->
  Chain_id.t ->
  Block_hash.t ->
  Block_header.t ->
  Protocol_hash.t ->
  Time.Protocol.t ->
  Chain.t tzresult Lwt.t

type chain_data = {
  current_head : Block.t;
  current_mempool : Mempool.t;
  live_blocks : Block_hash.Set.t;
  live_operations : Operation_hash.Set.t;
  test_chain : Chain_id.t option;
  save_point : Int32.t * Block_hash.t;
  caboose : Int32.t * Block_hash.t;
}

val read_chain_data :
  Chain.t -> (Store.Chain_data.store -> chain_data -> 'a Lwt.t) -> 'a Lwt.t

val update_chain_data :
  Chain.t ->
  (Store.Chain_data.store -> chain_data -> (chain_data option * 'a) Lwt.t) ->
  'a Lwt.t

(** {2 Protocol database} *)

module Protocol : sig
  include module type of struct
    include Protocol
  end

  (** Is a value stored in the local database ? *)
  val known : global_state -> Protocol_hash.t -> bool Lwt.t

  (** Read a value in the local database. *)
  val read : global_state -> Protocol_hash.t -> Protocol.t tzresult Lwt.t

  val read_opt : global_state -> Protocol_hash.t -> Protocol.t option Lwt.t

  (** Read a value in the local database (without parsing). *)
  val read_raw : global_state -> Protocol_hash.t -> Bytes.t tzresult Lwt.t

  val read_raw_opt : global_state -> Protocol_hash.t -> Bytes.t option Lwt.t

  val store : global_state -> Protocol.t -> Protocol_hash.t option Lwt.t

  (** Remove a value from the local database. *)
  val remove : global_state -> Protocol_hash.t -> bool Lwt.t

  val list : global_state -> Protocol_hash.Set.t Lwt.t

  val watcher :
    global_state -> Protocol_hash.t Lwt_stream.t * Lwt_watcher.stopper
end

module Current_mempool : sig
  (** The current mempool. *)
  val get : Chain.t -> (Block_header.t * Mempool.t) Lwt.t

  (** Set the current mempool. It is ignored if the current head is
      not the provided one. *)
  val set : Chain.t -> head:Block_hash.t -> Mempool.t -> unit Lwt.t
end

type error +=
  | Incorrect_history_mode_switch of {
      previous_mode : History_mode.t;
      next_mode : History_mode.t;
    }

val history_mode : global_state -> History_mode.t Lwt.t

(** [compute_locator chain ?max_size block seed] computes a
    locator of the [chain] from [head] to the chain's caboose or until
    the locator contains [max_size] steps.
    [max_size] defaults to 200. *)
val compute_locator :
  Chain.t ->
  ?max_size:int ->
  Block.t ->
  Block_locator.seed ->
  Block_locator.t Lwt.t

(** [compute_protocol_locator chain ?max_size ~proto_level seed]
    computes a locator for a specific protocol of level [proto_level]
    in the [chain] from the latest block with this protocol to its
    activation block or until the locator contains [max_size] steps.
    [max_size] defaults to 200. *)
val compute_protocol_locator :
  Chain.t ->
  ?max_size:int ->
  proto_level:int ->
  Block_locator.seed ->
  Block_locator.t option Lwt.t

(** Read the internal state of the node and initialize
    the databases. *)
val init :
  ?patch_context:(Context.t -> Context.t tzresult Lwt.t) ->
  ?commit_genesis:(chain_id:Chain_id.t -> Context_hash.t tzresult Lwt.t) ->
  ?store_mapsize:int64 ->
  ?context_mapsize:int64 ->
  store_root:string ->
  context_root:string ->
  ?history_mode:History_mode.t ->
  ?readonly:bool ->
  Genesis.t ->
  (global_state * Chain.t * Context.index * History_mode.t) tzresult Lwt.t

val close : global_state -> unit Lwt.t
