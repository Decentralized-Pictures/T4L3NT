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

type 'a t = 'a Data_encoding.t

type schema = Data_encoding.json_schema * Data_encoding.Binary_schema.t

let unit = Data_encoding.empty

let untyped = Data_encoding.(obj1 (req "untyped" string))

let conv f g t = Data_encoding.conv ~schema:(Data_encoding.Json.schema t) f g t

let schema ?definitions_path t =
  ( Data_encoding.Json.schema ?definitions_path t,
    Data_encoding.Binary.describe t )

let schema_encoding =
  let open Data_encoding in
  obj2
    (req "json_schema" json_schema)
    (req "binary_schema" Data_encoding.Binary_schema.encoding)

module StringMap = Resto.StringMap

let arg_encoding =
  let open Data_encoding in
  conv
    (fun {Resto.Arg.name; descr} -> ((), name, descr))
    (fun ((), name, descr) -> {name; descr})
    (obj3
       (req "id" (constant "single"))
       (req "name" string)
       (opt "descr" string))

let multi_arg_encoding =
  let open Data_encoding in
  conv
    (fun {Resto.Arg.name; descr} -> ((), name, descr))
    (fun ((), name, descr) -> {name; descr})
    (obj3
       (req "id" (constant "multiple"))
       (req "name" string)
       (opt "descr" string))

open Resto.Description

let meth_encoding =
  Data_encoding.string_enum
    [ ("GET", `GET);
      ("POST", `POST);
      ("DELETE", `DELETE);
      ("PUT", `PUT);
      ("PATCH", `PATCH) ]

let path_item_encoding =
  let open Data_encoding in
  union
    [ case
        (Tag 0)
        string
        ~title:"PStatic"
        (function PStatic s -> Some s | _ -> None)
        (fun s -> PStatic s);
      case
        (Tag 1)
        arg_encoding
        ~title:"PDynamic"
        (function PDynamic s -> Some s | _ -> None)
        (fun s -> PDynamic s);
      case
        (Tag 2)
        multi_arg_encoding
        ~title:"PDynamicTail"
        (function PDynamicTail s -> Some s | _ -> None)
        (fun s -> PDynamicTail s) ]

let query_kind_encoding =
  let open Data_encoding in
  union
    [ case
        (Tag 0)
        ~title:"Single"
        (obj1 (req "single" arg_encoding))
        (function Single s -> Some s | _ -> None)
        (fun s -> Single s);
      case
        (Tag 1)
        ~title:"Optional"
        (obj1 (req "optional" arg_encoding))
        (function Optional s -> Some s | _ -> None)
        (fun s -> Optional s);
      case
        (Tag 2)
        ~title:"Flag"
        (obj1 (req "flag" empty))
        (function Flag -> Some () | _ -> None)
        (fun () -> Flag);
      case
        (Tag 3)
        ~title:"Multi"
        (obj1 (req "multi" arg_encoding))
        (function Multi s -> Some s | _ -> None)
        (fun s -> Multi s) ]

let query_item_encoding =
  let open Data_encoding in
  conv
    (fun {name; description; kind} -> (name, description, kind))
    (fun (name, description, kind) -> {name; description; kind})
    (obj3
       (req "name" string)
       (opt "description" string)
       (req "kind" query_kind_encoding))

let service_descr_encoding =
  let open Data_encoding in
  conv
    (fun {meth; path; description; query; input; output; error} ->
      ( meth,
        path,
        description,
        query,
        ( match input with
        | None ->
            None
        | Some input ->
            Some (Lazy.force input) ),
        Lazy.force output,
        Lazy.force error ))
    (fun (meth, path, description, query, input, output, error) ->
      {
        meth;
        path;
        description;
        query;
        input =
          ( match input with
          | None ->
              None
          | Some input ->
              Some (Lazy.from_val input) );
        output = Lazy.from_val output;
        error = Lazy.from_val error;
      })
    (obj7
       (req "meth" meth_encoding)
       (req "path" (list path_item_encoding))
       (opt "description" string)
       (req "query" (list query_item_encoding))
       (opt "input" schema_encoding)
       (req "output" schema_encoding)
       (req "error" schema_encoding))

let directory_descr_encoding =
  let open Data_encoding in
  mu "service_tree"
  @@ fun directory_descr_encoding ->
  let static_subdirectories_descr_encoding =
    union
      [ case
          (Tag 0)
          ~title:"Suffixes"
          (obj1
             (req
                "suffixes"
                (list
                   (obj2
                      (req "name" string)
                      (req "tree" directory_descr_encoding)))))
          (function
            | Suffixes map -> Some (StringMap.bindings map) | _ -> None)
          (fun m ->
            let add acc (n, t) = StringMap.add n t acc in
            Suffixes (List.fold_left add StringMap.empty m));
        case
          (Tag 1)
          ~title:"Arg"
          (obj1
             (req
                "dynamic_dispatch"
                (obj2
                   (req "arg" arg_encoding)
                   (req "tree" directory_descr_encoding))))
          (function Arg (ty, tree) -> Some (ty, tree) | _ -> None)
          (fun (ty, tree) -> Arg (ty, tree)) ]
  in
  let static_directory_descr_encoding =
    conv
      (fun {services; subdirs} ->
        let find s =
          try Some (Resto.MethMap.find s services) with Not_found -> None
        in
        (find `GET, find `POST, find `DELETE, find `PUT, find `PATCH, subdirs))
      (fun (get, post, delete, put, patch, subdirs) ->
        let add meth s services =
          match s with
          | None ->
              services
          | Some s ->
              Resto.MethMap.add meth s services
        in
        let services =
          Resto.MethMap.empty
          |> add `GET get
          |> add `POST post
          |> add `DELETE delete
          |> add `PUT put
          |> add `PATCH patch
        in
        {services; subdirs})
      (obj6
         (opt "get_service" service_descr_encoding)
         (opt "post_service" service_descr_encoding)
         (opt "delete_service" service_descr_encoding)
         (opt "put_service" service_descr_encoding)
         (opt "patch_service" service_descr_encoding)
         (opt "subdirs" static_subdirectories_descr_encoding))
  in
  union
    [ case
        (Tag 0)
        ~title:"Static"
        (obj1 (req "static" static_directory_descr_encoding))
        (function Static descr -> Some descr | _ -> None)
        (fun descr -> Static descr);
      case
        (Tag 1)
        ~title:"Dynamic"
        (obj1 (req "dynamic" (option string)))
        (function Dynamic descr -> Some descr | _ -> None)
        (fun descr -> Dynamic descr);
      case
        (Tag 2)
        ~title:"Empty"
        (constant "empty")
        (function Empty -> Some () | _ -> None)
        (fun () -> Empty) ]

let description_request_encoding =
  let open Data_encoding in
  conv
    (fun {recurse} -> recurse)
    (function recurse -> {recurse})
    (obj1 (dft "recursive" bool false))

let description_answer_encoding = directory_descr_encoding

let uri_encoding =
  let open Data_encoding in
  conv Uri.to_string Uri.of_string string
