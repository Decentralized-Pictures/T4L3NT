(** Create and manipulate bootstrap-parameters and accounts. *)

open Internal_pervasives
open Protocol

(** Manipulate public/private key pairs. *)
module Key : sig
  (** Deterministically generate public/private key (hashes) from
      given strings. *)
  module Of_name : sig
    val pubkey : string -> string
    val pubkey_hash : string -> string
    val private_key : string -> string
  end
end

(** Create and transform Michelson programs. *)
module Script : sig
  type origin = [`Sandbox_faucet | `String of string]

  val parse :
    string -> Alpha_context.Script.expr

  val code_of_json_exn :
    string
    -> Michelson_v1_primitives.prim
      Tezos_micheline.Micheline.canonical

  val json_script_repr :
    Script_repr.expr
    -> Script_repr.expr
    -> Ezjsonm.t

  val original_json : string
  val faucet_tz : string

  val print :
    Script_repr.expr
    -> Script_repr.expr
    -> unit

  val load : origin -> Ezjsonm.t
  val test : unit -> unit
end

(** An account is a named key-pair. *)
module Account : sig
  type t = private
    | Of_name of string
    | Key_pair of
        { name: string
        ; pubkey: string
        ; pubkey_hash: string
        ; private_key: string }

  val of_name : string -> t
  val of_namef : ('a, unit, string, t) format4 -> 'a

  val key_pair :
    string -> pubkey:string -> pubkey_hash:string -> private_key:string -> t

  val name : t -> string
  val pubkey : t -> string
  val pubkey_hash : t -> string
  val private_key : t -> string
end

module Voting_period : sig
  type t = Alpha_context.Voting_period.kind =
    | Proposal
    | Testing_vote
    | Testing
    | Promotion_vote

  val to_string : t -> string
end

(** [t] wraps bootstrap parameters for sandboxed protocols. *)
type t =
  { id: string
  ; bootstrap_accounts: (Account.t * Int64.t) list
  ; dictator: Account.t
  ; bootstrap_contracts: (Account.t * int * Script.origin) list
  ; expected_pow: int
  ; name: string
  ; hash: string
  ; time_between_blocks: int list
  ; blocks_per_roll_snapshot: int
  ; blocks_per_voting_period: int
  ; blocks_per_cycle: int
  ; preserved_cycles: int
  ; proof_of_work_threshold: int
  ; blocks_per_commitment: int
  ; endorsers_per_block: int
  ; hard_gas_limit_per_operation: int
  ; hard_gas_limit_per_block: int
  ; tokens_per_roll: int
  ; michelson_maximum_type_size: int
  ; seed_nonce_revelation_tip: int
  ; origination_size: int
  ; block_security_deposit: int
  ; endorsement_security_deposit: int
  ; block_reward: int
  ; endorsement_reward: int
  ; hard_storage_limit_per_operation: int
  ; cost_per_byte: int
  ; test_chain_duration: int
  ; quorum_min: int
  ; quorum_max: int
  ; min_proposal_quorum: int
  ; initial_endorsers: int
  ; delay_per_missing_endorsement: int }

val compare : t -> t -> int
val default : unit -> t
val protocol_parameters_json : t -> Ezjsonm.t
val sandbox : t -> string
val protocol_parameters : t -> string
val expected_pow : t -> int
val id : t -> string
val bootstrap_accounts : t -> Account.t list
val dictator_name : t -> string
val dictator_secret_key : t -> string
val sandbox_path : config:< paths: Paths.t ; .. > -> t -> string
val protocol_parameters_path : config:< paths: Paths.t ; .. > -> t -> string

val ensure_script :
  config:< paths: Paths.t ; .. > -> t -> unit Genspio.Language.t
(** Build a {!Genspio.EDSL.t} script which generates the
    bootstrap-parameters JSON file. *)

val ensure :
     t
  -> config:< paths: Paths.t ; .. >
  -> (unit, [> `Lwt_exn of exn]) Asynchronous_result.t
(** Run the script created by [ensure_script], i.e. create the JSON
    bootstrap parameters. *)

val cli_term : unit -> t Cmdliner.Term.t
(** Create a [Cmdliner] term which configures protocol-parameters
    (e.g. options like ["--time-between-blocks"]). *)
