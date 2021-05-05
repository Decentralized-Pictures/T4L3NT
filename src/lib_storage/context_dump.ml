(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018-2020 Nomadic Labs. <contact@nomadic-labs.com>          *)
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

include Context_dump_intf

let current_version = "tezos-snapshot-1.1.0"

(* A set of versions that may be restored *)
let compatible_versions = [current_version; "tezos-snapshot-1.0.0"]

(*****************************************************************************)
let () =
  let open Data_encoding in
  register_error_kind
    `Permanent
    ~id:"Writing_error"
    ~title:"Writing error"
    ~description:"Cannot write in file for context dump"
    ~pp:(fun ppf s ->
      Format.fprintf ppf "Unable to write file for context dumping: %s" s)
    (obj1 (req "context_dump_no_space" string))
    (function System_write_error s -> Some s | _ -> None)
    (fun s -> System_write_error s) ;
  register_error_kind
    `Permanent
    ~id:"Bad_hash"
    ~title:"Bad hash"
    ~description:"Wrong hash given"
    ~pp:(fun ppf (ty, his, hshould) ->
      Format.fprintf
        ppf
        "Wrong hash [%s] given: %s, should be %s"
        ty
        (Bytes.to_string his)
        (Bytes.to_string hshould))
    (obj3
       (req "hash_ty" string)
       (req "hash_is" bytes)
       (req "hash_should" bytes))
    (function
      | Bad_hash (ty, his, hshould) -> Some (ty, his, hshould) | _ -> None)
    (fun (ty, his, hshould) -> Bad_hash (ty, his, hshould)) ;
  register_error_kind
    `Permanent
    ~id:"Context_not_found"
    ~title:"Context not found"
    ~description:"Cannot find context corresponding to hash"
    ~pp:(fun ppf mb ->
      Format.fprintf ppf "No context with hash: %s" (Bytes.to_string mb))
    (obj1 (req "context_not_found" bytes))
    (function Context_not_found mb -> Some mb | _ -> None)
    (fun mb -> Context_not_found mb) ;
  register_error_kind
    `Permanent
    ~id:"System_read_error"
    ~title:"System read error"
    ~description:"Failed to read file"
    ~pp:(fun ppf uerr ->
      Format.fprintf
        ppf
        "Error while reading file for context dumping: %s"
        uerr)
    (obj1 (req "system_read_error" string))
    (function System_read_error e -> Some e | _ -> None)
    (fun e -> System_read_error e) ;
  register_error_kind
    `Permanent
    ~id:"Inconsistent_snapshot_file"
    ~title:"Inconsistent snapshot file"
    ~description:"Error while opening snapshot file"
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Failed to read snapshot file. The provided file is inconsistent.")
    empty
    (function Inconsistent_snapshot_file -> Some () | _ -> None)
    (fun () -> Inconsistent_snapshot_file) ;
  register_error_kind
    `Permanent
    ~id:"Inconsistent_snapshot_data"
    ~title:"Inconsistent snapshot data"
    ~description:"The data provided by the snapshot is inconsistent"
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "The data provided by the snapshot file is inconsistent (context_hash \
         does not correspond for block).")
    empty
    (function Inconsistent_snapshot_data -> Some () | _ -> None)
    (fun () -> Inconsistent_snapshot_data) ;
  register_error_kind
    `Permanent
    ~id:"Missing_snapshot_data"
    ~title:"Missing data in imported snapshot"
    ~description:"Mandatory data missing while reaching end of snapshot file."
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "Mandatory data is missing is the provided snapshot file.")
    empty
    (function Missing_snapshot_data -> Some () | _ -> None)
    (fun () -> Missing_snapshot_data) ;
  register_error_kind
    `Permanent
    ~id:"Invalid_snapshot_version"
    ~title:"Invalid snapshot version"
    ~description:"The version of the snapshot to import is not valid"
    ~pp:(fun ppf (found, expected) ->
      Format.fprintf
        ppf
        "The snapshot to import has version \"%s\" but one of %a was expected."
        found
        Format.(
          pp_print_list
            ~pp_sep:(fun ppf () -> fprintf ppf ", ")
            (fun ppf version -> fprintf ppf "\"%s\"" version))
        expected)
    (obj2 (req "found" string) (req "expected" (list string)))
    (function
      | Invalid_snapshot_version (found, expected) ->
          Some (found, expected)
      | _ ->
          None)
    (fun (found, expected) -> Invalid_snapshot_version (found, expected)) ;
  register_error_kind
    `Permanent
    ~id:"Restore_context_failure"
    ~title:"Failed to restore context"
    ~description:"Internal error while restoring the context"
    ~pp:(fun ppf () ->
      Format.fprintf ppf "Internal error while restoring the context.")
    empty
    (function Restore_context_failure -> Some () | _ -> None)
    (fun () -> Restore_context_failure)

module Make (I : Dump_interface) = struct
  type command =
    | Root of {
        block_header : I.Block_header.t;
        info : I.commit_info;
        parents : I.Commit_hash.t list;
        block_data : I.Block_data.t;
        pred_block_metadata_hash : Block_metadata_hash.t option;
        pred_ops_metadata_hashes : Operation_metadata_hash.t list list option;
      }
    | Node of (string * I.hash) list
    | Blob of bytes
    | Proot of I.Pruned_block.t
    | Loot of I.Protocol_data.t
    | End

  (* Command encoding. *)

  let blob_encoding =
    let open Data_encoding in
    case
      ~title:"blob"
      (Tag (Char.code 'b'))
      bytes
      (function Blob b -> Some b | _ -> None)
      (function b -> Blob b)

  let node_encoding =
    let open Data_encoding in
    case
      ~title:"node"
      (Tag (Char.code 'd'))
      (list (obj2 (req "name" string) (req "hash" I.hash_encoding)))
      (function Node x -> Some x | _ -> None)
      (function x -> Node x)

  let end_encoding =
    let open Data_encoding in
    case
      ~title:"end"
      (Tag (Char.code 'e'))
      empty
      (function End -> Some () | _ -> None)
      (fun () -> End)

  let loot_encoding =
    let open Data_encoding in
    case
      ~title:"loot"
      (Tag (Char.code 'l'))
      I.Protocol_data.encoding
      (function Loot protocol_data -> Some protocol_data | _ -> None)
      (fun protocol_data -> Loot protocol_data)

  let loot_encoding_1_0_0 =
    let open Data_encoding in
    case
      ~title:"loot"
      (Tag (Char.code 'l'))
      I.Protocol_data.encoding_1_0_0
      (function Loot protocol_data -> Some protocol_data | _ -> None)
      (fun protocol_data -> Loot protocol_data)

  let proot_encoding =
    let open Data_encoding in
    case
      ~title:"proot"
      (Tag (Char.code 'p'))
      (obj1 (req "pruned_block" I.Pruned_block.encoding))
      (function Proot pruned_block -> Some pruned_block | _ -> None)
      (fun pruned_block -> Proot pruned_block)

  let root_encoding =
    let open Data_encoding in
    case
      ~title:"root"
      (Tag (Char.code 'r'))
      (obj6
         (opt "pred_block_metadata_hash" Block_metadata_hash.encoding)
         (opt
            "pred_ops_metadata_hashes"
            (list (list Operation_metadata_hash.encoding)))
         (req "block_header" (dynamic_size I.Block_header.encoding))
         (req "info" I.commit_info_encoding)
         (req "parents" (list I.Commit_hash.encoding))
         (req "block_data" I.Block_data.encoding))
      (function
        | Root
            { pred_block_metadata_hash;
              pred_ops_metadata_hashes;
              block_header;
              info;
              parents;
              block_data } ->
            Some
              ( pred_block_metadata_hash,
                pred_ops_metadata_hashes,
                block_header,
                info,
                parents,
                block_data )
        | _ ->
            None)
      (fun ( pred_block_metadata_hash,
             pred_ops_metadata_hashes,
             block_header,
             info,
             parents,
             block_data ) ->
        Root
          {
            pred_block_metadata_hash;
            pred_ops_metadata_hashes;
            block_header;
            info;
            parents;
            block_data;
          })

  (* This version (1.0.0) doesn't include the optional fields
     [pred_block_metadata_hash] and [pred_ops_metadata_hashes], but we can still
     restore this version by setting these to [None]. *)
  let root_encoding_1_0_0 =
    let open Data_encoding in
    case
      ~title:"root"
      (Tag (Char.code 'r'))
      (obj4
         (req "block_header" (dynamic_size I.Block_header.encoding))
         (req "info" I.commit_info_encoding)
         (req "parents" (list I.Commit_hash.encoding))
         (req "block_data" I.Block_data.encoding))
      (function
        | Root
            { pred_block_metadata_hash = _;
              pred_ops_metadata_hashes = _;
              block_header;
              info;
              parents;
              block_data } ->
            Some (block_header, info, parents, block_data)
        | _ ->
            None)
      (fun (block_header, info, parents, block_data) ->
        Root
          {
            pred_block_metadata_hash = None;
            pred_ops_metadata_hashes = None;
            block_header;
            info;
            parents;
            block_data;
          })

  let command_encoding =
    Data_encoding.union
      ~tag_size:`Uint8
      [ blob_encoding;
        node_encoding;
        end_encoding;
        loot_encoding;
        proot_encoding;
        root_encoding ]

  let command_encoding_1_0_0 =
    Data_encoding.union
      ~tag_size:`Uint8
      [ blob_encoding;
        node_encoding;
        end_encoding;
        loot_encoding_1_0_0;
        proot_encoding;
        root_encoding_1_0_0 ]

  (* IO toolkit. *)

  let rec read_string rbuf ~len =
    let (fd, buf, ofs, total) = !rbuf in
    if Bytes.length buf - ofs < len then (
      let blen = Bytes.length buf - ofs in
      let neu = Bytes.create (blen + 1_000_000) in
      Bytes.blit buf ofs neu 0 blen ;
      Lwt_unix.read fd neu blen 1_000_000
      >>= fun bread ->
      total := !total + bread ;
      if bread = 0 then fail Inconsistent_snapshot_file
      else
        let neu =
          if bread <> 1_000_000 then Bytes.sub neu 0 (blen + bread) else neu
        in
        rbuf := (fd, neu, 0, total) ;
        read_string rbuf ~len )
    else
      let res = Bytes.sub_string buf ofs len in
      rbuf := (fd, buf, ofs + len, total) ;
      return res

  let read_mbytes rbuf b =
    read_string rbuf ~len:(Bytes.length b)
    >>=? fun string ->
    Bytes.blit_string string 0 b 0 (Bytes.length b) ;
    return ()

  let set_int64 buf i =
    let b = Bytes.create 8 in
    EndianBytes.BigEndian.set_int64 b 0 i ;
    Buffer.add_bytes buf b

  let get_int64 rbuf =
    read_string ~len:8 rbuf
    >>=? fun s -> return @@ EndianString.BigEndian.get_int64 s 0

  let set_mbytes buf b =
    set_int64 buf (Int64.of_int (Bytes.length b)) ;
    Buffer.add_bytes buf b

  let get_mbytes rbuf =
    get_int64 rbuf >|=? Int64.to_int
    >>=? fun l ->
    let b = Bytes.create l in
    read_mbytes rbuf b >>=? fun () -> return b

  (* Getter and setters *)

  let get_command encoding rbuf =
    get_mbytes rbuf
    >|=? fun bytes -> Data_encoding.Binary.of_bytes_exn encoding bytes

  let set_root buf block_header info parents block_data
      pred_block_metadata_hash pred_ops_metadata_hashes =
    let root =
      Root
        {
          block_header;
          info;
          parents;
          block_data;
          pred_block_metadata_hash;
          pred_ops_metadata_hashes;
        }
    in
    let bytes = Data_encoding.Binary.to_bytes_exn command_encoding root in
    set_mbytes buf bytes

  let set_tree buf tree =
    (match tree with `Branch node -> Node node | `Leaf blob -> Blob blob)
    |> Data_encoding.Binary.to_bytes_exn command_encoding
    |> set_mbytes buf

  let set_proot buf pruned_block =
    let proot = Proot pruned_block in
    let bytes = Data_encoding.Binary.to_bytes_exn command_encoding proot in
    set_mbytes buf bytes

  let set_loot buf protocol_data =
    let loot = Loot protocol_data in
    let bytes = Data_encoding.Binary.to_bytes_exn command_encoding loot in
    set_mbytes buf bytes

  let set_end buf =
    let bytes = Data_encoding.Binary.to_bytes_exn command_encoding End in
    set_mbytes buf bytes

  (* Snapshot metadata *)

  (* TODO add more info (e.g. nb context item, nb blocks, etc.) *)
  type snapshot_metadata = {
    version : string;
    mode : Tezos_shell_services.History_mode.t;
  }

  let snapshot_metadata_encoding =
    let open Data_encoding in
    conv
      (fun {version; mode} -> (version, mode))
      (fun (version, mode) -> {version; mode})
      (obj2
         (req "version" string)
         (req "mode" Tezos_shell_services.History_mode.encoding))

  let write_snapshot_metadata ~mode buf =
    let version = {version = current_version; mode} in
    let bytes =
      Data_encoding.(Binary.to_bytes_exn snapshot_metadata_encoding version)
    in
    set_mbytes buf bytes

  let read_snapshot_metadata rbuf =
    get_mbytes rbuf
    >|=? fun bytes ->
    Data_encoding.(Binary.of_bytes_exn snapshot_metadata_encoding) bytes

  let check_version v =
    fail_when
      (List.mem v.version compatible_versions |> not)
      (Invalid_snapshot_version (v.version, compatible_versions))

  let serialize_tree ~maybe_flush ~written buf =
    I.tree_iteri_unique (fun visited sub_tree ->
        set_tree buf sub_tree ;
        maybe_flush ()
        >|= fun () ->
        Tezos_stdlib_unix.Utils.display_progress
          ~refresh_rate:(visited, 1_000)
          (fun m ->
            m
              "Context: %dK elements, %dMiB written%!"
              (visited / 1_000)
              (written () / 1_048_576)))

  let dump_contexts_fd idx data ~fd =
    (* Dumping *)
    let buf = Buffer.create 1_000_000 in
    let written = ref 0 in
    let flush () =
      let contents = Buffer.contents buf in
      Buffer.clear buf ;
      written := !written + String.length contents ;
      Lwt_utils_unix.write_string fd contents
    in
    let maybe_flush () =
      if Buffer.length buf > 1_000_000 then flush () else Lwt.return_unit
    in
    Lwt.catch
      (fun () ->
        let ( bh,
              block_data,
              pred_block_metadata_hash,
              pred_ops_metadata_hashes,
              mode,
              pruned_iterator ) =
          data
        in
        write_snapshot_metadata ~mode buf ;
        I.get_context idx bh
        >>= function
        | None ->
            fail @@ Context_not_found (I.Block_header.to_bytes bh)
        | Some ctxt ->
            I.context_tree ctxt
            |> serialize_tree ~maybe_flush ~written:(fun () -> !written) buf
            >>= fun () ->
            Tezos_stdlib_unix.Utils.display_progress_end () ;
            let parents = I.context_parents ctxt in
            set_root
              buf
              bh
              (I.context_info ctxt)
              parents
              block_data
              pred_block_metadata_hash
              pred_ops_metadata_hashes ;
            (* Dump pruned blocks *)
            let dump_pruned cpt pruned =
              Tezos_stdlib_unix.Utils.display_progress
                ~refresh_rate:(cpt, 1_000)
                (fun m ->
                  m
                    "History: %dK block, %dMiB written"
                    (cpt / 1_000)
                    (!written / 1_048_576)) ;
              set_proot buf pruned ;
              maybe_flush ()
            in
            let rec aux cpt acc header =
              pruned_iterator header
              >>=? function
              | (None, None) ->
                  return acc (* assert false *)
              | (None, Some protocol_data) ->
                  return (protocol_data :: acc)
              | (Some pred_pruned, Some protocol_data) ->
                  dump_pruned cpt pred_pruned
                  >>= fun () ->
                  aux
                    (succ cpt)
                    (protocol_data :: acc)
                    (I.Pruned_block.header pred_pruned)
              | (Some pred_pruned, None) ->
                  dump_pruned cpt pred_pruned
                  >>= fun () ->
                  aux (succ cpt) acc (I.Pruned_block.header pred_pruned)
            in
            let starting_block_header = I.Block_data.header block_data in
            aux 0 [] starting_block_header
            >>=? fun protocol_datas ->
            (* Dump protocol data *)
            List.iter_s
              (fun proto -> set_loot buf proto ; maybe_flush ())
              protocol_datas
            >>= fun () ->
            Tezos_stdlib_unix.Utils.display_progress_end () ;
            return_unit
            >>=? fun () ->
            set_end buf ;
            flush () >>= fun () -> return_unit)
      (function
        | Unix.Unix_error (e, _, _) ->
            fail @@ System_write_error (Unix.error_message e)
        | err ->
            Lwt.fail err)

  (* Restoring *)

  let restore_contexts_fd index ~fd k_store_pruned_blocks block_validation =
    let read = ref 0 in
    let rbuf = ref (fd, Bytes.empty, 0, read) in
    (* Editing the repository *)
    let add_blob t blob = I.add_bytes t blob >>= fun tree -> return tree in
    let add_dir t keys =
      I.add_dir t keys
      >>= function
      | None -> fail Restore_context_failure | Some tree -> return tree
    in
    let restore version =
      let encoding =
        if version.version = "tezos-snapshot-1.0.0" then command_encoding_1_0_0
        else command_encoding
      in
      let history_mode = version.mode in
      let rec first_pass batch ctxt cpt =
        Tezos_stdlib_unix.Utils.display_progress
          ~refresh_rate:(cpt, 1_000)
          (fun m ->
            m
              "Context: %dK elements, %dMiB read"
              (cpt / 1_000)
              (!read / 1_048_576)) ;
        get_command encoding rbuf
        >>=? function
        | Root
            { block_header;
              info;
              parents;
              block_data;
              pred_block_metadata_hash;
              pred_ops_metadata_hashes } -> (
            I.set_context ~info ~parents ctxt block_header
            >>= function
            | None ->
                fail Inconsistent_snapshot_data
            | Some block_header ->
                return
                  ( block_header,
                    block_data,
                    pred_block_metadata_hash,
                    pred_ops_metadata_hashes ) )
        | Node contents ->
            add_dir batch contents
            >>=? fun tree ->
            first_pass batch (I.update_context ctxt tree) (cpt + 1)
        | Blob data ->
            add_blob batch data
            >>=? fun tree ->
            first_pass batch (I.update_context ctxt tree) (cpt + 1)
        | _ ->
            fail Inconsistent_snapshot_data
      in
      let rec second_pass pred_header (rev_block_hashes, protocol_datas) todo
          cpt =
        Tezos_stdlib_unix.Utils.display_progress
          ~refresh_rate:(cpt, 1_000)
          (fun m ->
            m
              "Store: %dK elements, %dMiB read"
              (cpt / 1_000)
              (!read / 1_048_576)) ;
        get_command encoding rbuf
        >>=? function
        | Proot pruned_block ->
            let header = I.Pruned_block.header pruned_block in
            let hash = Block_header.hash header in
            block_validation pred_header hash pruned_block
            >>=? fun () ->
            if (cpt + 1) mod 5_000 = 0 then
              k_store_pruned_blocks ((hash, pruned_block) :: todo)
              >>=? fun () ->
              second_pass
                (Some header)
                (hash :: rev_block_hashes, protocol_datas)
                []
                (cpt + 1)
            else
              second_pass
                (Some header)
                (hash :: rev_block_hashes, protocol_datas)
                ((hash, pruned_block) :: todo)
                (cpt + 1)
        | Loot protocol_data ->
            k_store_pruned_blocks todo
            >>=? fun () ->
            second_pass
              pred_header
              (rev_block_hashes, protocol_data :: protocol_datas)
              todo
              (cpt + 1)
        | End ->
            return (pred_header, rev_block_hashes, List.rev protocol_datas)
        | _ ->
            fail Inconsistent_snapshot_data
      in
      I.batch index (fun batch -> first_pass batch (I.make_context index) 0)
      >>=? fun ( block_header,
                 block_data,
                 pred_block_metadata_hash,
                 pred_ops_metadata_hashes ) ->
      Tezos_stdlib_unix.Utils.display_progress_end () ;
      second_pass None ([], []) [] 0
      >>=? fun (oldest_header_opt, rev_block_hashes, protocol_datas) ->
      Tezos_stdlib_unix.Utils.display_progress_end () ;
      return
        ( block_header,
          block_data,
          pred_block_metadata_hash,
          pred_ops_metadata_hashes,
          history_mode,
          oldest_header_opt,
          rev_block_hashes,
          protocol_datas )
    in
    Lwt.catch
      (fun () ->
        (* Check snapshot version *)
        read_snapshot_metadata rbuf
        >>=? fun version ->
        check_version version >>=? fun () -> restore version)
      (function
        | Unix.Unix_error (e, _, _) ->
            fail (System_read_error (Unix.error_message e))
        | Invalid_argument _ ->
            fail Inconsistent_snapshot_file
        | err ->
            Lwt.fail err)
end
