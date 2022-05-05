(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

module Selected_distribution_for_cycle = struct
  module Cache_client = struct
    type cached_value = (Signature.Public_key_hash.t * Tez_repr.t) list

    let namespace = Cache_repr.create_namespace "stake_distribution"

    let cache_index = 1

    let value_of_identifier ctxt identifier =
      let cycle = Cycle_repr.of_string_exn identifier in
      Storage.Stake.Selected_distribution_for_cycle.get ctxt cycle
  end

  module Cache = (val Cache_repr.register_exn (module Cache_client))

  let identifier_of_cycle cycle = Format.asprintf "%a" Cycle_repr.pp cycle

  let init ctxt cycle stakes =
    let id = identifier_of_cycle cycle in
    Storage.Stake.Selected_distribution_for_cycle.init ctxt cycle stakes
    >>=? fun ctxt ->
    let size = 1 (* that's symbolic: 1 cycle = 1 entry *) in
    Cache.update ctxt id (Some (stakes, size)) >>?= fun ctxt -> return ctxt

  let get ctxt cycle =
    let id = identifier_of_cycle cycle in
    Cache.find ctxt id >>=? function
    | None -> Storage.Stake.Selected_distribution_for_cycle.get ctxt cycle
    | Some v -> return v

  let remove_existing ctxt cycle =
    let id = identifier_of_cycle cycle in
    Cache.update ctxt id None >>?= fun ctxt ->
    Storage.Stake.Selected_distribution_for_cycle.remove_existing ctxt cycle
end

let get_staking_balance = Storage.Stake.Staking_balance.get

let get_initialized_stake ctxt delegate =
  Storage.Stake.Staking_balance.find ctxt delegate >>=? function
  | Some staking_balance -> return (staking_balance, ctxt)
  | None ->
      Frozen_deposits_storage.init ctxt delegate >>=? fun ctxt ->
      let balance = Tez_repr.zero in
      Storage.Stake.Staking_balance.init ctxt delegate balance >>=? fun ctxt ->
      return (balance, ctxt)

let remove_stake ctxt delegate amount =
  get_initialized_stake ctxt delegate >>=? fun (staking_balance_before, ctxt) ->
  Tez_repr.(staking_balance_before -? amount) >>?= fun staking_balance ->
  Storage.Stake.Staking_balance.update ctxt delegate staking_balance
  >>=? fun ctxt ->
  let tokens_per_roll = Constants_storage.tokens_per_roll ctxt in
  if Tez_repr.(staking_balance_before >= tokens_per_roll) then
    Delegate_activation_storage.is_inactive ctxt delegate >>=? fun inactive ->
    if (not inactive) && Tez_repr.(staking_balance < tokens_per_roll) then
      Storage.Stake.Active_delegate_with_one_roll.remove ctxt delegate
      >>= fun ctxt -> return ctxt
    else return ctxt
  else
    (* The delegate was not in Stake.Active_delegate_with_one_roll,
       either because it was inactive, or because it did not have a
       roll, in which case it still does not have a roll. *)
    return ctxt

let add_stake ctxt delegate amount =
  get_initialized_stake ctxt delegate >>=? fun (staking_balance_before, ctxt) ->
  Tez_repr.(amount +? staking_balance_before) >>?= fun staking_balance ->
  Storage.Stake.Staking_balance.update ctxt delegate staking_balance
  >>=? fun ctxt ->
  let tokens_per_roll = Constants_storage.tokens_per_roll ctxt in
  if Tez_repr.(staking_balance >= tokens_per_roll) then
    Delegate_activation_storage.is_inactive ctxt delegate >>=? fun inactive ->
    if inactive || Tez_repr.(staking_balance_before >= tokens_per_roll) then
      return ctxt
    else
      Storage.Stake.Active_delegate_with_one_roll.add ctxt delegate ()
      >>= fun ctxt -> return ctxt
  else
    (* The delegate was not in Stake.Active_delegate_with_one_roll,
       because it did not have a roll (as otherwise it would have a
       roll now). *)
    return ctxt

let deactivate_only_call_from_delegate_storage ctxt delegate =
  Storage.Stake.Active_delegate_with_one_roll.remove ctxt delegate

let activate_only_call_from_delegate_storage ctxt delegate =
  get_initialized_stake ctxt delegate >>=? fun (staking_balance, ctxt) ->
  let tokens_per_roll = Constants_storage.tokens_per_roll ctxt in
  if Tez_repr.(staking_balance >= tokens_per_roll) then
    Storage.Stake.Active_delegate_with_one_roll.add ctxt delegate ()
    >>= fun ctxt -> return ctxt
  else return ctxt

let snapshot ctxt =
  Storage.Stake.Last_snapshot.get ctxt >>=? fun index ->
  Storage.Stake.Last_snapshot.update ctxt (index + 1) >>=? fun ctxt ->
  Storage.Stake.Staking_balance.snapshot ctxt index >>=? fun ctxt ->
  Storage.Stake.Active_delegate_with_one_roll.snapshot ctxt index

let max_snapshot_index = Storage.Stake.Last_snapshot.get

let set_selected_distribution_for_cycle ctxt cycle stakes total_stake =
  let stakes = List.sort (fun (_, x) (_, y) -> Tez_repr.compare y x) stakes in
  Selected_distribution_for_cycle.init ctxt cycle stakes >>=? fun ctxt ->
  Storage.Total_active_stake.add ctxt cycle total_stake >>= fun ctxt ->
  (* cleanup snapshots *)
  Storage.Stake.Staking_balance.Snapshot.clear ctxt >>= fun ctxt ->
  Storage.Stake.Active_delegate_with_one_roll.Snapshot.clear ctxt
  >>= fun ctxt -> Storage.Stake.Last_snapshot.update ctxt 0

let clear_cycle ctxt cycle =
  Storage.Total_active_stake.remove_existing ctxt cycle >>=? fun ctxt ->
  Selected_distribution_for_cycle.remove_existing ctxt cycle

let fold ctxt ~f ~order init =
  Storage.Stake.Active_delegate_with_one_roll.fold
    ctxt
    ~order
    ~init:(Ok init)
    ~f:(fun delegate () acc ->
      acc >>?= fun acc ->
      get_staking_balance ctxt delegate >>=? fun stake ->
      f (delegate, stake) acc)

let fold_snapshot ctxt ~index ~f ~init =
  Storage.Stake.Active_delegate_with_one_roll.fold_snapshot
    ctxt
    index
    ~order:`Sorted
    ~init
    ~f:(fun delegate () acc ->
      Storage.Stake.Staking_balance.Snapshot.get ctxt (index, delegate)
      >>=? fun stake -> f (delegate, stake) acc)

let clear_at_cycle_end ctxt ~new_cycle =
  let max_slashing_period = Constants_storage.max_slashing_period ctxt in
  match Cycle_repr.sub new_cycle max_slashing_period with
  | None -> return ctxt
  | Some cycle_to_clear -> clear_cycle ctxt cycle_to_clear

let get ctxt delegate =
  Storage.Stake.Active_delegate_with_one_roll.mem ctxt delegate >>= function
  | true -> get_staking_balance ctxt delegate
  | false -> return Tez_repr.zero

let fold_on_active_delegates_with_rolls =
  Storage.Stake.Active_delegate_with_one_roll.fold

let get_selected_distribution = Selected_distribution_for_cycle.get

let find_selected_distribution =
  Storage.Stake.Selected_distribution_for_cycle.find

let prepare_stake_distribution ctxt =
  let level = Level_storage.current ctxt in
  Selected_distribution_for_cycle.get ctxt level.cycle >>=? fun stakes ->
  let stake_distribution =
    List.fold_left
      (fun map (pkh, stake) -> Signature.Public_key_hash.Map.add pkh stake map)
      Signature.Public_key_hash.Map.empty
      stakes
  in
  return
    (Raw_context.init_stake_distribution_for_current_cycle
       ctxt
       stake_distribution)

let get_total_active_stake = Storage.Total_active_stake.get

let remove_contract_stake ctxt contract amount =
  Contract_delegate_storage.find ctxt contract >>=? function
  | None -> return ctxt
  | Some delegate -> remove_stake ctxt delegate amount

let add_contract_stake ctxt contract amount =
  Contract_delegate_storage.find ctxt contract >>=? function
  | None -> return ctxt
  | Some delegate -> add_stake ctxt delegate amount
