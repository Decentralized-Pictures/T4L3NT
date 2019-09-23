open Internal_pervasives

module More_fmt = struct
  include Fmt
  (** Little experiment for fun … *)

  let vertical_box ?indent ppf f = vbox ?indent (fun ppf () -> f ppf) ppf ()
  let wrapping_box ?indent ppf f = hvbox ?indent (fun ppf () -> f ppf) ppf ()

  let wf ppf fmt =
    Format.kasprintf (fun s -> box (fun ppf () -> text ppf s) ppf ()) fmt

  let markdown_verbatim_list ppf l =
    vertical_box ~indent:0 ppf (fun ppf ->
        cut ppf () ;
        string ppf (String.make 45 '`') ;
        List.iter l ~f:(fun l -> cut ppf () ; string ppf l) ;
        cut ppf () ;
        string ppf (String.make 45 '`'))

  let tag tag ppf f =
    Format.pp_open_tag ppf tag ;
    (f ppf : unit) ;
    Format.pp_close_tag ppf ()

  let shout = tag "shout"

  let long_string ?(max = 30) ppf s =
    match String.sub s ~pos:0 ~len:(max - 2) with
    | s -> pf ppf "%S" (s ^ "...")
    | exception _ -> pf ppf "%S" s
end

module Markup_fmt = struct
  (** An alternative experiment. *)

  let vertical_box ?indent ppf f =
    let open Fmt in
    vbox ?indent (fun ppf () -> f ppf) ppf ()

  let wrapping_box ?indent ppf f =
    let open Fmt in
    box ?indent (fun ppf () -> f ppf) ppf ()

  type in_par =
    [`Text of string | `Highlight of in_par | `Concat of in_par list]

  type t =
    [ `Par of in_par
    | `Itemize of in_par list
    | `Raw of string
    | `Verbatim of string list ]

  let par l : t list =
    match l with [one] -> [`Par one] | l -> [`Par (`Concat l)]

  let verbatim l = [`Verbatim l]
  let verbatim_raw raw = [`Verbatim (String.split ~on:'\n' raw)]

  let verbatim_ezjson json =
    verbatim_raw (Ezjsonm.value_to_string ~minify:false json)

  let t s : in_par list = [`Text s]
  let tf fmt = Format.kasprintf t fmt
  let hl l : in_par list = [`Highlight (`Concat l)]
  let concat l = `Concat l
  let hlf fmt = Format.kasprintf (fun s -> hl (t s)) fmt
  let itemize l : t list = [`Itemize (List.map l ~f:(fun l -> `Concat l))]

  let to_fmt (x : t list) ppf () =
    let open Fmt in
    let rec pp_in_par ppf = function
      | `Text s -> text ppf s
      | `Concat l -> List.iter l ~f:(pp_in_par ppf)
      | `Highlight s ->
          Format.pp_open_tag ppf "prompt" ;
          pp_in_par ppf s ;
          Format.pp_close_tag ppf () in
    vertical_box ppf (fun ppf ->
        list ~sep:cut
          (fun ppf item ->
            match item with
            | `Par in_par -> wrapping_box ppf (fun ppf -> pp_in_par ppf in_par)
            | `Verbatim sl ->
                vertical_box ppf (fun ppf ->
                    string ppf "`````" ;
                    List.iter sl ~f:(fun l -> cut ppf () ; string ppf l) ;
                    cut ppf () ;
                    string ppf "`````")
            | `Itemize l ->
                list ~sep:cut
                  (fun ppf inpar ->
                    wrapping_box ~indent:2 ppf (fun ppf ->
                        string ppf "* " ; pp_in_par ppf inpar))
                  ppf l
            | `Raw s -> string ppf s)
          ppf x)
end
