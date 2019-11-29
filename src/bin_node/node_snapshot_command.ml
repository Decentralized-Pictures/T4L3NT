(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018 Nomadic Labs. <nomadic@tezcore.com>                    *)
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

open Node_logging

let ( // ) = Filename.concat

let context_dir data_dir = data_dir // "context"

let store_dir data_dir = data_dir // "store"

type error += Invalid_sandbox_file of string

let () =
  register_error_kind
    `Permanent
    ~id:"main.snapshots.invalid_sandbox_file"
    ~title:"Invalid sandbox file"
    ~description:"The provided sandbox file is not a valid sandbox JSON file."
    ~pp:(fun ppf s ->
      Format.fprintf ppf "The file '%s' is not a valid JSON sandbox file" s)
    Data_encoding.(obj1 (req "sandbox_file" string))
    (function Invalid_sandbox_file s -> Some s | _ -> None)
    (fun s -> Invalid_sandbox_file s)

(** Main *)

module Term = struct
  type subcommand = Export | Import

  let dir_cleaner data_dir =
    lwt_log_notice "Cleaning directory %s because of failure" data_dir
    >>= fun () ->
    Lwt_utils_unix.remove_dir @@ store_dir data_dir
    >>= fun () -> Lwt_utils_unix.remove_dir @@ context_dir data_dir

  let process subcommand args snapshot_file block export_rolling reconstruct
      sandbox_file =
    let run =
      Internal_event_unix.init ()
      >>= fun () ->
      Node_shared_arg.read_data_dir args
      >>=? fun data_dir ->
      let genesis = Genesis_chain.genesis in
      match subcommand with
      | Export ->
          Node_data_version.ensure_data_dir data_dir
          >>=? fun () ->
          let context_root = context_dir data_dir in
          let store_root = store_dir data_dir in
          Store.init store_root
          >>=? fun store ->
          Context.init ~readonly:true context_root
          >>= fun context_index ->
          Snapshots.export
            ~export_rolling
            ~context_index
            ~store
            ~genesis:genesis.block
            snapshot_file
            block
          >>=? fun () -> Store.close store |> return
      | Import ->
          Node_data_version.ensure_data_dir ~bare:true data_dir
          >>=? fun () ->
          Lwt_lock_file.create
            ~unlink_on_exit:true
            (Node_data_version.lock_file data_dir)
          >>=? fun () ->
          Option.unopt_map
            ~default:return_none
            ~f:(fun filename ->
              Lwt_utils_unix.Json.read_file filename
              >>= function
              | Error _err ->
                  fail (Invalid_sandbox_file filename)
              | Ok json ->
                  return_some ("sandbox_parameter", json))
            sandbox_file
          >>=? fun sandbox_parameters ->
          let patch_context = Patch_context.patch_context sandbox_parameters in
          Snapshots.import
            ~reconstruct
            ~patch_context
            ~data_dir
            ~dir_cleaner
            ~genesis
            snapshot_file
            block
    in
    match Lwt_main.run run with
    | Ok () ->
        `Ok ()
    | Error err ->
        `Error (false, Format.asprintf "%a" pp_print_error err)

  let subcommand_arg =
    let parser = function
      | "export" ->
          `Ok Export
      | "import" ->
          `Ok Import
      | s ->
          `Error ("invalid argument: " ^ s)
    and printer ppf = function
      | Export ->
          Format.fprintf ppf "export"
      | Import ->
          Format.fprintf ppf "import"
    in
    let open Cmdliner.Arg in
    let doc =
      "Operation to perform. Possible values: $(b,export), $(b,import)."
    in
    required
    & pos 0 (some (parser, printer)) None
    & info [] ~docv:"OPERATION" ~doc

  let file_arg =
    let open Cmdliner.Arg in
    required & pos 1 (some string) None & info [] ~docv:"FILE"

  let blocks =
    let open Cmdliner.Arg in
    let doc = "Block hash of the block to export/import." in
    value & opt (some string) None & info ~docv:"<block_hash>" ~doc ["block"]

  let export_rolling =
    let open Cmdliner in
    let doc =
      "Force export command to dump a minimal snapshot based on the rolling \
       mode."
    in
    Arg.(
      value & flag
      & info ~docs:Node_shared_arg.Manpage.misc_section ~doc ["rolling"])

  let reconstruct =
    let open Cmdliner in
    let doc =
      "Start a storage reconstruction from a full mode snapshot to an archive \
       storage. This operation can be quite long."
    in
    Arg.(
      value & flag
      & info ~docs:Node_shared_arg.Manpage.misc_section ~doc ["reconstruct"])

  let sandbox =
    let open Cmdliner in
    let doc =
      "Run the snapshot import in sandbox mode. P2P to non-localhost \
       addresses are disabled, and constants of the economic protocol can be \
       altered with an optional JSON file. $(b,IMPORTANT): Using sandbox mode \
       affects the node state and subsequent runs of Tezos node must also use \
       sandbox mode. In order to run the node in normal mode afterwards, a \
       full reset must be performed (by removing the node's data directory)."
    in
    Arg.(
      value
      & opt (some non_dir_file) None
      & info
          ~docs:Node_shared_arg.Manpage.misc_section
          ~doc
          ~docv:"FILE.json"
          ["sandbox"])

  let term =
    let open Cmdliner.Term in
    ret
      ( const process $ subcommand_arg $ Node_shared_arg.Term.args $ file_arg
      $ blocks $ export_rolling $ reconstruct $ sandbox )
end

module Manpage = struct
  let command_description =
    "The $(b,snapshot) command is meant to export and import snapshots files."

  let description =
    [ `S "DESCRIPTION";
      `P (command_description ^ " Several operations are possible: ");
      `P
        "$(b,export) allows to export a snapshot of the current node state \
         into a file.";
      `P "$(b,import) allows to import a snapshot from a given file." ]

  let options = [`S "OPTIONS"]

  let examples =
    [ `S "EXAMPLES";
      `I
        ( "$(b,Export a snapshot using the rolling mode)",
          "$(mname) snapshot export latest.rolling --rolling" );
      `I
        ( "$(b,Import a snapshot located in file.full)",
          "$(mname) snapshot import file.full" );
      `I
        ( "$(b,Import a full mode snapshot and then reconstruct the whole \
           storage to obtain an archive mode storage)",
          "$(mname) snapshot import file.full --reconstruct" ) ]

  let man = description @ options @ examples @ Node_shared_arg.Manpage.bugs

  let info = Cmdliner.Term.info ~doc:"Manage snapshots" ~man "snapshot"
end

let cmd = (Term.term, Manpage.info)
