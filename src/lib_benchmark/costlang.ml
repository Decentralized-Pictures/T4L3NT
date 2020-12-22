(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2019 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

module type S = sig
  type 'a repr

  type size

  val true_ : bool repr

  val false_ : bool repr

  val int : int -> size repr

  val float : float -> size repr

  val ( + ) : size repr -> size repr -> size repr

  val ( - ) : size repr -> size repr -> size repr

  val ( * ) : size repr -> size repr -> size repr

  val ( / ) : size repr -> size repr -> size repr

  val max : size repr -> size repr -> size repr

  val min : size repr -> size repr -> size repr

  val log2 : size repr -> size repr

  val free : name:Free_variable.t -> size repr

  val lt : size repr -> size repr -> bool repr

  val eq : size repr -> size repr -> bool repr

  val shift_left : size repr -> int -> size repr

  val shift_right : size repr -> int -> size repr

  val lam : name:string -> ('a repr -> 'b repr) -> ('a -> 'b) repr

  val app : ('a -> 'b) repr -> 'a repr -> 'b repr

  val let_ : name:string -> 'a repr -> ('a repr -> 'b repr) -> 'b repr

  val if_ : bool repr -> 'a repr -> 'a repr -> 'a repr
end

(* ------------------------------------------------------------------------- *)
(* Various useful implementations of the signatures above. *)

module Pp : S with type 'a repr = string and type size = string = struct
  type 'a repr = string

  type size = string

  let true_ = "true"

  let false_ = "false"

  let float = string_of_float

  let int = string_of_int

  let ( + ) x y = Format.asprintf "(%s + %s)" x y

  let ( - ) x y = Format.asprintf "(%s - %s)" x y

  let ( * ) x y = Format.asprintf "(%s * %s)" x y

  let ( / ) x y = Format.asprintf "(%s / %s)" x y

  let max x y = Format.asprintf "(max %s %s)" x y

  let min x y = Format.asprintf "(min %s %s)" x y

  let shift_left x i = Format.asprintf "(%s lsl %d)" x i

  let shift_right x i = Format.asprintf "(%s lsr %d)" x i

  let log2 x = Format.asprintf "(log2 %s)" x

  let free ~name = Format.asprintf "free(%a)" Free_variable.pp name

  let lt x y = Format.asprintf "(%s < %s)" x y

  let eq x y = Format.asprintf "(%s = %s)" x y

  let lam ~name f = Format.asprintf "fun %s -> %s" name (f name)

  let app f arg = Format.asprintf "(%s %s)" f arg

  let let_ ~name m f = Format.asprintf "let %s = %s in %s" name m (f name)

  let if_ cond ift iff = Format.asprintf "(if %s then %s else %s)" cond ift iff
end

module Free_variables :
  S with type 'a repr = Free_variable.Set.t and type size = unit = struct
  open Free_variable

  exception Free_variable_captured_by_lambda of string

  exception Free_variable_captured_by_let of string

  type 'a repr = Set.t

  type size = unit

  let lift_binop x y = Set.union x y

  let true_ = Set.empty

  let false_ = Set.empty

  let float _ = Set.empty

  let int _ = Set.empty

  let ( + ) = lift_binop

  let ( - ) = lift_binop

  let ( * ) = lift_binop

  let ( / ) = lift_binop

  let max = lift_binop

  let min = lift_binop

  let shift_left x _i = x

  let shift_right x _i = x

  let log2 x = x

  let free ~name = Set.singleton name

  let lt = lift_binop

  let eq = lift_binop

  let lam ~name f =
    let result = f Set.empty in
    let bound = Free_variable.of_string name in
    if Set.mem bound result then raise (Free_variable_captured_by_lambda name)
    else result

  let app f arg = Set.union f arg

  let let_ ~name m f =
    let in_scope = f Set.empty in
    let result = Set.union m in_scope in
    let bound = Free_variable.of_string name in
    if Set.mem bound in_scope then raise (Free_variable_captured_by_let name)
    else result

  let if_ cond ift iff = Set.union cond (Set.union ift iff)
end

module Parameters :
  S with type 'a repr = bool -> String.Set.t and type size = unit = struct
  type 'a repr = bool -> String.Set.t

  type size = unit

  let true_ _ = String.Set.empty

  let false_ _ = String.Set.empty

  let lift_binop _x _y _b = String.Set.empty

  let float _ _ = String.Set.empty

  let int _ _ = String.Set.empty

  let ( + ) = lift_binop

  let ( - ) = lift_binop

  let ( * ) = lift_binop

  let ( / ) = lift_binop

  let max = lift_binop

  let min = lift_binop

  let shift_left _x _i _ = String.Set.empty

  let shift_right _x _i _ = String.Set.empty

  let log2 _x _ = String.Set.empty

  let free ~name _ = ignore name ; String.Set.empty

  let lt = lift_binop

  let eq = lift_binop

  let lam ~name f is_head =
    if is_head then String.Set.add name (f (fun _ -> String.Set.empty) is_head)
    else String.Set.empty

  let app _f _arg _ = String.Set.empty

  let let_ ~name _m _f _ = ignore name ; String.Set.empty

  let if_ _cond _ift _iff _ = String.Set.empty
end

module Eval : S with type 'a repr = 'a and type size = float = struct
  exception Term_contains_free_variable of Free_variable.t

  type 'a repr = 'a

  type size = float

  let lift_binop op x y = op x y

  let true_ = true

  let false_ = false

  let float x = x

  let int x = float_of_int x

  let ( + ) = lift_binop ( +. )

  let ( - ) = lift_binop ( -. )

  let ( * ) = lift_binop ( *. )

  let ( / ) = lift_binop ( /. )

  let max = lift_binop max

  let min = lift_binop min

  let shift_left x i = x *. (2. ** float_of_int i)

  let shift_right x i = x /. (2. ** float_of_int i)

  let log2 x = log x /. log 2.

  let free ~name = raise (Term_contains_free_variable name)

  let lt x y = x < y

  let eq x y = x = y

  let lam ~name f = ignore name ; f

  let app f arg = f arg

  let let_ ~name m f = ignore name ; f m

  let if_ cond ift iff = if cond then ift else iff
end

(* Evaluating implementation. Expects terms to evaluate
   to affine combinations with free variables as coefficients.
   Fails otherwise.
   Takes a substitution as a parameter. *)

type affine = {linear_comb : Free_variable.Sparse_vec.t; const : float}

module Affine_ops = struct
  module V = Free_variable.Sparse_vec

  let is_const a = V.is_empty a.linear_comb

  let ( + ) a1 a2 =
    {
      linear_comb = V.add a1.linear_comb a2.linear_comb;
      const = a1.const +. a2.const;
    }

  let ( - ) a1 a2 =
    {
      linear_comb = V.add a1.linear_comb (V.neg a2.linear_comb);
      const = a1.const -. a2.const;
    }

  let smul c {linear_comb; const} =
    {linear_comb = V.smul c linear_comb; const = c *. const}
end

(* Substitution for free variables *)
type subst = Free_variable.t -> float option

exception Eval_linear_combination of string

let () =
  Printexc.register_printer (fun exn ->
      match exn with
      | Eval_linear_combination s ->
          Some
            (Format.asprintf
               "Eval_linear_combination: cannot convert node %s"
               s)
      | _ ->
          None)

module Eval_linear_combination_impl : sig
  include S

  val run : subst -> size repr -> affine
end
(* multiset of strings = formal linear combinations with integer coefficients *) =
struct
  type size = float

  type 'a repr = subst -> 'a result

  and 'a result = Affine : affine -> size result | Bool : bool -> bool result

  let true_ _ = Bool true

  let false_ _ = Bool false

  let int i _ =
    Affine
      {const = float_of_int i; linear_comb = Free_variable.Sparse_vec.zero}

  let float f _ =
    Affine {const = f; linear_comb = Free_variable.Sparse_vec.zero}

  let ( + ) (x1 : size repr) (x2 : size repr) subst =
    let (Affine a1) = x1 subst in
    let (Affine a2) = x2 subst in
    Affine Affine_ops.(a1 + a2)

  let ( - ) (x1 : size repr) (x2 : size repr) subst =
    let (Affine a1) = x1 subst in
    let (Affine a2) = x2 subst in
    Affine Affine_ops.(a1 - a2)

  let ( * ) (x1 : size repr) (x2 : size repr) subst =
    let (Affine a1) = x1 subst in
    let (Affine a2) = x2 subst in
    if Affine_ops.is_const a1 then Affine (Affine_ops.smul a1.const a2)
    else if Affine_ops.is_const a2 then Affine (Affine_ops.smul a2.const a1)
    else raise (Eval_linear_combination "*")

  let ( / ) (x1 : size repr) (x2 : size repr) subst =
    let (Affine a1) = x1 subst in
    let (Affine a2) = x2 subst in
    if Affine_ops.is_const a2 then Affine (Affine_ops.smul (1. /. a2.const) a1)
    else raise (Eval_linear_combination "/")

  let max (x1 : size repr) (x2 : size repr) subst =
    let (Affine a1) = x1 subst in
    let (Affine a2) = x2 subst in
    if Affine_ops.is_const a1 && Affine_ops.is_const a2 then
      Affine
        {
          linear_comb = Free_variable.Sparse_vec.zero;
          const = max a1.const a2.const;
        }
    else raise (Eval_linear_combination "max")

  let min (x1 : size repr) (x2 : size repr) subst =
    let (Affine a1) = x1 subst in
    let (Affine a2) = x2 subst in
    if Affine_ops.is_const a1 && Affine_ops.is_const a2 then
      Affine
        {
          linear_comb = Free_variable.Sparse_vec.zero;
          const = min a1.const a2.const;
        }
    else raise (Eval_linear_combination "max")

  let log2 (x : size repr) subst =
    let (Affine a) = x subst in
    if Affine_ops.is_const a then
      Affine
        {
          linear_comb = Free_variable.Sparse_vec.zero;
          const = log a.const /. log 2.;
        }
    else raise (Eval_linear_combination "max")

  let free ~name subst =
    match subst name with
    | Some const ->
        Affine {const; linear_comb = Free_variable.Sparse_vec.zero}
    | None ->
        Affine
          {
            const = 0.0;
            linear_comb = Free_variable.Sparse_vec.of_list [(name, 1.0)];
          }

  let lt (x1 : size repr) (x2 : size repr) subst =
    let (Affine a1) = x1 subst in
    let (Affine a2) = x2 subst in
    if Affine_ops.is_const a1 && Affine_ops.is_const a2 then
      Bool (a1.const < a2.const)
    else raise (Eval_linear_combination "lt")

  let eq (x1 : size repr) (x2 : size repr) subst =
    let (Affine a1) = x1 subst in
    let (Affine a2) = x2 subst in
    if Affine_ops.is_const a1 && Affine_ops.is_const a2 then
      Bool (a1.const = a2.const)
    else raise (Eval_linear_combination "eq")

  let shift_left _ _ = raise (Eval_linear_combination "shift_left")

  let shift_right _ _ = raise (Eval_linear_combination "shift_right")

  let lam ~name:_ _f _subst = raise (Eval_linear_combination "lambda")

  let app _bound _body _subst = raise (Eval_linear_combination "app")

  let let_ ~name:_ bound body subst = body bound subst

  let if_ (cond : bool repr) (ift : 'a repr) (iff : 'a repr) : 'a repr =
   fun subst ->
    let (Bool b) = cond subst in
    if b then ift subst else iff subst

  let run : subst -> size repr -> affine =
   fun subst repr ->
    let (Affine res) = repr subst in
    res
end

(* ------------------------------------------------------------------------- *)
(* Implementation _transformers_. *)

module type Transform = functor (X : S) -> sig
  include S with type size = X.size

  val prj : 'a repr -> 'a X.repr
end

type transform = (module Transform)

let compose (f : transform) (g : transform) : transform =
  let module F = (val f) in
  let module G = (val g) in
  let module G_circ_F (X : S) = struct
    module FX = F (X)
    module GFX = G (FX)
    include GFX

    let prj term = FX.prj (GFX.prj term)
  end in
  (module G_circ_F)

(* Identity transform *)
module Identity : Transform =
functor
  (X : S)
  ->
  struct
    include X

    let prj x = x
  end

module type Map_const_params = sig
  val map_int : int -> int

  val map_float : float -> float
end

module Map_const (P : Map_const_params) : Transform =
functor
  (X : S)
  ->
  struct
    include X

    let prj x = x

    let float f = X.float (P.map_float f)

    let int i = X.int (P.map_int i)
  end

module Subst (P : sig
  val subst : Free_variable.t -> float
end) : Transform =
functor
  (X : S)
  ->
  struct
    include X

    let prj x = x

    let free ~name = X.float (P.subst name)
  end

module Hashtbl = Stdlib.Hashtbl

type 'a hash_consed = {repr : 'a; hash : int; tag : int}

module Hash_cons : Transform =
functor
  (X : S)
  ->
  struct
    type size = X.size

    type 'a repr = 'a X.repr hash_consed

    type unique_term_identifier =
      | Int_tag of {i : int} (* not a tag, actual data! *)
      | Float_tag of {f : float} (* not a tag, actual data! *)
      | Add_tag of int * int
      | Sub_tag of int * int
      | Mul_tag of int * int
      | Div_tag of int * int
      | Max_tag of int * int
      | Min_tag of int * int
      | Log2_tag of int
      | Free_tag of {name : Free_variable.t}

    let prj {repr; _} = repr

    (* A hashtable for memoizing terms of type `size repr`. We don't
       bother hash-consing the rest: this is the sublanguage were sharing
       is most useful. *)
    let size_table : (int, size repr * unique_term_identifier) Hashtbl.t =
      Hashtbl.create 101

    let fresh =
      let c = ref ~-1 in
      fun () -> incr c ; !c

    let insert_if_not_present (term_thunk : unit -> size X.repr)
        (uti : unique_term_identifier) =
      let hash = Hashtbl.hash uti in
      match Hashtbl.find_all size_table hash with
      | [] ->
          let hash_consed = {repr = term_thunk (); hash; tag = fresh ()} in
          Hashtbl.add size_table hash (hash_consed, uti) ;
          hash_consed
      | bindings -> (
        match List.find_opt (fun (_, uti') -> uti = uti') bindings with
        | None ->
            let hash_consed = {repr = term_thunk (); hash; tag = fresh ()} in
            Hashtbl.add size_table hash (hash_consed, uti) ;
            hash_consed
        | Some (res, _) ->
            res )

    let lift2_nohash f x y =
      let hash = -1 in
      {repr = f x.repr y.repr; hash; tag = fresh ()}

    let false_ = {repr = X.false_; hash = -1; tag = fresh ()}

    let true_ = {repr = X.false_; hash = -1; tag = fresh ()}

    let float (f : float) =
      insert_if_not_present (fun () -> X.float f) (Float_tag {f})

    let int (i : int) = insert_if_not_present (fun () -> X.int i) (Int_tag {i})

    let ( + ) x y =
      insert_if_not_present
        X.(fun () -> x.repr + y.repr)
        (Add_tag (x.tag, y.tag))

    let ( - ) x y =
      insert_if_not_present
        X.(fun () -> x.repr - y.repr)
        (Sub_tag (x.tag, y.tag))

    let ( * ) x y =
      insert_if_not_present
        X.(fun () -> x.repr * y.repr)
        (Mul_tag (x.tag, y.tag))

    let ( / ) x y =
      insert_if_not_present
        X.(fun () -> x.repr / y.repr)
        (Div_tag (x.tag, y.tag))

    let max x y =
      insert_if_not_present
        X.(fun () -> max x.repr y.repr)
        (Max_tag (x.tag, y.tag))

    let min x y =
      insert_if_not_present
        X.(fun () -> min x.repr y.repr)
        (Min_tag (x.tag, y.tag))

    let log2 x =
      insert_if_not_present X.(fun () -> log2 x.repr) (Log2_tag x.tag)

    let free ~name =
      insert_if_not_present X.(fun () -> free ~name) (Free_tag {name})

    let lt x y = {repr = X.lt x.repr y.repr; hash = -1; tag = fresh ()}

    let eq x y = {repr = X.lt x.repr y.repr; hash = -1; tag = fresh ()}

    (* The functions below are _not_ hash-consed. *)
    let shift_left x i =
      let hash = -1 in
      {repr = X.shift_left x.repr i; hash; tag = fresh ()}

    let shift_right x i =
      let hash = -1 in
      {repr = X.shift_right x.repr i; hash; tag = fresh ()}

    let unlift_fun : type a b. (a repr -> b repr) -> a X.repr -> b X.repr =
     fun f x -> (f {repr = x; hash = -1; tag = fresh ()}).repr

    let lam ~name body =
      {repr = X.lam ~name (unlift_fun body); hash = -1; tag = fresh ()}

    let app f arg = lift2_nohash X.app f arg

    let let_ ~name bound body =
      {
        repr = X.let_ ~name bound.repr (unlift_fun body);
        hash = -1;
        tag = fresh ();
      }

    let if_ cond ift iff =
      {repr = X.if_ cond.repr ift.repr iff.repr; hash = -1; tag = fresh ()}
  end

(* [Beta_normalize] evaluates beta-redexes. *)
module Beta_normalize : Transform =
functor
  (X : S)
  ->
  struct
    type size = X.size

    (* A value is either a lambda that can be statically evaluated
       (case [Static_lam]) or any value that will be
       dynamically evaluated (case [Dynamic]). *)
    type 'a repr =
      | Static_lam : {
          name : string;
          lam : 'a X.repr -> 'b repr;
        }
          -> ('a -> 'b) repr
      | Dynamic : 'a X.repr -> 'a repr

    let dyn (x : 'a X.repr) : 'a repr = Dynamic x

    let rec prj : type a. a repr -> a X.repr =
     fun x ->
      match x with
      | Static_lam {name; lam} ->
          X.lam ~name (fun arg -> prj (lam arg))
      | Dynamic d ->
          d

    let lift1 f x = match x with Dynamic d -> dyn (f d) | _ -> assert false

    let lift2 f x y =
      match (x, y) with
      | (Dynamic d, Dynamic e) ->
          dyn (f d e)
      | _ ->
          assert false

    let false_ = dyn X.false_

    let true_ = dyn X.true_

    let float f = dyn (X.float f)

    let int i = dyn (X.int i)

    let ( + ) x y = lift2 X.( + ) x y

    let ( - ) x y = lift2 X.( - ) x y

    let ( * ) x y = lift2 X.( * ) x y

    let ( / ) x y = lift2 X.( / ) x y

    let max x y = lift2 X.max x y

    let min x y = lift2 X.min x y

    let shift_left x i = lift1 (fun x -> X.shift_left x i) x

    let shift_right x i = lift1 (fun x -> X.shift_right x i) x

    let log2 x = lift1 X.log2 x

    let free ~name = dyn (X.free ~name)

    let lt x y = lift2 X.lt x y

    let eq x y = lift2 X.lt x y

    let lam : name:string -> ('a repr -> 'b repr) -> ('a -> 'b) repr =
     fun ~name f ->
      let lam arg = f (dyn arg) in
      Static_lam {name; lam}

    let app : type a b. (a -> b) repr -> a repr -> b repr =
     fun f arg ->
      match f with
      | Static_lam {lam; _} ->
          lam (prj arg)
      | Dynamic dyn_f ->
          Dynamic (X.app dyn_f (prj arg))

    let let_ : type a b. name:string -> a repr -> (a repr -> b repr) -> b repr
        =
     fun ~name m f -> Dynamic (X.let_ ~name (prj m) (fun x -> prj (f (dyn x))))

    let if_ cond ift iff = Dynamic (X.if_ (prj cond) (prj ift) (prj iff))
  end

(* As the type indicates, this is a simplified CPS transform designed to
   lift let-bindings out of subexpressions. Warning: this transformation
   does not check that the ~name arguments (used for pretty printing)
   are globally distinct for let bindings. *)
module Let_lift : Transform =
functor
  (X : S)
  ->
  struct
    type size = X.size

    type 'a cps = {cont : 'b. ('a -> 'b X.repr) -> 'b X.repr}

    type 'a repr = 'a X.repr cps

    let prj term = term.cont (fun x -> x)

    let ret x = {cont = (fun k -> k x)}

    let lift_binop op x y =
      {cont = (fun k -> x.cont (fun x -> y.cont (fun y -> k (op x y))))}

    let lift_unop op x = {cont = (fun k -> x.cont (fun x -> k (op x)))}

    let false_ = ret X.false_

    let true_ = ret X.true_

    let float f = ret (X.float f)

    let int i = ret (X.int i)

    let ( + ) = lift_binop X.( + )

    let ( - ) = lift_binop X.( - )

    let ( * ) = lift_binop X.( * )

    let ( / ) = lift_binop X.( / )

    let max = lift_binop X.max

    let min = lift_binop X.min

    let shift_left x i =
      {cont = (fun k -> x.cont (fun x -> k (X.shift_left x i)))}

    let shift_right x i =
      {cont = (fun k -> x.cont (fun x -> k (X.shift_right x i)))}

    let log2 = lift_unop X.log2

    let free ~name = ret (X.free ~name)

    let lt = lift_binop X.lt

    let eq = lift_binop X.eq

    let lam ~name (f : 'a repr -> 'b repr) =
      {cont = (fun k -> k (X.lam ~name (fun x -> prj (f (ret x)))))}

    let app f arg = {cont = (fun k -> k (X.app (prj f) (prj arg)))}

    let let_ ~name (m : 'a repr) (f : 'a repr -> 'b repr) : 'b repr =
      {
        cont =
          (fun k -> X.let_ ~name (prj m) (fun mres -> k (prj (f (ret mres)))));
      }

    let if_ cond ift iff =
      {
        cont =
          (fun k ->
            cond.cont (fun cond -> k @@ X.if_ cond (prj ift) (prj iff)));
      }
  end

(* Instantiate model over partially evaluating & hash-consing cost
   function DSL *)
module Hash_cons_vector = Hash_cons (Eval_linear_combination_impl)
module Eval_to_vector = Beta_normalize (Hash_cons_vector)
