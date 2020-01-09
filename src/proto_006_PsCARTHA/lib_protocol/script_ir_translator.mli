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

open Alpha_context
open Script_tc_errors

type ('ta, 'tb) eq = Eq : ('same, 'same) eq

type ex_comparable_ty =
  | Ex_comparable_ty : 'a Script_typed_ir.comparable_ty -> ex_comparable_ty

type ex_ty = Ex_ty : 'a Script_typed_ir.ty -> ex_ty

type ex_stack_ty = Ex_stack_ty : 'a Script_typed_ir.stack_ty -> ex_stack_ty

type ex_script = Ex_script : ('a, 'b) Script_typed_ir.script -> ex_script

type tc_context =
  | Lambda : tc_context
  | Dip : 'a Script_typed_ir.stack_ty * tc_context -> tc_context
  | Toplevel : {
      storage_type : 'sto Script_typed_ir.ty;
      param_type : 'param Script_typed_ir.ty;
      root_name : string option;
      legacy_create_contract_literal : bool;
    }
      -> tc_context

type 'bef judgement =
  | Typed : ('bef, 'aft) Script_typed_ir.descr -> 'bef judgement
  | Failed : {
      descr :
        'aft. 'aft Script_typed_ir.stack_ty ->
        ('bef, 'aft) Script_typed_ir.descr;
    }
      -> 'bef judgement

type unparsing_mode = Optimized | Readable

type type_logger =
  int ->
  (Script.expr * Script.annot) list ->
  (Script.expr * Script.annot) list ->
  unit

(* ---- Sets and Maps -------------------------------------------------------*)

val empty_set : 'a Script_typed_ir.comparable_ty -> 'a Script_typed_ir.set

val set_fold :
  ('elt -> 'acc -> 'acc) -> 'elt Script_typed_ir.set -> 'acc -> 'acc

val set_update : 'a -> bool -> 'a Script_typed_ir.set -> 'a Script_typed_ir.set

val set_mem : 'elt -> 'elt Script_typed_ir.set -> bool

val set_size : 'elt Script_typed_ir.set -> Script_int.n Script_int.num

val empty_map :
  'a Script_typed_ir.comparable_ty -> ('a, 'b) Script_typed_ir.map

val map_fold :
  ('key -> 'value -> 'acc -> 'acc) ->
  ('key, 'value) Script_typed_ir.map ->
  'acc ->
  'acc

val map_update :
  'a ->
  'b option ->
  ('a, 'b) Script_typed_ir.map ->
  ('a, 'b) Script_typed_ir.map

val map_mem : 'key -> ('key, 'value) Script_typed_ir.map -> bool

val map_get : 'key -> ('key, 'value) Script_typed_ir.map -> 'value option

val map_key_ty :
  ('a, 'b) Script_typed_ir.map -> 'a Script_typed_ir.comparable_ty

val map_size : ('a, 'b) Script_typed_ir.map -> Script_int.n Script_int.num

val empty_big_map :
  'a Script_typed_ir.comparable_ty ->
  'b Script_typed_ir.ty ->
  ('a, 'b) Script_typed_ir.big_map

val big_map_mem :
  context ->
  'key ->
  ('key, 'value) Script_typed_ir.big_map ->
  (bool * context) tzresult Lwt.t

val big_map_get :
  context ->
  'key ->
  ('key, 'value) Script_typed_ir.big_map ->
  ('value option * context) tzresult Lwt.t

val big_map_update :
  'key ->
  'value option ->
  ('key, 'value) Script_typed_ir.big_map ->
  ('key, 'value) Script_typed_ir.big_map

val ty_eq :
  context ->
  'ta Script_typed_ir.ty ->
  'tb Script_typed_ir.ty ->
  (('ta Script_typed_ir.ty, 'tb Script_typed_ir.ty) eq * context) tzresult

val compare_comparable : 'a Script_typed_ir.comparable_ty -> 'a -> 'a -> int

val parse_data :
  ?type_logger:type_logger ->
  context ->
  legacy:bool ->
  'a Script_typed_ir.ty ->
  Script.node ->
  ('a * context) tzresult Lwt.t

val unparse_data :
  context ->
  unparsing_mode ->
  'a Script_typed_ir.ty ->
  'a ->
  (Script.node * context) tzresult Lwt.t

val parse_instr :
  ?type_logger:type_logger ->
  tc_context ->
  context ->
  legacy:bool ->
  Script.node ->
  'bef Script_typed_ir.stack_ty ->
  ('bef judgement * context) tzresult Lwt.t

val parse_ty :
  context ->
  legacy:bool ->
  allow_big_map:bool ->
  allow_operation:bool ->
  allow_contract:bool ->
  Script.node ->
  (ex_ty * context) tzresult

val parse_packable_ty :
  context -> legacy:bool -> Script.node -> (ex_ty * context) tzresult

val unparse_ty :
  context -> 'a Script_typed_ir.ty -> (Script.node * context) tzresult Lwt.t

val parse_toplevel :
  legacy:bool ->
  Script.expr ->
  (Script.node * Script.node * Script.node * string option) tzresult

val add_field_annot :
  [`Field_annot of string] option ->
  [`Var_annot of string] option ->
  Script.node ->
  Script.node

val typecheck_code :
  context -> Script.expr -> (type_map * context) tzresult Lwt.t

val typecheck_data :
  ?type_logger:type_logger ->
  context ->
  Script.expr * Script.expr ->
  context tzresult Lwt.t

val parse_script :
  ?type_logger:type_logger ->
  context ->
  legacy:bool ->
  Script.t ->
  (ex_script * context) tzresult Lwt.t

(* Gas accounting may not be perfect in this function, as it is only called by RPCs. *)
val unparse_script :
  context ->
  unparsing_mode ->
  ('a, 'b) Script_typed_ir.script ->
  (Script.t * context) tzresult Lwt.t

val parse_contract :
  legacy:bool ->
  context ->
  Script.location ->
  'a Script_typed_ir.ty ->
  Contract.t ->
  entrypoint:string ->
  (context * 'a Script_typed_ir.typed_contract) tzresult Lwt.t

val parse_contract_for_script :
  legacy:bool ->
  context ->
  Script.location ->
  'a Script_typed_ir.ty ->
  Contract.t ->
  entrypoint:string ->
  (context * 'a Script_typed_ir.typed_contract option) tzresult Lwt.t

val find_entrypoint :
  't Script_typed_ir.ty ->
  root_name:string option ->
  string ->
  ((Script.node -> Script.node) * ex_ty) tzresult

module Entrypoints_map : S.MAP with type key = string

val list_entrypoints :
  't Script_typed_ir.ty ->
  context ->
  root_name:string option ->
  ( Michelson_v1_primitives.prim list list
  * (Michelson_v1_primitives.prim list * Script.node) Entrypoints_map.t )
  tzresult

val pack_data :
  context -> 'a Script_typed_ir.ty -> 'a -> (MBytes.t * context) tzresult Lwt.t

val hash_data :
  context ->
  'a Script_typed_ir.ty ->
  'a ->
  (Script_expr_hash.t * context) tzresult Lwt.t

type big_map_ids

val no_big_map_id : big_map_ids

val collect_big_maps :
  context ->
  'a Script_typed_ir.ty ->
  'a ->
  (big_map_ids * context) tzresult Lwt.t

val list_of_big_map_ids : big_map_ids -> Z.t list

val extract_big_map_diff :
  context ->
  unparsing_mode ->
  temporary:bool ->
  to_duplicate:big_map_ids ->
  to_update:big_map_ids ->
  'a Script_typed_ir.ty ->
  'a ->
  ('a * Contract.big_map_diff option * context) tzresult Lwt.t
