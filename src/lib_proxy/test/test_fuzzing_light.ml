(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs <contact@nomadic-labs.com>                *)
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

(** Testing

    -------
    Component:    Client
    Invocation:   dune build @src/lib_proxy/runtest_fuzzing_light
    Dependencies: src/lib_proxy/test/light_lib.ml
                  src/lib_proxy/test/test_light.ml
    Description:  Most generators in this module are recursive / nested, hence
                  width and depth of structures is fine-tuned.
*)

module Internal = Tezos_proxy.Light_internal
module Merkle = Internal.Merkle
module Store = Tezos_context_memory.Context
open Lib_test.Qcheck_helpers

(** [list1_arb arb] generates non-empty lists using [arb]. *)
let list1_arb arb =
  QCheck.(
    list_of_size Gen.(1 -- 100) arb
    |> add_shrink_invariant (fun l -> List.length l > 0))

let raw_context_arb =
  let open Tezos_shell_services.Block_services in
  let module MapArb = MakeMapArb (TzString.Map) in
  let open QCheck in
  let {gen = bytes_gen; shrink = bytes_shrink_opt; _} = bytes_arb in
  let gen =
    let open Gen in
    (* Factor used to limit the depth of the tree. *)
    let max_depth_factor = 10 in
    fix
      (fun self current_depth_factor ->
        frequency
          [
            (max_depth_factor, map (fun b -> Key b) bytes_gen);
            (max_depth_factor, pure Cut);
            ( current_depth_factor,
              map
                (fun d -> Dir d)
                (MapArb.gen_of_size
                   (0 -- 10)
                   string
                   (self (current_depth_factor / 2))) );
          ])
      max_depth_factor
  in
  let rec shrink =
    let open Iter in
    function
    | Cut -> empty
    | Key bigger_bytes ->
        shrink Cut
        <+> ( of_option_shrink bytes_shrink_opt bigger_bytes
            >|= fun smaller_bytes -> Key smaller_bytes )
    | Dir bigger_raw_context_map ->
        shrink Cut <+> shrink (Key Bytes.empty)
        <+> ( MapArb.shrink
                ~key:Shrink.string
                ~value:shrink
                bigger_raw_context_map
            >|= fun smaller_dir -> Dir smaller_dir )
  in
  let print = Format.asprintf "%a" pp_raw_context in
  make ~print ~shrink gen

let irmin_hash_arb = QCheck.oneofl ~print:Fun.id Light_lib.irmin_hashes

let merkle_node_arb =
  let open Tezos_shell_services.Block_services in
  let module MapArb = MakeMapArb (TzString.Map) in
  let open QCheck in
  let open Gen in
  let {gen = raw_context_gen; shrink = raw_context_shrink_opt; _} =
    raw_context_arb
  in
  let {gen = irmin_hash_gen; _} = irmin_hash_arb in
  let gen =
    let max_depth_factor = 4 in
    fix
      (fun self current_depth_factor ->
        frequency
          [
            ( max_depth_factor,
              map
                (fun (kind, hash) -> Hash (kind, hash))
                (pair (oneofl [Contents; Node]) irmin_hash_gen) );
            ( max_depth_factor,
              map (fun raw_context -> Data raw_context) raw_context_gen );
            ( current_depth_factor,
              map
                (fun merkle_node_map -> Continue merkle_node_map)
                (MapArb.gen_of_size
                   (0 -- 10)
                   string
                   (self (current_depth_factor / 2))) );
          ])
      max_depth_factor
  in
  let first_irmin_hash =
    List.hd Light_lib.irmin_hashes |> function
    | None -> assert false
    | Some hash -> hash
  in
  let rec shrink =
    let open Iter in
    function
    | Hash _ -> empty
    | Data bigger_raw_context ->
        shrink (Hash (Contents, first_irmin_hash))
        <+> ( of_option_shrink raw_context_shrink_opt bigger_raw_context
            >|= fun smaller_raw_context -> Data smaller_raw_context )
    | Continue bigger_mnode ->
        shrink (Hash (Contents, first_irmin_hash))
        <+> shrink (Data Cut)
        <+> ( MapArb.shrink ~key:Shrink.string ~value:shrink bigger_mnode
            >|= fun smaller_mnode -> Continue smaller_mnode )
  in
  let print = Format.asprintf "%a" pp_merkle_node in
  make ~print ~shrink gen

let merkle_tree_arb =
  let open MakeMapArb (TzString.Map) in
  arb_of_size QCheck.Gen.(0 -- 10) QCheck.string merkle_node_arb

let irmin_tree_arb =
  let module StringList = struct
    type t = string list

    let compare = Stdlib.compare
  end in
  let module StringListMap = Stdlib.Map.Make (StringList) in
  let open MakeMapArb (StringListMap) in
  let open QCheck in
  map
    ~rev:(fun tree ->
      Store.Tree.fold tree [] ~init:[] ~f:(fun path sub_tree acc ->
          Store.Tree.to_value sub_tree >|= function
          | None -> acc
          | Some bytes -> (path, bytes) :: acc)
      |> Lwt_main.run)
    (fun entries ->
      List.fold_left_s
        (fun built_tree (path, bytes) -> Store.Tree.add built_tree path bytes)
        (Store.Tree.empty Store.empty)
        entries
      |> Lwt_main.run)
    (small_list (pair (small_list string) bytes_arb))

let get_ok = function Ok x -> x | Error s -> QCheck.Test.fail_report s

(** Test that [merkle_tree_to_irmin_tree] preserves the tree's structure
    by checking that it yields the same [simple_tree]
    as when using [merkle_tree_to_simple_tree]
  *)
let test_merkle_tree_to_irmin_tree_preserves_simple_tree =
  QCheck.Test.make
    ~name:
      "merkle_tree_to_irmin_tree mtree |> irmin_tree_to_simple_tree = \
       merkle_tree_to_simple_tree mtree"
    merkle_tree_arb
  @@ fun mtree ->
  let repo = Lwt_main.run (Store.Tree.make_repo ()) in
  let merkle_irmin_tree =
    Lwt_main.run @@ Merkle.merkle_tree_to_irmin_tree repo mtree |> get_ok
  in
  let of_irmin_tree =
    Lwt_main.run @@ Light_lib.irmin_tree_to_simple_tree merkle_irmin_tree
  in
  (* Because Irmin does not add empty subtrees, [merkle_tree_to_irmin_tree]
     removes empty subtrees internally. We simulate the same behavior
     before calling [merkle_tree_to_simple_tree] (that doesn't go through
     Irmin APIs, and hence doesn't remove empty subtrees internally). *)
  let of_merkle_tree =
    Light_lib.merkle_tree_to_simple_tree @@ Light_lib.merkle_tree_rm_empty mtree
  in
  Light_lib.check_simple_tree_eq of_irmin_tree of_merkle_tree

let filter_none : 'a option list -> 'a list = List.filter_map Fun.id

let rec remove_data_in_node =
  let open Tezos_shell_services.Block_services in
  function
  | Hash _ as x -> Some x
  | Data _ -> None
  | Continue mtree ->
      let mtree' = remove_data_in_tree mtree in
      if TzString.Map.is_empty mtree' then None else Some (Continue mtree')

and remove_data_in_tree mtree =
  let pairs = TzString.Map.bindings mtree in
  let pairs' = Light_lib.Bifunctor.second remove_data_in_node pairs in
  let lift_opt (x, y_opt) =
    match y_opt with None -> None | Some y -> Some (x, y)
  in
  let pairs'' = List.map lift_opt pairs' |> filter_none in
  List.to_seq pairs'' |> TzString.Map.of_seq

(** Test that translating a [merkle_tree] to an Irmin tree yields
    an Irmin tree that is included in the original [merkle_tree].
    This function specifically tests function [merkle_tree_to_irmin_tree]. *)
let test_contains_merkle_tree =
  QCheck.Test.make
    ~name:"contains_merkle_tree (merkle_tree_to_irmin_tree mtree) mtree = true"
    merkle_tree_arb
  @@ fun mtree ->
  (* Because contains_merkle_tree doesn't support Data nodes, we need to
     remove them. That's because contains_merkle_tree is only called
     during the consensus phase, in which there should not be Data nodes
     (there should only be hashes). *)
  let mtree = remove_data_in_tree mtree in
  let repo = Lwt_main.run (Store.Tree.make_repo ()) in
  let irmin_tree =
    Lwt_main.run @@ Merkle.merkle_tree_to_irmin_tree repo mtree |> get_ok
  in
  let contains_res =
    Lwt_main.run @@ Merkle.contains_merkle_tree irmin_tree mtree
  in
  match contains_res with
  | Ok _ -> true
  | Error msg -> QCheck.Test.fail_report msg

(** Test that unioning an empty irmin tree and a merkle tree should yield
    the same irmin tree as if it was built directly from the merkle tree *)
let test_union_irmin_empty =
  QCheck.Test.make
    ~name:
      "union_irmin_tree_merkle_tree empty mtree = merkle_tree_to_irmin_tree \
       mtree"
    merkle_tree_arb
  @@ fun mtree ->
  let repo = Lwt_main.run (Store.Tree.make_repo ()) in
  let direct_tree =
    Lwt_main.run @@ Merkle.merkle_tree_to_irmin_tree repo mtree |> get_ok
  in
  let union_tree =
    Lwt_main.run
    @@ Merkle.union_irmin_tree_merkle_tree
         repo
         (Store.Tree.empty Store.empty)
         mtree
    |> get_ok
  in
  Light_lib.check_irmin_tree_eq direct_tree union_tree

(** Test that unioning an irmin tree - built by converting a merkle tree -
    and a merkle tree, yields the merkle tree.
    Tests both [Merkle.merkle_tree_to_irmin_tree]
    and [Merkle.union_irmin_tree_merkle_tree] *)
let test_union_translation =
  QCheck.Test.make
    ~name:
      "union_irmin_tree_merkle_tree (merkle_tree_to_irmin_tree mtree) mtree = \
       merkle_tree_to_irmin_tree mtree"
    merkle_tree_arb
  @@ fun mtree ->
  let repo = Lwt_main.run (Store.Tree.make_repo ()) in
  let direct_tree =
    Lwt_main.run @@ Merkle.merkle_tree_to_irmin_tree repo mtree |> get_ok
  in
  (* union shouldn't do anything, because the irmin tree given ([direct_tree])
     already contains all content from [mtree] *)
  let id_union_tree =
    Lwt_main.run @@ Merkle.union_irmin_tree_merkle_tree repo direct_tree mtree
    |> get_ok
  in
  Light_lib.check_irmin_tree_eq direct_tree id_union_tree

let rec union_merkle_node n1 n2 =
  let open Tezos_shell_services.Block_services in
  match (n1, n2) with
  | (Hash h1, Hash h2) when h1 = h2 -> Some n1
  | (Data raw_context1, Data raw_context2) when raw_context1 = raw_context2 ->
      Some n1
  | (Continue mtree1, Continue mtree2) -> (
      match union_merkle_tree mtree1 mtree2 with
      | None -> None
      | Some u -> Some (Continue u))
  | _ -> None

and union_merkle_tree t1 t2 =
  let conflict = ref false in
  let merge =
    TzString.Map.union
      (fun _key val1 val2 ->
        let node = union_merkle_node val1 val2 in
        if Option.is_none node then conflict := true ;
        node)
      t1
      t2
  in
  if !conflict then None else Some merge

(** Test that unioning [Merkle.union_irmin_tree_merkle_tree] yields
    the same result as [union_merkle_tree]  *)
let test_union_direct =
  QCheck.Test.make
    ~name:
      "union_irmin_tree_merkle_tree (merkle_tree_to_irmin_tree mtree) mtree = \
       merkle_tree_to_irmin_tree mtree"
    (QCheck.pair merkle_tree_arb merkle_tree_arb)
  @@ fun (mtree1, mtree2) ->
  match union_merkle_tree mtree1 mtree2 with
  | None ->
      (* trees are incompatible *)
      QCheck.assume_fail ()
  | Some merkle_union ->
      let repo = Lwt_main.run (Store.Tree.make_repo ()) in
      let irmin_union1 =
        Lwt_main.run
        @@ Merkle.union_irmin_tree_merkle_tree
             repo
             (Store.Tree.empty Store.empty)
             mtree1
        |> get_ok
      in
      let irmin_union12 =
        Lwt_main.run
        @@ Merkle.union_irmin_tree_merkle_tree repo irmin_union1 mtree2
        |> get_ok
      in
      let irmin_direct =
        Lwt_main.run @@ Merkle.merkle_tree_to_irmin_tree repo merkle_union
        |> get_ok
      in
      Light_lib.check_irmin_tree_eq irmin_union12 irmin_direct

(** Test that [Merkle.union_irmin_tree_merkle_tree] commutes i.e.
    that [Merkle.union_irmin_tree_merkle_tree t1 t2] yields the same
    value as [Merkle.union_irmin_tree_merkle_tree t2 t1]. *)
let test_union_commutation =
  QCheck.Test.make
    ~name:
      "union_irmin_tree_merkle_tree (union_irmin_tree_merkle_tree empty \
       mtree1) mtree2 = union_irmin_tree_merkle_tree \
       (union_irmin_tree_merkle_tree empty mtree2) mtree1"
    (QCheck.pair merkle_tree_arb merkle_tree_arb)
  @@ fun (mtree1, mtree2) ->
  match union_merkle_tree mtree1 mtree2 with
  | None ->
      (* rule out incompatible trees *)
      QCheck.assume_fail ()
  | Some _ ->
      let repo = Lwt_main.run (Store.Tree.make_repo ()) in
      let union2 t1 t2 =
        let intermediate =
          Lwt_main.run
          @@ Merkle.union_irmin_tree_merkle_tree
               repo
               (Store.Tree.empty Store.empty)
               t1
          |> get_ok
        in
        Lwt_main.run @@ Merkle.union_irmin_tree_merkle_tree repo intermediate t2
        |> get_ok
      in
      let union_12 = union2 mtree1 mtree2 in
      let union_21 = union2 mtree2 mtree1 in
      Light_lib.check_irmin_tree_eq union_12 union_21

(** Test that unioning an irmin tree with an empty merkle tree yield
    the input irmin tree *)
let test_union_merkle_empty =
  QCheck.Test.make
    ~name:"union_irmin_tree_merkle_tree tree empty = tree"
    irmin_tree_arb
  @@ fun tree ->
  let repo = Lwt_main.run (Store.Tree.make_repo ()) in
  let res =
    Lwt_main.run
    @@ Merkle.union_irmin_tree_merkle_tree repo tree TzString.Map.empty
    |> get_ok
  in
  Light_lib.check_irmin_tree_eq tree res

(** Test that comparing the tree shape correctly ignores the key *)
let test_shape_ignores_key =
  QCheck.Test.make
    ~name:"trees_shape_match ignores the key"
    QCheck.(quad merkle_tree_arb (list string) merkle_node_arb merkle_node_arb)
  @@ fun (tree, key, node1, node2) ->
  let open Tezos_shell_services.Block_services in
  let is_continue = function Continue _ -> true | _ -> false in
  (* If both are [Continue] then they are trees with child nodes, hence
     shape comparison will fail. *)
  QCheck.assume @@ not (is_continue node1 && is_continue node2) ;
  let rec deep_add current_key value mtree =
    match current_key with
    | [last_fragment] -> TzString.Map.add last_fragment value mtree
    | hd_key :: tl_key ->
        TzString.Map.update
          hd_key
          (fun mnode_opt ->
            let subtree =
              match mnode_opt with
              | Some (Continue subtree) -> subtree
              | _ -> TzString.Map.empty
            in
            Some (Continue (deep_add tl_key value subtree)))
          mtree
    | [] -> mtree
  in
  let tree1 = deep_add key node1 tree in
  let tree2 = deep_add key node2 tree in
  let result = Internal.Merkle.trees_shape_match key tree1 tree2 in
  qcheck_eq'
    ~pp:
      Format.(
        pp_print_result
          ~ok:(fun ppf () -> Format.fprintf ppf "()")
          ~error:(pp_print_list pp_print_string))
    ~expected:(Ok ())
    ~actual:result
    ()

module HashStability = struct
  let make_tree_shallow repo tree =
    let hash = Store.Tree.hash tree in
    let data =
      match Store.Tree.kind tree with
      | `Value -> `Contents hash
      | `Tree -> `Node hash
    in
    Store.Tree.shallow repo data

  (** Sub-par pseudo-random shallower, based on the tree and sub-trees hashes.
      The resulting tree may or may not be shallowed (i.e. exactly the same as
      the input one). *)
  let rec make_partial_shallow_tree repo tree =
    if (Store.Tree.hash tree |> Context_hash.hash) mod 2 = 0 then
      (* Full shallow *)
      Lwt.return @@ make_tree_shallow repo tree
    else
      (* Maybe shallow some sub-trees *)
      Store.Tree.list tree [] >>= fun dir ->
      Lwt_list.fold_left_s
        (fun wip_tree (key, sub_tree) ->
          make_partial_shallow_tree repo sub_tree
          >>= fun partial_shallowed_sub_tree ->
          Store.Tree.add_tree wip_tree [key] partial_shallowed_sub_tree)
        tree
        dir

  (** Provides a tree and a potentially shallowed (partially, totally or not at all) equivalent tree.
      Randomization of shallowing is sub-par (based on tree hash) because
      otherwise it would be very difficult to provide shrinking. Note that
      this will no be a problem once QCheck provides integrated shrinking. *)
  let tree_and_shallow_arb =
    let open QCheck in
    let repo = Lwt_main.run (Store.Tree.make_repo ()) in
    map_keep_input
      ~print:(Format.asprintf "%a" Store.Tree.pp)
      (fun tree -> Lwt_main.run (make_partial_shallow_tree repo tree))
      irmin_tree_arb

  (** Test that replacing Irmin subtrees by their [Store.Tree.shallow]
      value leaves the top-level [Store.Tree.hash] unchanged.

      This test was also proposed to Irmin in
      https://github.com/mirage/irmin/pull/1291 *)
  let test_hash_stability =
    QCheck.Test.make
      ~name:"Shallowing trees does not change their top-level hash"
      tree_and_shallow_arb
    @@ fun (tree, shallow_tree) ->
    let hash = Store.Tree.hash tree in
    let shallow_hash = Store.Tree.hash shallow_tree in
    if Context_hash.equal hash shallow_hash then true
    else
      QCheck.Test.fail_reportf
        "@[<v 2>Equality check failed!@,\
         expected:@,\
         %a@,\
         actual:@,\
         %a@,\
         expected hash:@,\
         %a@,\
         actual hash:@,\
         %a@]"
        Store.Tree.pp
        tree
        Store.Tree.pp
        shallow_tree
        Context_hash.pp
        hash
        Context_hash.pp
        shallow_hash
end

let check_tree_eq = qcheck_eq ~pp:Store.Tree.pp ~eq:Store.Tree.equal

module AddTree = struct
  (** Test that getting a tree that was just set returns this tree.

      This test was also proposed to Irmin in
      https://github.com/mirage/irmin/pull/1291 *)
  let test_add_tree =
    let open QCheck in
    Test.make
      ~name:
        "let tree' = Store.Tree.add_tree tree key at_key in \
         Store.Tree.find_tree tree' key = at_key"
      (triple
         HashStability.tree_and_shallow_arb
         (list1_arb string)
         irmin_tree_arb)
      (fun ( ((_, tree) : _ * Store.tree),
             (key : Store.key),
             (added : Store.tree) ) ->
        let tree' = Store.Tree.add_tree tree key added |> Lwt_main.run in
        let tree_opt_set_at_key =
          Store.Tree.find_tree tree' key |> Lwt_main.run
        in
        match tree_opt_set_at_key with
        | None -> check_tree_eq (Store.Tree.empty Store.empty) added
        | Some tree_set_at_key -> check_tree_eq added tree_set_at_key)
end

module Consensus = struct
  let (chain, block) = (`Main, `Head 0)

  class mock_rpc_context : RPC_context.simple =
    object
      method call_service
          : 'm 'p 'q 'i 'o.
            (([< Resto.meth] as 'm), unit, 'p, 'q, 'i, 'o) RPC_service.t ->
            'p ->
            'q ->
            'i ->
            'o tzresult Lwt.t =
        assert false
    end

  (* In the following [mk_rogue_*] functions, there are a number
     of ways to craft rogue data. I've chosen some, more variations
     could be done; or different ones. Ideally we want as much variety
     as possible. *)

  let mk_rogue_bytes bytes =
    if Bytes.length bytes = 0 then Bytes.of_string "1234"
    else Bytes.concat bytes [bytes]

  let mk_rogue_hash str =
    let rec go = function
      | [] -> Error ()
      | h :: _ when h <> str -> Ok h
      | _ :: rest -> go rest
    in
    go Light_lib.irmin_hashes

  (* [mk_rogue_key siblings key random] returns a variant of [key] in the
     context of [key] being a dictionary key whose siblings keys are [siblings].
     In this context, we want to ensure that the returned rogue version
     of [key] differs from all members of [siblings]. Note that we don't
     guarantee that all rogue versions of all members of [siblings] differ
     from each other. This is more complex. Our version suffices because
     the caller takes care of making at most a single key rogue in
     a given list of sibling keys *)
  let mk_rogue_key siblings key random =
    let trial =
      if random = 0 then "a" else Char.chr (random mod 256) |> String.make 1
    in
    if List.mem ~equal:String.equal trial siblings || trial = key then
      String.concat "" siblings
    else trial

  let mk_rogue_key siblings key random =
    assert (not (List.mem ~equal:String.equal key siblings)) ;
    let res = mk_rogue_key siblings key random in
    assert (not (List.mem ~equal:String.equal res siblings)) ;
    assert (res <> key) ;
    res

  (** [mk_rogue_raw_context raw_context randoms] returns a variant of
      [raw_context] whose hash differ from the input [raw_context]
      (so that it's incompatible with the input data, merkle-wise) *)
  let rec mk_rogue_raw_context raw_context (rand : Random.State.t) =
    let open Tezos_shell_services.Block_services in
    match raw_context with
    | Cut -> Error ()
    | Key v -> Ok (Key (mk_rogue_bytes v))
    | Dir dir ->
        let keys = List.map fst @@ TzString.Map.bindings dir in
        let key_changed = ref false in
        let f (success, acc) (k, v) =
          if Random.State.bool rand && not !key_changed then (
            (* change key *)
            let k' =
              mk_rogue_key (List.filter (( <> ) k) keys) k
              @@ Random.State.int rand 1024
            in
            key_changed := true ;
            (true, (k', v) :: acc))
          else
            (* change value *)
            let sub = mk_rogue_raw_context v rand in
            match sub with
            | Ok v' -> (true, (k, v') :: acc)
            | Error _ -> (success, (k, v) :: acc)
        in
        let dir_len = List.length keys in
        let (success, dir') =
          Seq.fold_left f (false, []) @@ TzString.Map.to_seq dir
        in
        assert (dir_len = List.length dir') ;
        let dir' =
          List.fold_left
            (fun acc (k, v) -> TzString.Map.add k v acc)
            TzString.Map.empty
            dir'
        in
        if success then Ok (Dir dir') else Error ()

  let mk_rogue_raw_context raw_context (rand : Random.State.t) =
    let res = mk_rogue_raw_context raw_context rand in
    Result.iter (fun raw_context' -> assert (raw_context <> raw_context')) res ;
    res

  (** [mk_rogue_tree mtree rand] returns a variant of [mtree]
      that isn't compatible, merkle-wise, with [mtree].  *)
  let rec mk_rogue_tree mtree (rand : Random.State.t) =
    let f k v (success, acc) =
      match mk_rogue_node v rand with
      | Ok v' -> (true, TzString.Map.add k v' acc)
      | Error _ -> (success, TzString.Map.add k v acc)
    in
    let (success, res) =
      TzString.Map.fold f mtree (false, TzString.Map.empty)
    in
    if success then Ok res else Error ()

  and mk_rogue_node mnode (rand : Random.State.t) =
    let open Tezos_shell_services.Block_services in
    match mnode with
    | Hash (hash_kind, str) ->
        (* Interestingly, swapping the hash_kind doesn't create a rogue
           tree. *)
        mk_rogue_hash str >>? fun h' -> Ok (Hash (hash_kind, h'))
    | Data raw_context ->
        mk_rogue_raw_context raw_context rand >>? fun raw_context ->
        Ok (Data raw_context)
    | Continue dir ->
        let f k v (success, acc) =
          match mk_rogue_node v rand with
          | Ok v' -> (true, TzString.Map.add k v' acc)
          | Error _ -> (success, TzString.Map.add k v acc)
        in
        let (success, dir) =
          TzString.Map.fold f dir (false, TzString.Map.empty)
        in
        if success then Ok (Continue dir) else Error ()

  let mk_rogue_tree mtree (seed : int) =
    Random.init seed ;
    let rand = Random.get_state () in
    let i = Random.State.int rand 11 in
    assert (0 <= i && i <= 10) ;
    (* When QCheck lands (MR https://gitlab.com/tezos/tezos/-/merge_requests/2688),
       this code should be generalized to also return a totally random
       merkle_tree (as long as it differs from [mtree]). Using Crowbar,
       this is impossible, because we cannot call a generator on our own,
       and using Crowbar's map-function in this case doesn't suffice (we need
       an infinite number of random trees to make sure we have one that differs
       from [mtree]). *)
    if i == 10 && TzString.Map.(mtree <> empty) then Ok TzString.Map.empty
    else mk_rogue_tree mtree rand

  (* [mock_light_rpc mtree [(endpoint1, true); (endpoint2, false)] seed]
     returns an instance of [Tezos_proxy.Light_proto.PROTO_RPCS]
     that always returns a rogue (illegal) variant of [mtree] when querying [endpoint1],
     [mtree] when querying [endpoint2], and [None] otherwise *)
  let mock_light_rpc mtree endpoints_and_rogueness seed =
    (module struct
      (** Use physical equality on [rpc_context] because they are identical objects. *)
      let merkle_tree (pgi : Tezos_proxy.Proxy.proxy_getter_input) _ _ =
        List.assq pgi.rpc_context endpoints_and_rogueness
        |> Option.map (fun is_rogue ->
               if is_rogue then
                 match mk_rogue_tree mtree seed with
                 | Ok rogue_mtree -> rogue_mtree
                 | _ -> QCheck.assume_fail ()
               else mtree)
        |> return
    end : Tezos_proxy.Light_proto.PROTO_RPCS)

  let mock_printer () =
    let rev_logs : string list ref = ref [] in
    object
      inherit
        Tezos_client_base.Client_context.simple_printer
          (fun _channel log ->
            rev_logs := log :: !rev_logs ;
            Lwt.return_unit)

      method get_logs = List.rev !rev_logs
    end

  let print_keys l =
    let l = List.map (fun s -> "\"" ^ s ^ "\"") l in
    "[" ^ String.concat "; " l ^ "]"

  (** [test_consensus min_agreement nb_honest nb_rogue key mtree randoms consensus_expected]
      checks that a consensus run with [nb_honest] honest nodes (i.e. that return [mtree] when requesting [key]),
      [nb_rogue] rogue nodes (i.e. that falsify data with the [mk_rogue_*] functions when requesting [key])
      returns [consensus_expected]. [randoms] is used to inject randomness in the rogue behaviour. *)
  let test_consensus min_agreement nb_honest nb_rogue key mtree randoms
      consensus_expected =
    assert (nb_honest >= 0) ;
    assert (nb_rogue >= 0) ;
    (* Because the consensus algorithm expects the merkle tree not to contain
       data: *)
    let mtree = remove_data_in_tree mtree in
    let honests = List.repeat nb_honest false in
    let rogues = List.repeat nb_rogue true in
    let endpoints_and_rogueness =
      List.map
        (fun is_rogue -> (new mock_rpc_context, is_rogue))
        (honests @ rogues)
    in
    let (module Light_proto) =
      mock_light_rpc mtree endpoints_and_rogueness randoms
    in
    let module Consensus = Tezos_proxy.Light_consensus.Make (Light_proto) in
    let printer = mock_printer () in
    let repo = Lwt_main.run (Store.Tree.make_repo ()) in
    Internal.Merkle.merkle_tree_to_irmin_tree repo mtree >|= get_ok
    >>= fun tree ->
    let input : Tezos_proxy.Light_consensus.input =
      {
        printer = (printer :> Tezos_client_base.Client_context.printer);
        min_agreement;
        chain;
        block;
        key;
        mtree;
        tree;
      }
    in
    let validating_endpoints =
      List.mapi
        (fun n (endpoint, _is_rogue) ->
          let uri = Printf.sprintf "http://foobar:%d" n |> Uri.of_string in
          (uri, endpoint))
        endpoints_and_rogueness
    in
    Consensus.consensus input validating_endpoints >|= get_ok
    >>= fun consensus_reached ->
    Lwt.return
    @@ qcheck_eq ~pp:Format.pp_print_bool consensus_expected consensus_reached
end

let add_test_consensus (min_agreement, honest, rogue, consensus_expected) =
  let open QCheck in
  (* Because the node providing data always agrees, [honest] must be > 0 *)
  assert (honest > 0) ;
  (* Because we test consensus, to which the node providing data
     doesn't participate: *)
  let honest = honest - 1 in
  Test.make
    ~name:
      (Printf.sprintf
         "min_agreement=%f, honest=%d, rogue=%d consensus_expected=%b"
         min_agreement
         honest
         rogue
         consensus_expected)
    (triple merkle_tree_arb (list string) int)
  @@ fun (mtree, key, randoms) ->
  Consensus.test_consensus
    min_agreement
    honest
    rogue
    key
    mtree
    randoms
    consensus_expected
  |> Lwt_main.run

let test_consensus_spec =
  let open QCheck in
  let min_agreement_arb = 0 -- 100 in
  let honest_arb = 1 -- 1000 in
  let rogue_arb = 0 -- 1000 in
  let key_arb = list string in
  Test.make
    ~name:
      "test_consensus min_agreement honest rogue ... = min_agreeing_endpoints \
       min_agreement (honest + rogue + 1) <= honest"
    (pair
       (quad min_agreement_arb honest_arb rogue_arb key_arb)
       (pair merkle_tree_arb int))
  @@ fun ((min_agreement_int, honest, rogue, key), (mtree, seed)) ->
  assert (0 <= min_agreement_int && min_agreement_int <= 100) ;
  let min_agreement = Float.of_int min_agreement_int /. 100. in
  assert (0.0 <= min_agreement && min_agreement <= 1.0) ;
  assert (0 < honest && honest <= 1024) ;
  assert (0 <= rogue && rogue <= 1024) ;
  let consensus_expected =
    (* +1 because there's the endpoint providing data, which always agrees *)
    let honest = honest + 1 in
    let nb_endpoints = honest + rogue in
    honest
    >= Tezos_proxy.Light_consensus.min_agreeing_endpoints
         min_agreement
         nb_endpoints
  in
  Consensus.test_consensus
    min_agreement
    honest
    rogue
    key
    mtree
    seed
    consensus_expected
  |> Lwt_main.run

let () =
  Alcotest.run
    ~verbose:true
    "Mode Light"
    [
      ( "Hash stability",
        qcheck_wrap [HashStability.test_hash_stability; AddTree.test_add_tree]
      );
      ( "Consensus consistency examples",
        (* These tests are kinda superseded by the fuzzing tests
           ([test_consensus_spec]) below. However, I want to keep them for
           documentation purposes, because they provide examples. In addition,
           if tests break in the future, these ones will be easier to
           debug than the most general ones. *)
        qcheck_wrap ~rand:(Random.State.make [|348980449|])
        @@ List.map
             add_test_consensus
             [
               (* min_agreement, nb honest nodes, nb rogue nodes, consensus expected *)
               (1.0, 2, 0, true);
               (1.0, 3, 0, true);
               (1.0, 4, 0, true);
               (1.0, 2, 1, false);
               (* Next one should fail because 3*0.7 |> ceil == 3 whereas only 2 nodes agree *)
               (0.7, 2, 1, false);
               (0.7, 1, 2, false);
               (0.7, 1, 3, false);
               (0.01, 1, 1, true);
               (0.01, 1, 2, true);
               (* Passes because 0.01 *. (1 + 99) |> ceil == 1 and the node providing data is always there *)
               (0.01, 1, 99, true);
               (* But then 0.01 *. (1 + 100) |> ceil == 2: *)
               (0.01, 1, 100, false);
               (0.6, 2, 1, true);
               (0.6, 3, 1, true);
               (0.6, 4, 1, true);
               (0.6, 5, 1, true);
               (0.5, 2, 2, true);
               (0.01, 1, 2, true);
             ] );
      ("Consensus consistency", qcheck_wrap [test_consensus_spec]);
      ( "Merkle tree to Irmin tree",
        qcheck_wrap
          [
            test_merkle_tree_to_irmin_tree_preserves_simple_tree;
            test_contains_merkle_tree;
            test_union_irmin_empty;
            test_union_translation;
            test_union_direct;
            test_union_commutation;
            test_union_merkle_empty;
          ] );
      ("Tree shape validation", qcheck_wrap [test_shape_ignores_key]);
    ]
