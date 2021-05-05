(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018-2020 Nomadic Labs <contact@nomadic-labs.com>           *)
(* Copyright (c) 2018-2020 Tarides <contact@tarides.com>                     *)
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

(** Tezos - Versioned (key x value) store (over Irmin) *)

open Tezos_storage_encoding.Context

let reporter () =
  let report src level ~over k msgf =
    let k _ = over () ; k () in
    let with_stamp h _tags k fmt =
      let dt = Mtime.Span.to_us (Mtime_clock.elapsed ()) in
      Fmt.kpf
        k
        Fmt.stderr
        ("%+04.0fus %a %a @[" ^^ fmt ^^ "@]@.")
        dt
        Fmt.(styled `Magenta string)
        (Logs.Src.name src)
        Logs_fmt.pp_header
        (level, h)
    in
    msgf @@ fun ?header ?tags fmt -> with_stamp header tags k fmt
  in
  {Logs.report}

let index_log_size = ref None

let () =
  let verbose () =
    Logs.set_level (Some Logs.Debug) ;
    Logs.set_reporter (reporter ())
  in
  let index_log_size n = index_log_size := Some (int_of_string n) in
  match Unix.getenv "TEZOS_STORAGE" with
  | exception Not_found ->
      ()
  | v ->
      let args = String.split ',' v in
      List.iter
        (function
          | "v" | "verbose" | "vv" ->
              verbose ()
          | v -> (
            match String.split '=' v with
            | ["index-log-size"; n] ->
                index_log_size n
            | _ ->
                () ))
        args

module Conf = struct
  let entries = 32

  let stable_hash = 256
end

module Store =
  Irmin_pack.Make_ext
    (struct
      let io_version = `V1
    end)
    (Conf)
    (Metadata)
    (Contents)
    (Path)
    (Branch)
    (Hash)
    (Node)
    (Commit)

module P = Store.Private

type index = {
  path : string;
  repo : Store.Repo.t;
  patch_context : (context -> context tzresult Lwt.t) option;
  readonly : bool;
}

and context = {index : index; parents : Store.Commit.t list; tree : Store.tree}

type t = context

module type S = Tezos_storage_sigs.Context.S

(*-- Version Access and Update -----------------------------------------------*)

let current_protocol_key = ["protocol"]

let current_test_chain_key = ["test_chain"]

let current_data_key = ["data"]

let current_predecessor_block_metadata_hash_key =
  ["predecessor_block_metadata_hash"]

let current_predecessor_ops_metadata_hash_key =
  ["predecessor_ops_metadata_hash"]

let restore_integrity ?ppf index =
  match Store.integrity_check ?ppf ~auto_repair:true index.repo with
  | Ok (`Fixed n) ->
      Ok (Some n)
  | Ok `No_error ->
      Ok None
  | Error (`Cannot_fix msg) ->
      error (failure "%s" msg)
  | Error (`Corrupted n) ->
      error
        (failure
           "unable to fix the corrupted context: %d bad entries detected"
           n)

let sync index =
  if index.readonly then Store.sync index.repo ;
  Lwt.return ()

let exists index key =
  sync index
  >>= fun () ->
  Store.Commit.of_hash index.repo (Hash.of_context_hash key)
  >|= function None -> false | Some _ -> true

let checkout index key =
  sync index
  >>= fun () ->
  Store.Commit.of_hash index.repo (Hash.of_context_hash key)
  >>= function
  | None ->
      Lwt.return_none
  | Some commit ->
      let tree = Store.Commit.tree commit in
      let ctxt = {index; tree; parents = [commit]} in
      Lwt.return_some ctxt

let checkout_exn index key =
  checkout index key
  >>= function None -> Lwt.fail Not_found | Some p -> Lwt.return p

(* unshallow possible 1-st level objects from previous partial
   checkouts ; might be better to pass directly the list of shallow
   objects. *)
let unshallow context =
  Store.Tree.list context.tree []
  >>= fun children ->
  P.Repo.batch context.index.repo (fun x y _ ->
      List.iter_s
        (fun (s, k) ->
          match Store.Tree.destruct k with
          | `Contents _ ->
              Lwt.return ()
          | `Node _ ->
              Store.Tree.get_tree context.tree [s]
              >>= fun tree ->
              Store.save_tree ~clear:true context.index.repo x y tree
              >|= fun _ -> ())
        children)

let raw_commit ~time ?(message = "") context =
  let info =
    Irmin.Info.v ~date:(Time.Protocol.to_seconds time) ~author:"Tezos" message
  in
  let parents = List.map Store.Commit.hash context.parents in
  unshallow context
  >>= fun () ->
  Store.Commit.v context.index.repo ~info ~parents context.tree
  >|= fun h ->
  Store.Tree.clear context.tree ;
  h

let hash ~time ?(message = "") context =
  let info =
    Irmin.Info.v ~date:(Time.Protocol.to_seconds time) ~author:"Tezos" message
  in
  let parents = List.map (fun c -> Store.Commit.hash c) context.parents in
  let node = Store.Tree.hash context.tree in
  let commit = P.Commit.Val.v ~parents ~node ~info in
  let x = P.Commit.Key.hash commit in
  Hash.to_context_hash x

let commit ~time ?message context =
  raw_commit ~time ?message context
  >|= fun commit -> Hash.to_context_hash (Store.Commit.hash commit)

(*-- Generic Store Primitives ------------------------------------------------*)

let data_key key = current_data_key @ key

type key = string list

type value = bytes

type tree = Store.tree

module Tree = Tezos_storage_helpers.Context.Make_tree (Store)

let mem ctxt key = Tree.mem ctxt.tree (data_key key)

let mem_tree ctxt key = Tree.mem_tree ctxt.tree (data_key key)

let raw_find ctxt key = Tree.find ctxt.tree key

let list ctxt ?offset ?length key =
  Tree.list ctxt.tree ?offset ?length (data_key key)

let find ctxt key = raw_find ctxt (data_key key)

let raw_add ctxt key data =
  Tree.add ctxt.tree key data >|= fun tree -> {ctxt with tree}

let add ctxt key data = raw_add ctxt (data_key key) data

let raw_remove ctxt k =
  Tree.remove ctxt.tree k >|= fun tree -> {ctxt with tree}

let remove ctxt key = raw_remove ctxt (data_key key)

let find_tree ctxt key = Tree.find_tree ctxt.tree (data_key key)

let add_tree ctxt key tree =
  Tree.add_tree ctxt.tree (data_key key) tree >|= fun tree -> {ctxt with tree}

let fold ?depth ctxt key ~init ~f =
  Tree.fold ?depth ctxt.tree (data_key key) ~init ~f

(*-- Predefined Fields -------------------------------------------------------*)

let get_protocol v =
  raw_find v current_protocol_key
  >>= function
  | None ->
      assert false
  | Some data ->
      Lwt.return (Protocol_hash.of_bytes_exn data)

let add_protocol v key =
  let key = Protocol_hash.to_bytes key in
  raw_add v current_protocol_key key

let get_test_chain v =
  raw_find v current_test_chain_key
  >>= function
  | None ->
      Lwt.fail (Failure "Unexpected error (Context.get_test_chain)")
  | Some data -> (
    match Data_encoding.Binary.of_bytes Test_chain_status.encoding data with
    | Error re ->
        Format.kasprintf
          (fun s -> Lwt.fail (Failure s))
          "Error in Context.get_test_chain: %a"
          Data_encoding.Binary.pp_read_error
          re
    | Ok r ->
        Lwt.return r )

let add_test_chain v id =
  let id = Data_encoding.Binary.to_bytes_exn Test_chain_status.encoding id in
  raw_add v current_test_chain_key id

let remove_test_chain v = raw_remove v current_test_chain_key

let fork_test_chain v ~protocol ~expiration =
  add_test_chain v (Forking {protocol; expiration})

let find_predecessor_block_metadata_hash v =
  raw_find v current_predecessor_block_metadata_hash_key
  >>= function
  | None ->
      Lwt.return_none
  | Some data -> (
    match
      Data_encoding.Binary.of_bytes_opt Block_metadata_hash.encoding data
    with
    | None ->
        Lwt.fail
          (Failure
             "Unexpected error (Context.get_predecessor_block_metadata_hash)")
    | Some r ->
        Lwt.return_some r )

let add_predecessor_block_metadata_hash v hash =
  let data =
    Data_encoding.Binary.to_bytes_exn Block_metadata_hash.encoding hash
  in
  raw_add v current_predecessor_block_metadata_hash_key data

let find_predecessor_ops_metadata_hash v =
  raw_find v current_predecessor_ops_metadata_hash_key
  >>= function
  | None ->
      Lwt.return_none
  | Some data -> (
    match
      Data_encoding.Binary.of_bytes_opt
        Operation_metadata_list_list_hash.encoding
        data
    with
    | None ->
        Lwt.fail
          (Failure
             "Unexpected error (Context.get_predecessor_ops_metadata_hash)")
    | Some r ->
        Lwt.return_some r )

let add_predecessor_ops_metadata_hash v hash =
  let data =
    Data_encoding.Binary.to_bytes_exn
      Operation_metadata_list_list_hash.encoding
      hash
  in
  raw_add v current_predecessor_ops_metadata_hash_key data

(*-- Initialisation ----------------------------------------------------------*)

let init ?patch_context ?mapsize:_ ?(readonly = false) root =
  Store.Repo.v
    (Irmin_pack.config ~readonly ?index_log_size:!index_log_size root)
  >|= fun repo -> {path = root; repo; patch_context; readonly}

let close index = Store.Repo.close index.repo

let get_branch chain_id = Format.asprintf "%a" Chain_id.pp chain_id

let commit_genesis index ~chain_id ~time ~protocol =
  let tree = Store.Tree.empty in
  let ctxt = {index; tree; parents = []} in
  ( match index.patch_context with
  | None ->
      return ctxt
  | Some patch_context ->
      patch_context ctxt )
  >>=? fun ctxt ->
  add_protocol ctxt protocol
  >>= fun ctxt ->
  add_test_chain ctxt Not_running
  >>= fun ctxt ->
  raw_commit ~time ~message:"Genesis" ctxt
  >>= fun commit ->
  Store.Branch.set index.repo (get_branch chain_id) commit
  >>= fun () -> return (Hash.to_context_hash (Store.Commit.hash commit))

let compute_testchain_chain_id genesis =
  let genesis_hash = Block_hash.hash_bytes [Block_hash.to_bytes genesis] in
  Chain_id.of_block_hash genesis_hash

let compute_testchain_genesis forked_block =
  let genesis = Block_hash.hash_bytes [Block_hash.to_bytes forked_block] in
  genesis

let commit_test_chain_genesis ctxt (forked_header : Block_header.t) =
  let message =
    Format.asprintf "Forking testchain at level %ld." forked_header.shell.level
  in
  raw_commit ~time:forked_header.shell.timestamp ~message ctxt
  >>= fun commit ->
  let faked_shell_header : Block_header.shell_header =
    {
      forked_header.shell with
      proto_level = succ forked_header.shell.proto_level;
      predecessor = Block_hash.zero;
      validation_passes = 0;
      operations_hash = Operation_list_list_hash.empty;
      context = Hash.to_context_hash (Store.Commit.hash commit);
    }
  in
  let forked_block = Block_header.hash forked_header in
  let genesis_hash = compute_testchain_genesis forked_block in
  let chain_id = compute_testchain_chain_id genesis_hash in
  let genesis_header : Block_header.t =
    {
      shell = {faked_shell_header with predecessor = genesis_hash};
      protocol_data = Bytes.create 0;
    }
  in
  let branch = get_branch chain_id in
  Store.Branch.set ctxt.index.repo branch commit
  >>= fun () -> Lwt.return genesis_header

let clear_test_chain index chain_id =
  (* TODO remove commits... ??? *)
  let branch = get_branch chain_id in
  Store.Branch.remove index.repo branch

let set_head index chain_id commit =
  let branch = get_branch chain_id in
  Store.Commit.of_hash index.repo (Hash.of_context_hash commit)
  >>= function
  | None ->
      assert false
  | Some commit ->
      Store.Branch.set index.repo branch commit

let set_master index commit =
  Store.Commit.of_hash index.repo (Hash.of_context_hash commit)
  >>= function
  | None ->
      assert false
  | Some commit ->
      Store.Branch.set index.repo Store.Branch.master commit

(* Context dumping *)

module Pruned_block = struct
  type t = {
    block_header : Block_header.t;
    operations : (int * Operation.t list) list;
    operation_hashes : (int * Operation_hash.t list) list;
  }

  let encoding =
    let open Data_encoding in
    conv
      (fun {block_header; operations; operation_hashes} ->
        (operations, operation_hashes, block_header))
      (fun (operations, operation_hashes, block_header) ->
        {block_header; operations; operation_hashes})
      (obj3
         (req
            "operations"
            (list (tup2 int31 (list (dynamic_size Operation.encoding)))))
         (req
            "operation_hashes"
            (list (tup2 int31 (list (dynamic_size Operation_hash.encoding)))))
         (req "block_header" Block_header.encoding))

  let to_bytes pruned_block =
    Data_encoding.Binary.to_bytes_exn encoding pruned_block

  let of_bytes pruned_block =
    Data_encoding.Binary.of_bytes_opt encoding pruned_block

  let header {block_header; _} = block_header
end

module Block_data = struct
  type t = {block_header : Block_header.t; operations : Operation.t list list}

  let header {block_header; _} = block_header

  let encoding =
    let open Data_encoding in
    conv
      (fun {block_header; operations} -> (operations, block_header))
      (fun (operations, block_header) -> {block_header; operations})
      (obj2
         (req "operations" (list (list (dynamic_size Operation.encoding))))
         (req "block_header" Block_header.encoding))

  let to_bytes = Data_encoding.Binary.to_bytes_exn encoding

  let of_bytes = Data_encoding.Binary.of_bytes_opt encoding
end

module Protocol_data = struct
  type info = {author : string; message : string; timestamp : Time.Protocol.t}

  let info_encoding =
    let open Data_encoding in
    conv
      (fun {author; message; timestamp} -> (author, message, timestamp))
      (fun (author, message, timestamp) -> {author; message; timestamp})
      (obj3
         (req "author" string)
         (req "message" string)
         (req "timestamp" Time.Protocol.encoding))

  type data = {
    predecessor_block_metadata_hash : Block_metadata_hash.t option;
    predecessor_ops_metadata_hash : Operation_metadata_list_list_hash.t option;
    info : info;
    protocol_hash : Protocol_hash.t;
    test_chain_status : Test_chain_status.t;
    data_key : Context_hash.t;
    parents : Context_hash.t list;
  }

  let data_encoding =
    let open Data_encoding in
    conv
      (fun { predecessor_block_metadata_hash;
             predecessor_ops_metadata_hash;
             info;
             protocol_hash;
             test_chain_status;
             data_key;
             parents } ->
        ( predecessor_block_metadata_hash,
          predecessor_ops_metadata_hash,
          info,
          protocol_hash,
          test_chain_status,
          data_key,
          parents ))
      (fun ( predecessor_block_metadata_hash,
             predecessor_ops_metadata_hash,
             info,
             protocol_hash,
             test_chain_status,
             data_key,
             parents ) ->
        {
          predecessor_block_metadata_hash;
          predecessor_ops_metadata_hash;
          info;
          protocol_hash;
          test_chain_status;
          data_key;
          parents;
        })
      (obj7
         (opt "predecessor_block_metadata_hash" Block_metadata_hash.encoding)
         (opt
            "predecessor_ops_metadata_hash"
            Operation_metadata_list_list_hash.encoding)
         (req "info" info_encoding)
         (req "protocol_hash" Protocol_hash.encoding)
         (req "test_chain_status" Test_chain_status.encoding)
         (req "data_key" Context_hash.encoding)
         (req "parents" (list Context_hash.encoding)))

  (* This version didn't include the optional fields
     [predecessor_block_metadata_hash] and [predecessor_ops_metadata_hashes],
     but we can still restore this version by setting these to [None]. *)
  let data_encoding_1_0_0 =
    let open Data_encoding in
    conv
      (fun { predecessor_block_metadata_hash = _;
             predecessor_ops_metadata_hash = _;
             info;
             protocol_hash;
             test_chain_status;
             data_key;
             parents } ->
        (info, protocol_hash, test_chain_status, data_key, parents))
      (fun (info, protocol_hash, test_chain_status, data_key, parents) ->
        {
          predecessor_block_metadata_hash = None;
          predecessor_ops_metadata_hash = None;
          info;
          protocol_hash;
          test_chain_status;
          data_key;
          parents;
        })
      (obj5
         (req "info" info_encoding)
         (req "protocol_hash" Protocol_hash.encoding)
         (req "test_chain_status" Test_chain_status.encoding)
         (req "data_key" Context_hash.encoding)
         (req "parents" (list Context_hash.encoding)))

  type t = Int32.t * data

  let encoding =
    let open Data_encoding in
    tup2 int32 data_encoding

  let encoding_1_0_0 =
    let open Data_encoding in
    tup2 int32 data_encoding_1_0_0

  let to_bytes = Data_encoding.Binary.to_bytes_exn encoding

  let of_bytes = Data_encoding.Binary.of_bytes_opt encoding
end

module Dumpable_context = struct
  type nonrec index = index

  type nonrec context = context

  type tree = Store.tree

  type hash = [`Blob of Store.hash | `Node of Store.hash]

  type commit_info = Irmin.Info.t

  type batch =
    | Batch of
        Store.repo * [`Read | `Write] P.Contents.t * [`Read | `Write] P.Node.t

  let batch index f =
    P.Repo.batch index.repo (fun x y _ -> f (Batch (index.repo, x, y)))

  let commit_info_encoding =
    let open Data_encoding in
    conv
      (fun irmin_info ->
        let author = Irmin.Info.author irmin_info in
        let message = Irmin.Info.message irmin_info in
        let date = Irmin.Info.date irmin_info in
        (author, message, date))
      (fun (author, message, date) -> Irmin.Info.v ~author ~date message)
      (obj3 (req "author" string) (req "message" string) (req "date" int64))

  let hash_encoding : hash Data_encoding.t =
    let open Data_encoding in
    let kind_encoding = string_enum [("node", `Node); ("blob", `Blob)] in
    conv
      (function
        | `Blob h ->
            (`Blob, Context_hash.to_bytes (Hash.to_context_hash h))
        | `Node h ->
            (`Node, Context_hash.to_bytes (Hash.to_context_hash h)))
      (function
        | (`Blob, h) ->
            `Blob (Hash.of_context_hash (Context_hash.of_bytes_exn h))
        | (`Node, h) ->
            `Node (Hash.of_context_hash (Context_hash.of_bytes_exn h)))
      (obj2 (req "kind" kind_encoding) (req "value" bytes))

  let hash_equal (h1 : hash) (h2 : hash) = h1 = h2

  let context_parents ctxt =
    match ctxt with
    | {parents = [commit]; _} ->
        let parents = Store.Commit.parents commit in
        let parents = List.map Hash.to_context_hash parents in
        List.sort Context_hash.compare parents
    | _ ->
        assert false

  let context_info = function
    | {parents = [c]; _} ->
        Store.Commit.info c
    | _ ->
        assert false

  let get_context idx bh = checkout idx bh.Block_header.shell.context

  let set_context ~info ~parents ctxt bh =
    let parents = List.sort Context_hash.compare parents in
    let parents = List.map Hash.of_context_hash parents in
    Store.Commit.v ctxt.index.repo ~info ~parents ctxt.tree
    >>= fun c ->
    let h = Store.Commit.hash c in
    if
      Context_hash.equal bh.Block_header.shell.context (Hash.to_context_hash h)
    then Lwt.return_some bh
    else Lwt.return_none

  let context_tree ctxt = ctxt.tree

  let tree_hash tree =
    let hash = Store.Tree.hash tree in
    match Store.Tree.destruct tree with
    | `Node _ ->
        `Node hash
    | `Contents _ ->
        `Blob hash

  type binding = {
    key : string;
    value : tree;
    value_kind : [`Node | `Contents];
    value_hash : hash;
  }

  (** Unpack the bindings in a tree node (in lexicographic order) and clear its
      internal cache. *)
  let bindings tree : binding list Lwt.t =
    Store.Tree.list tree []
    >>= fun keys ->
    keys
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
    |> List.map_s (fun (key, value) ->
           Store.Tree.kind value []
           >|= function
           | None ->
               (* The value must exist in the tree, because we're
                  iterating over existing keys *)
               assert false
           | Some value_kind ->
               let value_hash = tree_hash value in
               {key; value; value_kind; value_hash})
    >|= fun bindings -> Store.Tree.clear tree ; bindings

  module Hashtbl = Hashtbl.MakeSeeded (struct
    type t = hash

    let hash = Hashtbl.seeded_hash

    let equal = hash_equal
  end)

  let tree_iteri_unique f tree =
    let total_visited = ref 0 in
    (* Noting the visited hashes *)
    let visited_hash = Hashtbl.create 1000 in
    let visited h = Hashtbl.mem visited_hash h in
    let set_visit h =
      incr total_visited ;
      Hashtbl.add visited_hash h ()
    in
    let rec aux : type a. tree -> (unit -> a) -> a Lwt.t =
     fun tree k ->
      bindings tree
      >>= List.map_s (fun {key; value; value_hash; value_kind} ->
              let kv = (key, value_hash) in
              if visited value_hash then Lwt.return kv
              else
                match value_kind with
                | `Node ->
                    (* Visit children first, in left-to-right order. *)
                    (aux [@ocaml.tailcall]) value (fun () ->
                        (* There cannot be a cycle. *)
                        set_visit value_hash ; kv)
                | `Contents ->
                    Store.Tree.get value []
                    >>= fun data ->
                    f !total_visited (`Leaf data)
                    >|= fun () -> set_visit value_hash ; kv)
      >>= fun sub_keys -> f !total_visited (`Branch sub_keys) >|= k
    in
    aux tree Fun.id

  let make_context index = {index; tree = Store.Tree.empty; parents = []}

  let update_context context tree = {context with tree}

  let add_hash (Batch (repo, _, _)) tree key hash =
    let irmin_hash =
      match hash with `Blob hash -> `Contents (hash, ()) | `Node _ as n -> n
    in
    Store.Tree.of_hash repo irmin_hash
    >>= function
    | None ->
        Lwt.return_none
    | Some t ->
        Store.Tree.add_tree tree key (t :> tree) >>= Lwt.return_some

  let add_bytes (Batch (_, t, _)) b =
    (* Save the contents in the store *)
    Store.save_contents t b >|= fun _ -> Store.Tree.of_contents b

  let add_dir batch l =
    let rec fold_list sub_tree = function
      | [] ->
          Lwt.return_some sub_tree
      | (step, hash) :: tl -> (
          add_hash batch sub_tree [step] hash
          >>= function
          | None -> Lwt.return_none | Some sub_tree -> fold_list sub_tree tl )
    in
    fold_list Store.Tree.empty l
    >>= function
    | None ->
        Lwt.return_none
    | Some tree ->
        let (Batch (repo, x, y)) = batch in
        (* Save the node in the store ... *)
        Store.save_tree ~clear:true repo x y tree >|= fun _ -> Some tree

  module Commit_hash = Context_hash
  module Block_header = Block_header
  module Block_data = Block_data
  module Pruned_block = Pruned_block
  module Protocol_data = Protocol_data
end

(* Protocol data *)

let data_node_hash context =
  Store.Tree.get_tree context.tree current_data_key
  >|= fun tree -> Hash.to_context_hash (Store.Tree.hash tree)

let get_protocol_data_from_header index block_header =
  checkout_exn index block_header.Block_header.shell.context
  >>= fun context ->
  let level = block_header.shell.level in
  let irmin_info = Dumpable_context.context_info context in
  let date = Irmin.Info.date irmin_info in
  let author = Irmin.Info.author irmin_info in
  let message = Irmin.Info.message irmin_info in
  let info =
    {Protocol_data.timestamp = Time.Protocol.of_seconds date; author; message}
  in
  let parents = Dumpable_context.context_parents context in
  get_protocol context
  >>= fun protocol_hash ->
  get_test_chain context
  >>= fun test_chain_status ->
  find_predecessor_block_metadata_hash context
  >>= fun predecessor_block_metadata_hash ->
  find_predecessor_ops_metadata_hash context
  >>= fun predecessor_ops_metadata_hash ->
  data_node_hash context
  >>= fun data_key ->
  Lwt.return
    ( level,
      {
        predecessor_block_metadata_hash;
        predecessor_ops_metadata_hash;
        Protocol_data.parents;
        protocol_hash;
        test_chain_status;
        data_key;
        info;
      } )

let validate_context_hash_consistency_and_commit ~data_hash
    ~expected_context_hash ~timestamp ~test_chain ~protocol_hash ~message
    ~author ~parents ~predecessor_block_metadata_hash
    ~predecessor_ops_metadata_hash ~index =
  let data_hash = Hash.of_context_hash data_hash in
  let parents = List.map Hash.of_context_hash parents in
  let protocol_value = Protocol_hash.to_bytes protocol_hash in
  let test_chain_value =
    Data_encoding.Binary.to_bytes_exn Test_chain_status.encoding test_chain
  in
  let tree = Store.Tree.empty in
  Store.Tree.add tree current_protocol_key protocol_value
  >>= fun tree ->
  Store.Tree.add tree current_test_chain_key test_chain_value
  >>= fun tree ->
  ( match predecessor_block_metadata_hash with
  | Some predecessor_block_metadata_hash ->
      let predecessor_block_metadata_hash_value =
        Block_metadata_hash.to_bytes predecessor_block_metadata_hash
      in
      Store.Tree.add
        tree
        current_predecessor_block_metadata_hash_key
        predecessor_block_metadata_hash_value
  | None ->
      Lwt.return tree )
  >>= fun tree ->
  ( match predecessor_ops_metadata_hash with
  | Some predecessor_ops_metadata_hash ->
      let predecessor_ops_metadata_hash_value =
        Operation_metadata_list_list_hash.to_bytes
          predecessor_ops_metadata_hash
      in
      Store.Tree.add
        tree
        current_predecessor_ops_metadata_hash_key
        predecessor_ops_metadata_hash_value
  | None ->
      Lwt.return tree )
  >>= fun tree ->
  let info =
    Irmin.Info.v ~date:(Time.Protocol.to_seconds timestamp) ~author message
  in
  let data_tree = Store.Tree.shallow index.repo (`Node data_hash) in
  Store.Tree.add_tree tree current_data_key data_tree
  >>= fun node ->
  let node = Store.Tree.hash node in
  let commit = P.Commit.Val.v ~parents ~node ~info in
  let computed_context_hash =
    Hash.to_context_hash (P.Commit.Key.hash commit)
  in
  if Context_hash.equal expected_context_hash computed_context_hash then
    let ctxt =
      let parent = Store.of_private_commit index.repo commit in
      {index; tree = Store.Tree.empty; parents = [parent]}
    in
    add_test_chain ctxt test_chain
    >>= fun ctxt ->
    add_protocol ctxt protocol_hash
    >>= fun ctxt ->
    ( match predecessor_block_metadata_hash with
    | Some predecessor_block_metadata_hash ->
        add_predecessor_block_metadata_hash
          ctxt
          predecessor_block_metadata_hash
    | None ->
        Lwt.return ctxt )
    >>= fun ctxt ->
    ( match predecessor_ops_metadata_hash with
    | Some predecessor_ops_metadata_hash ->
        add_predecessor_ops_metadata_hash ctxt predecessor_ops_metadata_hash
    | None ->
        Lwt.return ctxt )
    >>= fun ctxt ->
    let data_t = Store.Tree.shallow index.repo (`Node data_hash) in
    Store.Tree.add_tree ctxt.tree current_data_key data_t
    >>= fun new_tree ->
    Store.Commit.v ctxt.index.repo ~info ~parents new_tree
    >|= fun commit ->
    let ctxt_h = Hash.to_context_hash (Store.Commit.hash commit) in
    Context_hash.equal ctxt_h expected_context_hash
  else Lwt.return_false

(* Context dumper *)

module Context_dumper = Context_dump.Make (Dumpable_context)
include Context_dumper

(* provides functions dump_contexts and restore_contexts *)

type error += Cannot_create_file of string

let () =
  register_error_kind
    `Permanent
    ~id:"context_dump.write.cannot_open"
    ~title:"Cannot open file for context dump"
    ~description:""
    ~pp:(fun ppf uerr ->
      Format.fprintf
        ppf
        "@[Error while opening file for context dumping: %s@]"
        uerr)
    Data_encoding.(obj1 (req "context_dump_cannot_open" string))
    (function Cannot_create_file e -> Some e | _ -> None)
    (fun e -> Cannot_create_file e)

type error += Cannot_open_file of string

let () =
  register_error_kind
    `Permanent
    ~id:"context_dump.read.cannot_open"
    ~title:"Cannot open file for context restoring"
    ~description:""
    ~pp:(fun ppf uerr ->
      Format.fprintf
        ppf
        "@[Error while opening file for context restoring: %s@]"
        uerr)
    Data_encoding.(obj1 (req "context_restore_cannot_open" string))
    (function Cannot_open_file e -> Some e | _ -> None)
    (fun e -> Cannot_open_file e)

type error += Suspicious_file of int

let () =
  register_error_kind
    `Permanent
    ~id:"context_dump.read.suspicious"
    ~title:"Suspicious file: data after end"
    ~description:""
    ~pp:(fun ppf uerr ->
      Format.fprintf
        ppf
        "@[Remaining bytes in file after context restoring: %d@]"
        uerr)
    Data_encoding.(obj1 (req "context_restore_suspicious" int31))
    (function Suspicious_file e -> Some e | _ -> None)
    (fun e -> Suspicious_file e)

let dump_contexts idx datas ~filename =
  let file_init () =
    Lwt_unix.openfile
      filename
      Lwt_unix.[O_WRONLY; O_CREAT; O_TRUNC; O_CLOEXEC]
      0o666
    >>= return
  in
  Lwt.catch file_init (function
      | Unix.Unix_error (e, _, _) ->
          fail @@ Cannot_create_file (Unix.error_message e)
      | exc ->
          let msg =
            Printf.sprintf "unknown error: %s" (Printexc.to_string exc)
          in
          fail (Cannot_create_file msg))
  >>=? fun fd -> dump_contexts_fd idx datas ~fd

let restore_contexts idx ~filename k_store_pruned_block pipeline_validation =
  let file_init () =
    Lwt_unix.openfile filename Lwt_unix.[O_RDONLY; O_CLOEXEC] 0o600 >>= return
  in
  Lwt.catch file_init (function
      | Unix.Unix_error (e, _, _) ->
          fail @@ Cannot_open_file (Unix.error_message e)
      | exc ->
          let msg =
            Printf.sprintf "unknown error: %s" (Printexc.to_string exc)
          in
          fail (Cannot_open_file msg))
  >>=? fun fd ->
  Lwt.finalize
    (fun () ->
      restore_contexts_fd idx ~fd k_store_pruned_block pipeline_validation
      >>=? fun result ->
      Lwt_unix.lseek fd 0 Lwt_unix.SEEK_CUR
      >>= fun current ->
      Lwt_unix.fstat fd
      >>= fun stats ->
      let total = stats.Lwt_unix.st_size in
      if current = total then return result
      else fail @@ Suspicious_file (total - current))
    (fun () -> Lwt_unix.close fd)

let upgrade_0_0_3 ~context_dir =
  Lwt_unix.file_exists (context_dir ^ "/" ^ "data.mdb")
  (* We assume that the data.mdb file is representative of a lmdb context *)
  >>= fun is_lmdb ->
  Lwt_unix.file_exists (context_dir ^ "/" ^ "store.pack")
  (* We assume that the store.pack file is representative of an irmin context *)
  >>= fun is_irmin ->
  match (is_lmdb, is_irmin) with
  | (true, true) ->
      Format.printf
        "Your directory contains both the LMDB and Irmin2 chain's data. From \
         now, the node only uses Irmin2. LMDB data can be safely removed. To \
         do so, delete the following files: %s/data.mdb and %s/lock.mdb@."
        context_dir
        context_dir ;
      return_unit
  | (true, false) ->
      failwith
        "Your directory contains the lmdb database which cannot be handled \
         with this version of the node. Please upgrade to the new irmin \
         storage.@.A guide to upgrade toward the new storage can be found \
         here: http://tezos.gitlab.io/releases/october-2019.html"
  | (false, true) ->
      return_unit
  | (false, false) ->
      failwith
        "Cannot find any context data in the provided directory (located at: \
         %s). Please make sure that the path to the storage is correct."
        context_dir
