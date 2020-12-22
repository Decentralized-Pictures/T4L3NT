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

open Filename.Infix

type t = string

let store_dir data_dir = data_dir // "store"

let context_dir data_dir = data_dir // "context"

let protocol_dir data_dir = data_dir // "protocol"

let lock_file data_dir = data_dir // "lock"

let default_identity_file_name = "identity.json"

let default_peers_file_name = "peers.json"

let default_config_file_name = "config.json"

let version_file_name = "version.json"

(* Data_version history:
 *  - 0.0.1 : original storage
 *  - 0.0.2 : never released
 *  - 0.0.3 : store upgrade (introducing history mode)
 *  - 0.0.4 : context upgrade (switching from LMDB to IRMIN v2) *)
let data_version = "0.0.4"

(* List of upgrade functions from each still supported previous
   version to the current [data_version] above. If this list grows too
   much, an idea would be to have triples (version, version,
   converter), and to sequence them dynamically instead of
   statically. *)
let upgradable_data_version =
  [ ( "0.0.3",
      fun ~data_dir ->
        Context.upgrade_0_0_3 ~context_dir:(context_dir data_dir) ) ]

let version_encoding = Data_encoding.(obj1 (req "version" string))

type error += Invalid_data_dir_version of t * t

type error += Invalid_data_dir of string

type error += Could_not_read_data_dir_version of string

type error += Could_not_write_version_file of string

type error += Data_dir_needs_upgrade of {expected : t; actual : t}

let () =
  register_error_kind
    `Permanent
    ~id:"invalidDataDir"
    ~title:"Invalid data directory"
    ~description:"The data directory cannot be accessed or created"
    ~pp:(fun ppf path ->
      Format.fprintf ppf "Invalid data directory '%s'." path)
    Data_encoding.(obj1 (req "datadir_path" string))
    (function Invalid_data_dir path -> Some path | _ -> None)
    (fun path -> Invalid_data_dir path) ;
  register_error_kind
    `Permanent
    ~id:"invalidDataDirVersion"
    ~title:"Invalid data directory version"
    ~description:"The data directory version was not the one that was expected"
    ~pp:(fun ppf (exp, got) ->
      Format.fprintf
        ppf
        "Invalid data directory version '%s' (expected '%s').@,\
         Your data directory is outdated and cannot be automatically upgraded."
        got
        exp)
    Data_encoding.(
      obj2 (req "expected_version" string) (req "actual_version" string))
    (function
      | Invalid_data_dir_version (expected, actual) ->
          Some (expected, actual)
      | _ ->
          None)
    (fun (expected, actual) -> Invalid_data_dir_version (expected, actual)) ;
  register_error_kind
    `Permanent
    ~id:"couldNotReadDataDirVersion"
    ~title:"Could not read data directory version file"
    ~description:"Data directory version file was invalid."
    Data_encoding.(obj1 (req "version_path" string))
    ~pp:(fun ppf path ->
      Format.fprintf
        ppf
        "Tried to read version file at '%s',  but the file could not be parsed."
        path)
    (function Could_not_read_data_dir_version path -> Some path | _ -> None)
    (fun path -> Could_not_read_data_dir_version path) ;
  register_error_kind
    `Permanent
    ~id:"couldNotWriteVersionFile"
    ~title:"Could not write version file"
    ~description:"Version file cannot be written."
    Data_encoding.(obj1 (req "file_path" string))
    ~pp:(fun ppf file_path ->
      Format.fprintf
        ppf
        "Tried to write version file at '%s',  but the file could not be \
         written."
        file_path)
    (function
      | Could_not_write_version_file file_path -> Some file_path | _ -> None)
    (fun file_path -> Could_not_write_version_file file_path) ;
  register_error_kind
    `Permanent
    ~id:"dataDirNeedsUpgrade"
    ~title:"The data directory needs to be upgraded"
    ~description:"The data directory needs to be upgraded"
    ~pp:(fun ppf (exp, got) ->
      Format.fprintf
        ppf
        "The data directory version is too old.@,\
         Found '%s', expected '%s'.@,\
         It needs to be upgraded with `tezos-node upgrade storage`."
        got
        exp)
    Data_encoding.(
      obj2 (req "expected_version" string) (req "actual_version" string))
    (function
      | Data_dir_needs_upgrade {expected; actual} ->
          Some (expected, actual)
      | _ ->
          None)
    (fun (expected, actual) -> Data_dir_needs_upgrade {expected; actual})

module Events = struct
  open Internal_event.Simple

  let section = ["node_data_version"]

  let dir_is_up_to_date =
    declare_0
      ~section
      ~level:Notice
      ~name:"dir_is_up_to_date"
      ~msg:"node data dir is up-to-date"
      ()

  let upgrading_node =
    declare_2
      ~section
      ~level:Notice
      ~name:"upgrading_node"
      ~msg:"upgrading data directory from {old_version} to {new_version}"
      ~pp1:Format.pp_print_string
      ("old_version", Data_encoding.string)
      ~pp2:Format.pp_print_string
      ("new_version", Data_encoding.string)

  let update_success =
    declare_0
      ~section
      ~level:Notice
      ~name:"update_success"
      ~msg:"the node data dir is now up-to-date"
      ()

  let aborting_upgrade =
    declare_1
      ~section
      ~level:Notice
      ~name:"aborting_upgrade"
      ~msg:"failed to upgrade storage: {error}"
      ~pp1:Error_monad.pp_print_error
      ("error", Error_monad.trace_encoding)

  let upgrade_status =
    declare_2
      ~section
      ~level:Notice
      ~name:"upgrade_status"
      ~msg:
        "current version: {current_version}, available version: \
         {available_version}"
      ~pp1:Format.pp_print_string
      ("current_version", Data_encoding.string)
      ~pp2:Format.pp_print_string
      ("available_version", Data_encoding.string)

  let emit = Internal_event.Simple.emit
end

let version_file data_dir = Filename.concat data_dir version_file_name

let clean_directory files =
  let to_delete =
    Format.asprintf
      "@[<v>%a@]"
      (Format.pp_print_list ~pp_sep:Format.pp_print_cut Format.pp_print_string)
      files
  in
  Format.sprintf "Please provide a clean directory by removing:@ %s" to_delete

let write_version_file data_dir =
  let version_file = version_file data_dir in
  Lwt_utils_unix.Json.write_file
    version_file
    (Data_encoding.Json.construct version_encoding data_version)
  |> trace (Could_not_write_version_file version_file)

let read_version_file version_file =
  Lwt_utils_unix.Json.read_file version_file
  |> trace (Could_not_read_data_dir_version version_file)
  >>=? fun json ->
  try return (Data_encoding.Json.destruct version_encoding json)
  with
  | Data_encoding.Json.Cannot_destruct _
  | Data_encoding.Json.Unexpected _
  | Data_encoding.Json.No_case_matched _
  | Data_encoding.Json.Bad_array_size _
  | Data_encoding.Json.Missing_field _
  | Data_encoding.Json.Unexpected_field _
  ->
    fail (Could_not_read_data_dir_version version_file)

let check_data_dir_version files data_dir =
  let version_file = version_file data_dir in
  Lwt_unix.file_exists version_file
  >>= function
  | false ->
      fail (Invalid_data_dir (clean_directory files))
  | true -> (
      read_version_file version_file
      >>=? fun version ->
      if String.equal version data_version then return_none
      else
        match
          List.find_opt
            (fun (v, _) -> String.equal v version)
            upgradable_data_version
        with
        | Some f ->
            return_some f
        | None ->
            fail (Invalid_data_dir_version (data_version, version)) )

let ensure_data_dir bare data_dir =
  let write_version () =
    write_version_file data_dir >>=? fun () -> return_none
  in
  Lwt.catch
    (fun () ->
      Lwt_unix.file_exists data_dir
      >>= function
      | true -> (
          Lwt_stream.to_list (Lwt_unix.files_of_directory data_dir)
          >|= List.filter (fun s ->
                  s <> "." && s <> ".." && s <> version_file_name
                  && s <> default_identity_file_name
                  && s <> default_config_file_name
                  && s <> default_peers_file_name)
          >>= function
          | [] ->
              write_version ()
          | files when bare ->
              fail (Invalid_data_dir (clean_directory files))
          | files ->
              check_data_dir_version files data_dir )
      | false ->
          Lwt_utils_unix.create_dir ~perm:0o700 data_dir
          >>= fun () -> write_version ())
    (function
      | Unix.Unix_error _ ->
          fail (Invalid_data_dir data_dir)
      | exc ->
          raise exc)

let upgrade_data_dir data_dir =
  ensure_data_dir false data_dir
  >>=? function
  | None ->
      Events.(emit dir_is_up_to_date ()) >>= fun () -> return_unit
  | Some (version, upgrade) -> (
      Events.(emit upgrading_node (version, data_version))
      >>= fun () ->
      upgrade ~data_dir
      >>= function
      | Ok () ->
          write_version_file data_dir
          >>=? fun () ->
          Events.(emit update_success ()) >>= fun () -> return_unit
      | Error e ->
          Events.(emit aborting_upgrade e) >>= fun () -> return_unit )

let ensure_data_dir ?(bare = false) data_dir =
  ensure_data_dir bare data_dir
  >>=? function
  | None ->
      return_unit
  | Some (version, _) ->
      fail (Data_dir_needs_upgrade {expected = data_version; actual = version})

let upgrade_status data_dir =
  read_version_file (version_file data_dir)
  >>=? fun data_dir_version ->
  Events.(emit upgrade_status (data_dir_version, data_version))
  >>= fun () -> return_unit
