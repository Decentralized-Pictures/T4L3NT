(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

open Storage_functors

module Int = struct
  type t = int

  let encoding = Data_encoding.uint16
end

module Int32 = struct
  type t = Int32.t

  let encoding = Data_encoding.int32
end

module Z = struct
  include Z

  let encoding = Data_encoding.z
end

module Int_index = struct
  type t = int

  let path_length = 1

  let to_path c l = string_of_int c :: l

  let of_path = function
    | [] | _ :: _ :: _ ->
        None
    | [c] ->
        int_of_string_opt c

  type 'a ipath = 'a * t

  let args =
    Storage_description.One
      {
        rpc_arg = RPC_arg.int;
        encoding = Data_encoding.int31;
        compare = Compare.Int.compare;
      }
end

module Make_index (H : Storage_description.INDEX) :
  INDEX with type t = H.t and type 'a ipath = 'a * H.t = struct
  include H

  type 'a ipath = 'a * t

  let args = Storage_description.One {rpc_arg; encoding; compare}
end

module Block_priority =
  Make_single_data_storage (Registered) (Raw_context)
    (struct
      let name = ["block_priority"]
    end)
    (Int)

(** Contracts handling *)

module Contract = struct
  module Raw_context =
    Make_subcontext (Registered) (Raw_context)
      (struct
        let name = ["contracts"]
      end)

  module Global_counter =
    Make_single_data_storage (Registered) (Raw_context)
      (struct
        let name = ["global_counter"]
      end)
      (Z)

  module Indexed_context =
    Make_indexed_subcontext
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["index"]
         end))
         (Make_index (Contract_repr.Index))

  let fold = Indexed_context.fold_keys

  let list = Indexed_context.keys

  module Balance =
    Indexed_context.Make_map
      (struct
        let name = ["balance"]
      end)
      (Tez_repr)

  module Frozen_balance_index =
    Make_indexed_subcontext
      (Make_subcontext (Registered) (Indexed_context.Raw_context)
         (struct
           let name = ["frozen_balance"]
         end))
         (Make_index (Cycle_repr.Index))

  module Frozen_deposits =
    Frozen_balance_index.Make_map
      (struct
        let name = ["deposits"]
      end)
      (Tez_repr)

  module Frozen_fees =
    Frozen_balance_index.Make_map
      (struct
        let name = ["fees"]
      end)
      (Tez_repr)

  module Frozen_rewards =
    Frozen_balance_index.Make_map
      (struct
        let name = ["rewards"]
      end)
      (Tez_repr)

  module Manager =
    Indexed_context.Make_map
      (struct
        let name = ["manager"]
      end)
      (Manager_repr)

  module Delegate =
    Indexed_context.Make_map
      (struct
        let name = ["delegate"]
      end)
      (Signature.Public_key_hash)

  module Inactive_delegate =
    Indexed_context.Make_set
      (Registered)
      (struct
        let name = ["inactive_delegate"]
      end)

  module Delegate_desactivation =
    Indexed_context.Make_map
      (struct
        let name = ["delegate_desactivation"]
      end)
      (Cycle_repr)

  module Delegated =
    Make_data_set_storage
      (Make_subcontext (Registered) (Indexed_context.Raw_context)
         (struct
           let name = ["delegated"]
         end))
         (Make_index (Contract_repr.Index))

  module Counter =
    Indexed_context.Make_map
      (struct
        let name = ["counter"]
      end)
      (Z)

  (* Consume gas for serilization and deserialization of expr in this
     module *)
  module Make_carbonated_map_expr (N : Storage_sigs.NAME) = struct
    module I =
      Indexed_context.Make_carbonated_map
        (N)
        (struct
          type t = Script_repr.lazy_expr

          let encoding = Script_repr.lazy_expr_encoding
        end)

    type context = I.context

    type key = I.key

    type value = I.value

    let mem = I.mem

    let delete = I.delete

    let remove = I.remove

    let consume_deserialize_gas ctxt value =
      Lwt.return
      @@ ( Raw_context.check_enough_gas
             ctxt
             (Script_repr.minimal_deserialize_cost value)
         >>? fun () ->
         Script_repr.force_decode value
         >>? fun (_value, value_cost) ->
         Raw_context.consume_gas ctxt value_cost )

    let consume_serialize_gas ctxt value =
      Lwt.return
      @@ ( Script_repr.force_bytes value
         >>? fun (_value, value_cost) ->
         Raw_context.consume_gas ctxt value_cost )

    let get ctxt contract =
      I.get ctxt contract
      >>=? fun (ctxt, value) ->
      consume_deserialize_gas ctxt value >>|? fun ctxt -> (ctxt, value)

    let get_option ctxt contract =
      I.get_option ctxt contract
      >>=? fun (ctxt, value_opt) ->
      match value_opt with
      | None ->
          return (ctxt, None)
      | Some value ->
          consume_deserialize_gas ctxt value >>|? fun ctxt -> (ctxt, value_opt)

    let set ctxt contract value =
      consume_serialize_gas ctxt value
      >>=? fun ctxt -> I.set ctxt contract value

    let set_option ctxt contract value_opt =
      match value_opt with
      | None ->
          I.set_option ctxt contract None
      | Some value ->
          consume_serialize_gas ctxt value
          >>=? fun ctxt -> I.set_option ctxt contract value_opt

    let init ctxt contract value =
      consume_serialize_gas ctxt value
      >>=? fun ctxt -> I.init ctxt contract value

    let init_set ctxt contract value =
      consume_serialize_gas ctxt value
      >>=? fun ctxt -> I.init_set ctxt contract value
  end

  module Code = Make_carbonated_map_expr (struct
    let name = ["code"]
  end)

  module Storage = Make_carbonated_map_expr (struct
    let name = ["storage"]
  end)

  module Paid_storage_space =
    Indexed_context.Make_map
      (struct
        let name = ["paid_bytes"]
      end)
      (Z)

  module Used_storage_space =
    Indexed_context.Make_map
      (struct
        let name = ["used_bytes"]
      end)
      (Z)

  module Roll_list =
    Indexed_context.Make_map
      (struct
        let name = ["roll_list"]
      end)
      (Roll_repr)

  module Change =
    Indexed_context.Make_map
      (struct
        let name = ["change"]
      end)
      (Tez_repr)
end

(** Big maps handling *)

module Big_map = struct
  module Raw_context =
    Make_subcontext (Registered) (Raw_context)
      (struct
        let name = ["big_maps"]
      end)

  module Next = struct
    include Make_single_data_storage (Registered) (Raw_context)
              (struct
                let name = ["next"]
              end)
              (Z)

    let incr ctxt =
      get ctxt
      >>=? fun i -> set ctxt (Z.succ i) >>=? fun ctxt -> return (ctxt, i)

    let init ctxt = init ctxt Z.zero
  end

  module Index = struct
    type t = Z.t

    let rpc_arg =
      let construct = Z.to_string in
      let destruct hash =
        match Z.of_string hash with
        | exception _ ->
            Error "Cannot parse big map id"
        | id ->
            Ok id
      in
      RPC_arg.make
        ~descr:"A big map identifier"
        ~name:"big_map_id"
        ~construct
        ~destruct
        ()

    let encoding =
      Data_encoding.def
        "big_map_id"
        ~title:"Big map identifier"
        ~description:"A big map identifier"
        Z.encoding

    let compare = Compare.Z.compare

    let path_length = 7

    let to_path c l =
      let raw_key = Data_encoding.Binary.to_bytes_exn encoding c in
      let (`Hex index_key) = MBytes.to_hex (Raw_hashes.blake2b raw_key) in
      String.sub index_key 0 2 :: String.sub index_key 2 2
      :: String.sub index_key 4 2 :: String.sub index_key 6 2
      :: String.sub index_key 8 2 :: String.sub index_key 10 2 :: Z.to_string c
      :: l

    let of_path = function
      | []
      | [_]
      | [_; _]
      | [_; _; _]
      | [_; _; _; _]
      | [_; _; _; _; _]
      | [_; _; _; _; _; _]
      | _ :: _ :: _ :: _ :: _ :: _ :: _ :: _ :: _ ->
          None
      | [index1; index2; index3; index4; index5; index6; key] ->
          let c = Z.of_string key in
          let raw_key = Data_encoding.Binary.to_bytes_exn encoding c in
          let (`Hex index_key) = MBytes.to_hex (Raw_hashes.blake2b raw_key) in
          assert (Compare.String.(String.sub index_key 0 2 = index1)) ;
          assert (Compare.String.(String.sub index_key 2 2 = index2)) ;
          assert (Compare.String.(String.sub index_key 4 2 = index3)) ;
          assert (Compare.String.(String.sub index_key 6 2 = index4)) ;
          assert (Compare.String.(String.sub index_key 8 2 = index5)) ;
          assert (Compare.String.(String.sub index_key 10 2 = index6)) ;
          Some c
  end

  module Indexed_context =
    Make_indexed_subcontext
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["index"]
         end))
         (Make_index (Index))

  let rpc_arg = Index.rpc_arg

  let fold = Indexed_context.fold_keys

  let list = Indexed_context.keys

  let remove_rec ctxt n = Indexed_context.remove_rec ctxt n

  let copy ctxt ~from ~to_ = Indexed_context.copy ctxt ~from ~to_

  type key = Raw_context.t * Z.t

  module Total_bytes =
    Indexed_context.Make_map
      (struct
        let name = ["total_bytes"]
      end)
      (Z)

  module Key_type =
    Indexed_context.Make_map
      (struct
        let name = ["key_type"]
      end)
      (struct
        type t = Script_repr.expr

        let encoding = Script_repr.expr_encoding
      end)

  module Value_type =
    Indexed_context.Make_map
      (struct
        let name = ["value_type"]
      end)
      (struct
        type t = Script_repr.expr

        let encoding = Script_repr.expr_encoding
      end)

  module Contents = struct
    module I =
      Storage_functors.Make_indexed_carbonated_data_storage
        (Make_subcontext (Registered) (Indexed_context.Raw_context)
           (struct
             let name = ["contents"]
           end))
           (Make_index (Script_expr_hash))
           (struct
             type t = Script_repr.expr

             let encoding = Script_repr.expr_encoding
           end)

    type context = I.context

    type key = I.key

    type value = I.value

    let mem = I.mem

    let delete = I.delete

    let remove = I.remove

    let set = I.set

    let set_option = I.set_option

    let init = I.init

    let init_set = I.init_set

    let consume_deserialize_gas ctxt value =
      Lwt.return
      @@ Raw_context.consume_gas ctxt (Script_repr.deserialized_cost value)

    let get ctxt contract =
      I.get ctxt contract
      >>=? fun (ctxt, value) ->
      consume_deserialize_gas ctxt value >>|? fun ctxt -> (ctxt, value)

    let get_option ctxt contract =
      I.get_option ctxt contract
      >>=? fun (ctxt, value_opt) ->
      match value_opt with
      | None ->
          return (ctxt, None)
      | Some value ->
          consume_deserialize_gas ctxt value >>|? fun ctxt -> (ctxt, value_opt)
  end
end

module Delegates =
  Make_data_set_storage
    (Make_subcontext (Registered) (Raw_context)
       (struct
         let name = ["delegates"]
       end))
       (Make_index (Signature.Public_key_hash))

module Active_delegates_with_rolls =
  Make_data_set_storage
    (Make_subcontext (Registered) (Raw_context)
       (struct
         let name = ["active_delegates_with_rolls"]
       end))
       (Make_index (Signature.Public_key_hash))

module Delegates_with_frozen_balance_index =
  Make_indexed_subcontext
    (Make_subcontext (Registered) (Raw_context)
       (struct
         let name = ["delegates_with_frozen_balance"]
       end))
       (Make_index (Cycle_repr.Index))

module Delegates_with_frozen_balance =
  Make_data_set_storage
    (Delegates_with_frozen_balance_index.Raw_context)
    (Make_index (Signature.Public_key_hash))

(** Rolls *)

module Cycle = struct
  module Indexed_context =
    Make_indexed_subcontext
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["cycle"]
         end))
         (Make_index (Cycle_repr.Index))

  module Last_roll =
    Make_indexed_data_storage
      (Make_subcontext (Registered) (Indexed_context.Raw_context)
         (struct
           let name = ["last_roll"]
         end))
         (Int_index)
      (Roll_repr)

  module Roll_snapshot =
    Indexed_context.Make_map
      (struct
        let name = ["roll_snapshot"]
      end)
      (Int)

  type unrevealed_nonce = {
    nonce_hash : Nonce_hash.t;
    delegate : Signature.Public_key_hash.t;
    rewards : Tez_repr.t;
    fees : Tez_repr.t;
  }

  type nonce_status =
    | Unrevealed of unrevealed_nonce
    | Revealed of Seed_repr.nonce

  let nonce_status_encoding =
    let open Data_encoding in
    union
      [ case
          (Tag 0)
          ~title:"Unrevealed"
          (tup4
             Nonce_hash.encoding
             Signature.Public_key_hash.encoding
             Tez_repr.encoding
             Tez_repr.encoding)
          (function
            | Unrevealed {nonce_hash; delegate; rewards; fees} ->
                Some (nonce_hash, delegate, rewards, fees)
            | _ ->
                None)
          (fun (nonce_hash, delegate, rewards, fees) ->
            Unrevealed {nonce_hash; delegate; rewards; fees});
        case
          (Tag 1)
          ~title:"Revealed"
          Seed_repr.nonce_encoding
          (function Revealed nonce -> Some nonce | _ -> None)
          (fun nonce -> Revealed nonce) ]

  module Nonce =
    Make_indexed_data_storage
      (Make_subcontext (Registered) (Indexed_context.Raw_context)
         (struct
           let name = ["nonces"]
         end))
         (Make_index (Raw_level_repr.Index))
         (struct
           type t = nonce_status

           let encoding = nonce_status_encoding
         end)

  module Seed =
    Indexed_context.Make_map
      (struct
        let name = ["random_seed"]
      end)
      (struct
        type t = Seed_repr.seed

        let encoding = Seed_repr.seed_encoding
      end)
end

module Roll = struct
  module Raw_context =
    Make_subcontext (Registered) (Raw_context)
      (struct
        let name = ["rolls"]
      end)

  module Indexed_context =
    Make_indexed_subcontext
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["index"]
         end))
         (Make_index (Roll_repr.Index))

  module Next =
    Make_single_data_storage (Registered) (Raw_context)
      (struct
        let name = ["next"]
      end)
      (Roll_repr)

  module Limbo =
    Make_single_data_storage (Registered) (Raw_context)
      (struct
        let name = ["limbo"]
      end)
      (Roll_repr)

  module Delegate_roll_list =
    Wrap_indexed_data_storage
      (Contract.Roll_list)
      (struct
        type t = Signature.Public_key_hash.t

        let wrap = Contract_repr.implicit_contract

        let unwrap = Contract_repr.is_implicit
      end)

  module Successor =
    Indexed_context.Make_map
      (struct
        let name = ["successor"]
      end)
      (Roll_repr)

  module Delegate_change =
    Wrap_indexed_data_storage
      (Contract.Change)
      (struct
        type t = Signature.Public_key_hash.t

        let wrap = Contract_repr.implicit_contract

        let unwrap = Contract_repr.is_implicit
      end)

  module Snapshoted_owner_index = struct
    type t = Cycle_repr.t * int

    let path_length = Cycle_repr.Index.path_length + 1

    let to_path (c, n) s = Cycle_repr.Index.to_path c (string_of_int n :: s)

    let of_path l =
      match Misc.take Cycle_repr.Index.path_length l with
      | None | Some (_, ([] | _ :: _ :: _)) ->
          None
      | Some (l1, [l2]) -> (
        match (Cycle_repr.Index.of_path l1, int_of_string_opt l2) with
        | (None, _) | (_, None) ->
            None
        | (Some c, Some i) ->
            Some (c, i) )

    type 'a ipath = ('a * Cycle_repr.t) * int

    let left_args =
      Storage_description.One
        {
          rpc_arg = Cycle_repr.rpc_arg;
          encoding = Cycle_repr.encoding;
          compare = Cycle_repr.compare;
        }

    let right_args =
      Storage_description.One
        {
          rpc_arg = RPC_arg.int;
          encoding = Data_encoding.int31;
          compare = Compare.Int.compare;
        }

    let args = Storage_description.(Pair (left_args, right_args))
  end

  module Owner =
    Make_indexed_data_snapshotable_storage
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["owner"]
         end))
         (Snapshoted_owner_index)
      (Make_index (Roll_repr.Index))
      (Signature.Public_key)

  module Snapshot_for_cycle = Cycle.Roll_snapshot
  module Last_for_snapshot = Cycle.Last_roll

  let clear = Indexed_context.clear
end

(** Votes *)

module Vote = struct
  module Raw_context =
    Make_subcontext (Registered) (Raw_context)
      (struct
        let name = ["votes"]
      end)

  module Current_period_kind =
    Make_single_data_storage (Registered) (Raw_context)
      (struct
        let name = ["current_period_kind"]
      end)
      (struct
        type t = Voting_period_repr.kind

        let encoding = Voting_period_repr.kind_encoding
      end)

  module Participation_ema =
    Make_single_data_storage (Registered) (Raw_context)
      (struct
        let name = ["participation_ema"]
      end)
      (Int32)

  module Current_proposal =
    Make_single_data_storage (Registered) (Raw_context)
      (struct
        let name = ["current_proposal"]
      end)
      (Protocol_hash)

  module Listings_size =
    Make_single_data_storage (Registered) (Raw_context)
      (struct
        let name = ["listings_size"]
      end)
      (Int32)

  module Listings =
    Make_indexed_data_storage
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["listings"]
         end))
         (Make_index (Signature.Public_key_hash))
         (Int32)

  module Proposals =
    Make_data_set_storage
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["proposals"]
         end))
         (Pair
            (Make_index
               (Protocol_hash))
               (Make_index (Signature.Public_key_hash)))

  module Proposals_count =
    Make_indexed_data_storage
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["proposals_count"]
         end))
         (Make_index (Signature.Public_key_hash))
         (Int)

  module Ballots =
    Make_indexed_data_storage
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["ballots"]
         end))
         (Make_index (Signature.Public_key_hash))
         (struct
           type t = Vote_repr.ballot

           let encoding = Vote_repr.ballot_encoding
         end)
end

(** Seed *)

module Seed = struct
  type unrevealed_nonce = Cycle.unrevealed_nonce = {
    nonce_hash : Nonce_hash.t;
    delegate : Signature.Public_key_hash.t;
    rewards : Tez_repr.t;
    fees : Tez_repr.t;
  }

  type nonce_status = Cycle.nonce_status =
    | Unrevealed of unrevealed_nonce
    | Revealed of Seed_repr.nonce

  module Nonce = struct
    open Level_repr

    type context = Raw_context.t

    let mem ctxt l = Cycle.Nonce.mem (ctxt, l.cycle) l.level

    let get ctxt l = Cycle.Nonce.get (ctxt, l.cycle) l.level

    let get_option ctxt l = Cycle.Nonce.get_option (ctxt, l.cycle) l.level

    let set ctxt l v = Cycle.Nonce.set (ctxt, l.cycle) l.level v

    let init ctxt l v = Cycle.Nonce.init (ctxt, l.cycle) l.level v

    let init_set ctxt l v = Cycle.Nonce.init_set (ctxt, l.cycle) l.level v

    let set_option ctxt l v = Cycle.Nonce.set_option (ctxt, l.cycle) l.level v

    let delete ctxt l = Cycle.Nonce.delete (ctxt, l.cycle) l.level

    let remove ctxt l = Cycle.Nonce.remove (ctxt, l.cycle) l.level
  end

  module For_cycle = Cycle.Seed
end

(** Commitments *)

module Commitments =
  Make_indexed_data_storage
    (Make_subcontext (Registered) (Raw_context)
       (struct
         let name = ["commitments"]
       end))
       (Make_index (Blinded_public_key_hash.Index))
       (Tez_repr)

(** Ramp up security deposits... *)

module Ramp_up = struct
  module Rewards =
    Make_indexed_data_storage
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["ramp_up"; "rewards"]
         end))
         (Make_index (Cycle_repr.Index))
         (struct
           type t = Tez_repr.t list * Tez_repr.t list

           let encoding =
             Data_encoding.(
               obj2
                 (req "baking_reward_per_endorsement" (list Tez_repr.encoding))
                 (req "endorsement_reward" (list Tez_repr.encoding)))
         end)

  module Security_deposits =
    Make_indexed_data_storage
      (Make_subcontext (Registered) (Raw_context)
         (struct
           let name = ["ramp_up"; "deposits"]
         end))
         (Make_index (Cycle_repr.Index))
         (struct
           type t = Tez_repr.t * Tez_repr.t

           let encoding =
             Data_encoding.tup2 Tez_repr.encoding Tez_repr.encoding
         end)
end
