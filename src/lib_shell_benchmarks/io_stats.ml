(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

module Context = Tezos_protocol_environment.Context

type t = {
  total : int;
  keys : int;
  dirs : int;
  degrees : int list;
  depths : int list;
  sizes : int list;
}

let min_max (l : int list) =
  let rec loop l mn mx =
    match l with
    | [] ->
        (mn, mx)
    | x :: tl ->
        let mn = min mn x in
        let mx = max mx x in
        loop tl mn mx
  in
  loop l max_int ~-1

let pp fmtr {total; keys; dirs; degrees = _; depths = _; sizes} =
  let (min_size, max_size) = min_max sizes in
  Format.fprintf
    fmtr
    "{ total = %d; keys = %d ; dirs = %d; sizes in [%d; %d] degrees = ...; \
     depths = _}"
    total
    keys
    dirs
    min_size
    max_size

let empty_stats () =
  {total = 0; keys = 0; dirs = 0; degrees = []; depths = []; sizes = []}

let tree_statistics key_map =
  let open Io_helpers.Key_map in
  let nodes = ref 0 in
  let keys = ref 0 in
  let dirs = ref 0 in
  let rec loop tree depth degrees depths sizes =
    match tree with
    | Leaf size ->
        incr nodes ;
        incr keys ;
        (degrees, depth :: depths, size :: sizes)
    | Node map ->
        let degree = Io_helpers.Key_map.String_map.cardinal map in
        let degrees = degree :: degrees in
        incr nodes ;
        incr dirs ;
        Io_helpers.Key_map.String_map.fold
          (fun _ tree (degrees, depths, sizes) ->
            loop tree (depth + 1) degrees depths sizes)
          map
          (degrees, depths, sizes)
  in
  let (degrees, depths, sizes) = loop key_map 0 [] [] [] in
  {total = !nodes; keys = !keys; dirs = !dirs; degrees; depths; sizes}

let load_tree context key =
  Context.fold
    context
    key
    ~init:Io_helpers.Key_map.empty
    ~f:(fun path t tree ->
      Context.Tree.to_value t
      >|= function
      | Some bytes ->
          let len = Bytes.length bytes in
          Io_helpers.Key_map.insert path len tree
      | None ->
          tree)

let context_statistics base_dir context_hash =
  let (context, index) =
    Io_helpers.load_context_from_disk base_dir context_hash
  in
  load_tree context []
  >>= fun tree ->
  Tezos_storage.Context.close index
  >>= fun () -> Lwt.return (tree_statistics tree)

open StaTz

let empirical_of_list (l : int list) : int Stats.emp =
  Stats.empirical_of_raw_data (Array.of_list l)

let matrix_of_int_list (l : int list) =
  let arr = Array.map float_of_int (Array.of_list l) in
  Pyplot.Matrix.init ~lines:(Array.length arr) ~cols:1 ~f:(fun l _ -> arr.(l))

let plot_histograms save_to {degrees; depths; sizes; _} =
  let open Pyplot.Plot in
  init () ;
  let degrees = matrix_of_int_list degrees in
  let depths = matrix_of_int_list depths in
  let sizes = matrix_of_int_list sizes in
  run
    ~nrows:1
    ~ncols:3
    ( subplot_2d
        ~row:0
        ~col:0
        Axis.(
          set_title "Tree degree distribution"
          >>= fun () ->
          histogram_1d
            ~h:degrees
            ~opts:{bins = Some (Bins_num 50); range = None})
    >>= fun () ->
    subplot_2d
      ~row:0
      ~col:1
      Axis.(
        set_title "Key depth distribution"
        >>= fun () ->
        histogram_1d ~h:depths ~opts:{bins = Some (Bins_num 50); range = None})
    >>= fun () ->
    subplot_2d
      ~row:0
      ~col:2
      Axis.(
        set_title "Data size distribution"
        >>= fun () -> histogram_1d ~h:sizes ~opts:{bins = None; range = None})
    >>= fun () -> savefig ~filename:save_to ~dpi:300 ~quality:95 )
