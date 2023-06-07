(*****************************************************************************)
(*                                                                           *)
(* MIT License                                                               *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

module StringMap = struct
  module M = Map.Make (String)
  include M

  let of_list l = of_seq (List.to_seq l)

  let t (inner : 'a Repr.t) : 'a t Repr.t =
    let module M = Repr.Of_map (struct
      include M

      let key_t = Repr.string
    end) in
    M.t inner

  let keys t = bindings t |> List.map fst

  let values t = bindings t |> List.map snd

  let to_bytes printer map =
    fold
      (fun key elt state ->
        Bytes.cat (Bytes.of_string key) (Bytes.cat (printer elt) state))
      map
      Bytes.empty

  let show (show_inner : 'a -> string) : 'a t -> string =
   fun m ->
    "{\n"
    ^ String.concat
        "\n"
        (List.map (fun (k, v) -> k ^ ": " ^ show_inner v) (bindings m))
    ^ "\n}"

  let to_pair m = (map fst m, map snd m)

  let add_unique k v m =
    if mem k m then
      raise
        (Invalid_argument (Printf.sprintf "key %s already present in map." k))
    else add k v m

  (* Return the union of two maps. The keys of the maps have to be disjoint unless
     specifically stated in common_keys. In this case both key's values
     are asserted to be equal, with a given equality function.
     If no equal function is given the polymorphic euqality is used.*)
  let union_disjoint ?(common_keys_equal_elt = ([], ( = ))) x y =
    let common_keys, equal_elt = common_keys_equal_elt in
    union
      (fun key elt_1 elt_2 ->
        if not (List.mem key common_keys) then
          raise
            (Invalid_argument
               (Printf.sprintf
                  "the key %s appears in both union arguments and does not \
                   belong\n\
                  \                                 to common_keys."
                  key))
        else if not (equal_elt elt_1 elt_2) then
          raise
            (Invalid_argument
               (Printf.sprintf
                  "the key %s appears in both union argument with different \
                   values"
                  key))
        else Some elt_1)
      x
      y

  (* applies union_disjoint on a list of map*)
  let union_disjoint_list ?(common_keys_equal_elt = ([], ( = ))) map_list =
    List.fold_left (union_disjoint ~common_keys_equal_elt) empty map_list

  (* given a list of maps outputs a single map with the union of all keys and
     containing lists which consist of the concatenation of the data elements
     under the same key (order is preserved) *)
  let map_list_to_list_map map_list =
    let join _key x y = Some (x @ y) in
    List.fold_left
      (fun list_map m -> union join list_map (map (fun x -> [x]) m))
      empty
      map_list

  let sub_map sub_map map =
    let res = filter (fun name _ -> mem name sub_map) map in
    if cardinal res <> cardinal sub_map then
      failwith "sub_map : first argument is not contained in the second." ;
    res

  let two_maps_of_pair_map m =
    fold
      (fun k (v1, v2) (acc1, acc2) -> (add k v1 acc1, add k v2 acc2))
      m
      (empty, empty)

  let update_keys f map = fold (fun k v acc -> add (f k) v acc) map empty

  module Aggregation = struct
    (* separator between prefixes & name ; must be only one character *)
    let sep = "~"

    let padded ~n i =
      let str = string_of_int i in
      let len = String.length (string_of_int (n - 1)) in
      String.(make (len - length str) '0') ^ str

    let add_prefix ?(no_sep = false) ?(n = 1) ?(i = 0) ?(shift = 0) prefix str =
      let prefix = if prefix = "" || no_sep then prefix else prefix ^ sep in
      if n = 1 then prefix ^ str else prefix ^ padded ~n (i + shift) ^ sep ^ str

    let prefix_map ?n ?i ?shift prefix str_map =
      fold (fun k -> add (add_prefix ?n ?i ?shift prefix k)) str_map empty

    (* This function will merge the maps of the list, by prefixing each key with it’s index in the list, optionnally with a shift, with the index prefix prefixed with zero to we able to handle [n] elements with the same prefix size ; if a [prefix] is given, it will be put before the index.
       *)
    let map_of_list_map ?(prefix = "") ?shift ?n list_map =
      let n = match n with None -> List.length list_map | Some n -> n in
      let shift = match shift with None -> 0 | Some shift -> shift in
      List.mapi (fun i m -> prefix_map ~n ~i ~shift prefix m) list_map
      |> union_disjoint_list

    let smap_of_smap_smap mapmap =
      fold (fun prefix map res -> prefix_map prefix map :: res) mapmap []
      |> union_disjoint_list

    let gather_maps ?(shifts_map = empty) map_list_map =
      mapi
        (fun name list_map ->
          let shift, n =
            match find_opt name shifts_map with
            | None -> (None, None)
            | Some (shift, n) -> (Some shift, Some n)
          in
          map_of_list_map ?shift ?n list_map)
        map_list_map
      |> smap_of_smap_smap

    let filter_by_circuit_name circuit_name =
      let sep_char =
        assert (String.length sep = 1) ;
        String.get sep 0
      in
      filter (fun key _ ->
          let name_parts = String.split_on_char sep_char key in
          circuit_name = ""
          || List.exists
               (String.equal circuit_name)
               (* we exclude the last element in [name_parts] *)
               (List.rev name_parts |> List.tl))

    let select_answers_by_circuit circuit_name =
      map (filter_by_circuit_name circuit_name)
  end
end

module type S = sig
  include Map.S with type key = string and type 'a t = 'a StringMap.t

  val t : 'a Repr.ty -> 'a t Repr.ty

  val of_list : (string * 'a) list -> 'a t

  val keys : 'a t -> string list

  val values : 'a t -> 'a list

  val to_pair : ('a * 'b) t -> 'a t * 'b t

  (* [add_unique k v map] adds [k -> v] to [map] & throw an error if [k] is
     already in [map]
  *)
  val add_unique : key -> 'a -> 'a t -> 'a t

  val union_disjoint :
    ?common_keys_equal_elt:string list * ('a -> 'a -> bool) ->
    'a t ->
    'a t ->
    'a t

  val union_disjoint_list :
    ?common_keys_equal_elt:string list * ('a -> 'a -> bool) -> 'a t list -> 'a t

  val map_list_to_list_map : 'a t list -> 'a list t

  (* [sub_map m1 m2] returns m2 without the keys that do not appear in m1.
     Raises failure if some key of m1 is not in m2
  *)
  val sub_map : 'a t -> 'b t -> 'b t

  (* Splits a map of couple into a couple of maps *)
  val two_maps_of_pair_map : ('a * 'b) t -> 'a t * 'b t

  (* USE WITH CAUTION : be sure your update function won’t create duplications *)
  val update_keys : (key -> key) -> 'a t -> 'a t

  module Aggregation : sig
    (* Separator for prefixing *)
    val sep : string

    (* [add_prefix ~n ~i ~shift prefix str] return idx^prefix^sep^str
       idx = [i] + [shift] as a string, eventually padded with '0' before to
       allow a numbering until [n] with the same number of caracters
       for instance, [prefix ~n:11 ~i:5 ~shift:1 "hello" "world"] will return
       "06~hello~world"
       [no_sep] is false by default ; if set to true, the separator before the
        string to prefix will be ommitted :
       [prefix ~no_sep:true ~n:11 ~i:5 ~shift:1 "hello" "world"] will return
       "06~helloworld"
    *)
    val add_prefix :
      ?no_sep:bool ->
      ?n:int ->
      ?i:int ->
      ?shift:int ->
      string ->
      string ->
      string

    (* adds prefix to each key of str_map ; [i] will be added as a string
       before the prefix
       For instance [prefix_map ~n:3000 ~i:5 ~shift:1 "hello" map] will prefix
       all the keys of [map] with "0006~hello~"
    *)
    val prefix_map : ?n:int -> ?i:int -> ?shift:int -> string -> 'a t -> 'a t

    val map_of_list_map :
      ?prefix:key -> ?shift:int -> ?n:int -> 'a t list -> 'a t

    (* "c1" -> {"a" ; "b"} ; "c2" -> {"a" ; "c"} becomes
       {"c1~a" ; "c1~b" ; "c2~a" ; "c2~c"} with the same values *)
    val smap_of_smap_smap : 'a t t -> 'a t

    (* Converts a map of list of map in a map, by merging each list of map in
       one map, prefixing all keys with their proof index, and then merging all
       the new maps into one prefixing the keys with the outside map’s keys.
       shifts_maps map outside key to pairs of integers.
       'key1' -> (7, 20) means that 20 proofs will be produced for key1 in
       total and we should start from the 8th one, assuming 7 of them were done
       independently. (Note that we may not even finish the whole 20, this
       depends on the map_list length).
       For example, on input:
       { 'circuit_foo' -> [ {'a' -> fa0; 'b' -> fb0; 'c' -> fc0};
                            {'a' -> fa1; 'b' -> fb1; 'c' -> fc1} ];
         'circuit_bar' -> [ {'a' -> ga0; 'b' -> gb0; 'c' -> gc0} ]; }
       outputs
       { 'circuit_foo~0~a' -> fa0;
         'circuit_foo~0~b' -> fb0
         'circuit_foo~0~c' -> fc0
         'circuit_foo~1~a' -> fa1
         'circuit_foo~1~b' -> fb1
         'circuit_foo~1~c' -> fc1
         'circuit_bar~0~a' -> ga0
         'circuit_bar~0~b' -> gb0
         'circuit_bar~0~c' -> gc0
       }
    *)
    val gather_maps : ?shifts_map:(int * int) t -> 'a t list t -> 'a t

    (* Filter a map keeping the elements whose key corresponds to the given
       circuit name *)
    val filter_by_circuit_name : string -> 'a t -> 'a t

    (* [select_answers_by_circuit circuit_name s_map_map] takes a [circuit_name]
       and a map with the structure:
       { 'x' -> { 'circuit_foo~0~a' -> [scalar] ;
                  'circuit_foo~0~b' -> [scalar] ;
                   ...
                }
       }
       and filters the keys of the inner map, keeping the elements whose key
       corresponds to the given circuit name. *)
    val select_answers_by_circuit : string -> 'a t t -> 'a t t
  end
end

include (StringMap : S)
