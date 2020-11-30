(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2019 Nomadic Labs <contact@nomadic-labs.com>                *)
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

let json_pp id description encoding ppf data =
  Format.pp_print_string ppf @@ Data_encoding.Json.to_string
  @@
  let pp_encoding =
    Data_encoding.(
      obj3 (req "id" string) (req "description" string) (req "data" encoding))
  in
  Data_encoding.Json.construct pp_encoding (id, description, data)

let set_error_encoding_cache_dirty = ref (fun () -> ())

module Make (Prefix : Sig.PREFIX) : sig
  type error = ..

  include Sig.CORE with type error := error

  include Sig.EXT with type error := error

  include Sig.WITH_WRAPPED with type error := error
end = struct
  type error = ..

  let error_encoding_name =
    if Prefix.id = "" then "error" else Prefix.id ^ "error"

  module type Wrapped_error_monad = sig
    type unwrapped = ..

    include Sig.CORE with type error := unwrapped

    include Sig.EXT with type error := unwrapped

    val unwrap : error -> unwrapped option

    val wrap : unwrapped -> error
  end

  type full_error_category =
    | Main of Sig.error_category
    | Wrapped of (module Wrapped_error_monad)

  type encoding_case =
    | Non_recursive of error Data_encoding.case
    | Recursive of (error Data_encoding.t -> error Data_encoding.case)

  (* the toplevel store for error kinds *)
  type error_kind =
    | Error_kind : {
        id : string;
        title : string;
        description : string;
        from_error : error -> 'err option;
        category : full_error_category;
        encoding_case : encoding_case;
        pp : Format.formatter -> 'err -> unit;
      }
        -> error_kind

  type error_info = {
    category : Sig.error_category;
    id : string;
    title : string;
    description : string;
    schema : Data_encoding.json_schema;
  }

  let error_kinds : error_kind list ref = ref []

  let has_recursive_error = ref false

  let get_registered_errors () : error_info list =
    List.flatten
      (List.map
         (function
           | Error_kind {id = ""; _} ->
               []
           | Error_kind
               { id;
                 title;
                 description;
                 category = Main category;
                 encoding_case;
                 _ } -> (
             match encoding_case with
             | Non_recursive encoding_case ->
                 [ {
                     id;
                     title;
                     description;
                     category;
                     schema =
                       Data_encoding.Json.schema
                         (Data_encoding.union [encoding_case]);
                   } ]
             | Recursive make_encoding_case ->
                 [ {
                     id;
                     title;
                     description;
                     category;
                     schema =
                       Data_encoding.Json.schema
                         ( Data_encoding.mu error_encoding_name
                         @@ fun error_encoding ->
                         Data_encoding.union [make_encoding_case error_encoding]
                         );
                   } ] )
           | Error_kind {category = Wrapped (module WEM); _} ->
               List.map
                 (fun {WEM.id; title; description; category; schema} ->
                   {id; title; description; category; schema})
                 (WEM.get_registered_errors ()))
         !error_kinds)

  let error_encoding_cache = ref None

  let () =
    let cont = !set_error_encoding_cache_dirty in
    set_error_encoding_cache_dirty :=
      fun () ->
        cont () ;
        error_encoding_cache := None

  let string_of_category = function
    | `Permanent ->
        "permanent"
    | `Temporary ->
        "temporary"
    | `Branch ->
        "branch"

  let pp_info ppf {category; id; title; description; schema} =
    Format.fprintf
      ppf
      "@[<v 2>category : %s\n\
       id : %s\n\
       title : %s\n\
       description : %s\n\
       schema : %a@]"
      (string_of_category category)
      id
      title
      description
      (Json_repr.pp (module Json_repr.Ezjsonm))
      (Json_schema.to_json schema)

  (* Catch all error when 'serializing' an error. *)
  type error += Unclassified of string

  let () =
    let id = "" in
    let category = Main `Temporary in
    let to_error msg = Unclassified msg in
    let from_error = function
      | Unclassified msg ->
          Some msg
      | error ->
          let msg = Obj.Extension_constructor.(name @@ of_val error) in
          Some ("Unclassified error: " ^ msg ^ ". Was the error registered?")
    in
    let title = "Generic error" in
    let description = "An unclassified error" in
    let encoding_case =
      let open Data_encoding in
      case
        Json_only
        ~title:"Generic error"
        ( def "generic_error" ~title ~description
        @@ conv (fun x -> ((), x)) (fun ((), x) -> x)
        @@ obj2 (req "kind" (constant "generic")) (req "error" string) )
        from_error
        to_error
    in
    let encoding_case = Non_recursive encoding_case in
    let pp ppf s = Format.fprintf ppf "@[<h 0>%a@]" Format.pp_print_text s in
    error_kinds :=
      Error_kind
        {id; title; description; from_error; category; encoding_case; pp}
      :: !error_kinds

  (* Catch all error when 'deserializing' an error. *)
  type error += Unregistered_error of Data_encoding.json

  let () =
    let id = "" in
    let category = Main `Temporary in
    let to_error msg = Unregistered_error msg in
    let from_error = function
      | Unregistered_error json ->
          Some json
      | _ ->
          None
    in
    let encoding_case =
      let open Data_encoding in
      case Json_only ~title:"Unregistered error" json from_error to_error
    in
    let encoding_case = Non_recursive encoding_case in
    let pp ppf json =
      Format.fprintf
        ppf
        "@[<v 2>Unregistered error:@ %a@]"
        Data_encoding.Json.pp
        json
    in
    error_kinds :=
      Error_kind
        {
          id;
          title = "";
          description = "";
          from_error;
          category;
          encoding_case;
          pp;
        }
      :: !error_kinds

  let prepare_registration new_id =
    !set_error_encoding_cache_dirty () ;
    let name = Prefix.id ^ new_id in
    if List.exists (fun (Error_kind {id; _}) -> name = id) !error_kinds then
      invalid_arg
        (Printf.sprintf "register_error_kind: duplicate error name: %s" name) ;
    name

  let register_wrapped_error_kind (module WEM : Wrapped_error_monad) ~id ~title
      ~description =
    let name = prepare_registration id in
    let encoding_case =
      let unwrap err =
        match WEM.unwrap err with
        | Some (WEM.Unclassified _) ->
            None
        | Some (WEM.Unregistered_error _) ->
            None
        | res ->
            res
      in
      let wrap err =
        match err with
        | WEM.Unclassified _ ->
            failwith "ignore wrapped error when serializing"
        | WEM.Unregistered_error _ ->
            failwith "ignore wrapped error when deserializing"
        | res ->
            WEM.wrap res
      in
      Non_recursive (case Json_only ~title:name WEM.error_encoding unwrap wrap)
    in
    error_kinds :=
      Error_kind
        {
          id = name;
          category = Wrapped (module WEM);
          title;
          description;
          from_error = WEM.unwrap;
          encoding_case;
          pp = WEM.pp;
        }
      :: !error_kinds

  let add_kind_and_id ~category ~name ~title ~description encoding from_error
      to_error =
    if not (Data_encoding.is_obj encoding) then
      invalid_arg
        (Printf.sprintf
           "Specified encoding for \"%s%s\" is not an object, but error \
            encodings must be objects."
           Prefix.id
           name) ;
    let with_id_and_kind_encoding =
      merge_objs
        (obj2
           (req "kind" (constant (string_of_category category)))
           (req "id" (constant name)))
        encoding
    in
    case
      Json_only
      ~title
      ~description
      (conv
         (fun x -> (((), ()), x))
         (fun (((), ()), x) -> x)
         with_id_and_kind_encoding)
      from_error
      to_error

  let register_error_kind category ~id ~title ~description ?pp encoding
      from_error to_error =
    let name = prepare_registration id in
    let encoding_case =
      Non_recursive
        (add_kind_and_id
           ~category
           ~name
           ~title
           ~description
           encoding
           from_error
           to_error)
    in
    error_kinds :=
      Error_kind
        {
          id = name;
          category = Main category;
          title;
          description;
          from_error;
          encoding_case;
          pp = Option.value ~default:(json_pp name description encoding) pp;
        }
      :: !error_kinds

  let register_recursive_error_kind category ~id ~title ~description ~pp
      make_encoding from_error to_error =
    let name = prepare_registration id in
    let encoding_case =
      Recursive
        (fun error_encoding ->
          let encoding = make_encoding error_encoding in
          add_kind_and_id
            ~category
            ~name
            ~title
            ~description
            encoding
            from_error
            to_error)
    in
    has_recursive_error := true ;
    error_kinds :=
      Error_kind
        {
          id = name;
          category = Main category;
          title;
          description;
          from_error;
          encoding_case;
          pp;
        }
      :: !error_kinds

  let error_encoding () =
    match !error_encoding_cache with
    | None ->
        let encoding =
          if !has_recursive_error then
            Data_encoding.mu error_encoding_name
            @@ fun error_encoding ->
            let cases =
              List.map
                (fun (Error_kind {encoding_case; _}) ->
                  match encoding_case with
                  | Non_recursive case ->
                      case
                  | Recursive make ->
                      make error_encoding)
                !error_kinds
            in
            let union_encoding = Data_encoding.union cases in
            let open Data_encoding in
            dynamic_size
            @@ splitted
                 ~json:union_encoding
                 ~binary:
                   (conv
                      (Json.construct union_encoding)
                      (Json.destruct union_encoding)
                      json)
          else
            let cases =
              List.map
                (fun (Error_kind {encoding_case; _}) ->
                  match encoding_case with
                  | Non_recursive case ->
                      case
                  | Recursive _ ->
                      assert false)
                !error_kinds
            in
            let union_encoding = Data_encoding.union cases in
            let open Data_encoding in
            dynamic_size
            @@ splitted
                 ~json:union_encoding
                 ~binary:
                   (conv
                      (Json.construct union_encoding)
                      (Json.destruct union_encoding)
                      json)
        in
        error_encoding_cache := Some encoding ;
        encoding
    | Some encoding ->
        encoding

  let error_encoding = Data_encoding.delayed error_encoding

  let json_of_error error = Data_encoding.Json.construct error_encoding error

  let error_of_json json = Data_encoding.Json.destruct error_encoding json

  let classify_error error =
    let rec find e = function
      | [] ->
          `Temporary
      | Error_kind {from_error; category; _} :: rest -> (
        match from_error e with
        | Some _ -> (
          match category with
          | Main error_category ->
              error_category
          | Wrapped (module WEM) -> (
            match WEM.unwrap e with
            | Some e ->
                WEM.classify_error e
            | None ->
                find e rest ) )
        | None ->
            find e rest )
    in
    find error !error_kinds

  let pp ppf error =
    let rec find = function
      | [] ->
          Format.fprintf
            ppf
            "An unspecified error happened, the component that threw it did \
             not provide a specific trace. This should be reported."
      | Error_kind {from_error; pp; _} :: errors -> (
        match from_error error with None -> find errors | Some x -> pp ppf x )
    in
    find !error_kinds
end
