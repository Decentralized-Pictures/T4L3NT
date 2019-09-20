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
open Script
open Script_tc_errors

(* Helpers for encoding *)
let type_map_enc =
  let open Data_encoding in
  let stack_enc = list (tup2 Script.expr_encoding (list string)) in
  list
    (conv
       (fun (loc, (bef, aft)) -> (loc, bef, aft))
       (fun (loc, bef, aft) -> (loc, (bef, aft)))
       (obj3
          (req "location" Script.location_encoding)
          (req "stack_before" stack_enc)
          (req "stack_after" stack_enc)))

let stack_ty_enc =
  let open Data_encoding in
  (list
     (obj2
        (req "type" Script.expr_encoding)
        (dft "annots" (list string) [])))

(* main registration *)
let () =
  let open Data_encoding in
  let located enc =
    merge_objs
      (obj1 (req "location" Script.location_encoding))
      enc in
  let arity_enc =
    int8 in
  let namespace_enc =
    def "primitiveNamespace"
      ~title: "Primitive namespace"
      ~description:
        "One of the three possible namespaces of primitive \
         (data constructor, type name or instruction)." @@
    string_enum [ "type", Type_namespace ;
                  "constant", Constant_namespace ;
                  "instruction", Instr_namespace ] in
  let kind_enc =
    def "expressionKind"
      ~title: "Expression kind"
      ~description:
        "One of the four possible kinds of expression \
         (integer, string, primitive application or sequence)." @@
    string_enum [ "integer", Int_kind ;
                  "string", String_kind ;
                  "bytes", Bytes_kind ;
                  "primitiveApplication", Prim_kind ;
                  "sequence", Seq_kind ] in
  (* -- Structure errors ---------------------- *)
  (* Invalid arity *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_arity"
    ~title: "Invalid arity"
    ~description:
      "In a script or data expression, a primitive was applied \
       to an unsupported number of arguments."
    (located (obj3
                (req "primitive_name" Script.prim_encoding)
                (req "expected_arity" arity_enc)
                (req "wrong_arity" arity_enc)))
    (function
      | Invalid_arity (loc, name, exp, got) ->
          Some (loc, (name, exp, got))
      | _ -> None)
    (fun (loc, (name, exp, got)) ->
       Invalid_arity (loc, name, exp, got)) ;
  (* Missing field *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.missing_script_field"
    ~title:"Script is missing a field (parse error)"
    ~description:
      "When parsing script, a field was expected, but not provided"
    (obj1 (req "prim" prim_encoding))
    (function Missing_field prim -> Some prim | _ -> None)
    (fun prim -> Missing_field prim) ;
  (* Invalid primitive *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_primitive"
    ~title: "Invalid primitive"
    ~description:
      "In a script or data expression, a primitive was unknown."
    (located (obj2
                (dft "expected_primitive_names" (list prim_encoding) [])
                (req "wrong_primitive_name" prim_encoding)))
    (function
      | Invalid_primitive (loc, exp, got) -> Some (loc, (exp, got))
      | _ -> None)
    (fun (loc, (exp, got)) ->
       Invalid_primitive (loc, exp, got)) ;
  (* Invalid kind *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_expression_kind"
    ~title: "Invalid expression kind"
    ~description:
      "In a script or data expression, an expression was of the wrong kind \
       (for instance a string where only a primitive applications can appear)."
    (located (obj2
                (req "expected_kinds" (list kind_enc))
                (req "wrong_kind" kind_enc)))
    (function
      | Invalid_kind (loc, exp, got) -> Some (loc, (exp, got))
      | _ -> None)
    (fun (loc, (exp, got)) ->
       Invalid_kind (loc, exp, got)) ;
  (* Invalid namespace *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_primitive_namespace"
    ~title: "Invalid primitive namespace"
    ~description:
      "In a script or data expression, a primitive was of the wrong namespace."
    (located (obj3
                (req "primitive_name" prim_encoding)
                (req "expected_namespace" namespace_enc)
                (req "wrong_namespace" namespace_enc)))
    (function
      | Invalid_namespace (loc, name, exp, got) -> Some (loc, (name, exp, got))
      | _ -> None)
    (fun (loc, (name, exp, got)) ->
       Invalid_namespace (loc, name, exp, got)) ;
  (* Duplicate field *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.duplicate_script_field"
    ~title: "Script has a duplicated field (parse error)"
    ~description:
      "When parsing script, a field was found more than once"
    (obj2
       (req "loc" location_encoding)
       (req "prim" prim_encoding))
    (function Duplicate_field (loc, prim) -> Some (loc, prim) | _ -> None)
    (fun (loc, prim) -> Duplicate_field (loc, prim)) ;
  (* Unexpected big_map *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.unexpected_bigmap"
    ~title: "Big map in unauthorized position (type error)"
    ~description:
      "When parsing script, a big_map type was found in a position \
       where it could end up stored inside a big_map, which is \
       forbidden for now."
    (obj1
       (req "loc" location_encoding))
    (function Unexpected_big_map loc -> Some loc | _ -> None)
    (fun loc -> Unexpected_big_map loc) ;
  (* Unexpected operation *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.unexpected_operation"
    ~title: "Operation in unauthorized position (type error)"
    ~description:
      "When parsing script, an operation type was found \
       in the storage or parameter field."
    (obj1
       (req "loc" location_encoding))
    (function Unexpected_operation loc -> Some loc | _ -> None)
    (fun loc -> Unexpected_operation loc) ;
  (* No such entrypoint *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.no_such_entrypoint"
    ~title: "No such entrypoint (type error)"
    ~description:
      "An entrypoint was not found when calling a contract."
    (obj1
       (req "entrypoint" string))
    (function No_such_entrypoint entrypoint -> Some entrypoint | _ -> None)
    (fun entrypoint -> No_such_entrypoint entrypoint) ;
  (* Unreachable entrypoint *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.unreachable_entrypoint"
    ~title: "Unreachable entrypoint (type error)"
    ~description:
      "An entrypoint in the contract is not reachable."
    (obj1
       (req "path" (list prim_encoding)))
    (function Unreachable_entrypoint path -> Some path | _ -> None)
    (fun path -> Unreachable_entrypoint path) ;
  (* Duplicate entrypoint *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.duplicate_entrypoint"
    ~title: "Duplicate entrypoint (type error)"
    ~description:
      "Two entrypoints have the same name."
    (obj1
       (req "path" string))
    (function Duplicate_entrypoint entrypoint -> Some entrypoint | _ -> None)
    (fun entrypoint -> Duplicate_entrypoint entrypoint) ;
  (* Entrypoint name too long *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.entrypoint_name_too_long"
    ~title: "Entrypoint name too long (type error)"
    ~description:
      "An entrypoint name exceeds the maximum length of 31 characters."
    (obj1
       (req "name" string))
    (function Entrypoint_name_too_long entrypoint -> Some entrypoint | _ -> None)
    (fun entrypoint -> Entrypoint_name_too_long entrypoint) ;
  (* Unexpected contract *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.unexpected_contract"
    ~title: "Contract in unauthorized position (type error)"
    ~description:
      "When parsing script, a contract type was found \
       in the storage or parameter field."
    (obj1
       (req "loc" location_encoding))
    (function Unexpected_contract loc -> Some loc | _ -> None)
    (fun loc -> Unexpected_contract loc) ;
  (* -- Value typing errors ---------------------- *)
  (* Unordered map keys *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.unordered_map_literal"
    ~title:"Invalid map key order"
    ~description:"Map keys must be in strictly increasing order"
    (obj2
       (req "location" Script.location_encoding)
       (req "item" Script.expr_encoding))
    (function
      | Unordered_map_keys (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Unordered_map_keys (loc, expr));
  (* Duplicate map keys *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.duplicate_map_keys"
    ~title:"Duplicate map keys"
    ~description:"Map literals cannot contain duplicated keys"
    (obj2
       (req "location" Script.location_encoding)
       (req "item" Script.expr_encoding))
    (function
      | Duplicate_map_keys (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Duplicate_map_keys (loc, expr));
  (* Unordered set values *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.unordered_set_literal"
    ~title:"Invalid set value order"
    ~description:"Set values must be in strictly increasing order"
    (obj2
       (req "location" Script.location_encoding)
       (req "value" Script.expr_encoding))
    (function
      | Unordered_set_values (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Unordered_set_values (loc, expr));
  (* Duplicate set values *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.duplicate_set_values_in_literal"
    ~title:"Sets literals cannot contain duplicate elements"
    ~description:"Set literals cannot contain duplicate elements, \
                  but a duplicae was found while parsing."
    (obj2
       (req "location" Script.location_encoding)
       (req "value" Script.expr_encoding))
    (function
      | Duplicate_set_values (loc, expr) -> Some (loc, expr)
      | _ -> None)
    (fun (loc, expr) -> Duplicate_set_values (loc, expr));
  (* -- Instruction typing errors ------------- *)
  (* Fail not in tail position *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.fail_not_in_tail_position"
    ~title: "FAIL not in tail position"
    ~description:
      "There is non trivial garbage code after a FAIL instruction."
    (located empty)
    (function
      | Fail_not_in_tail_position loc -> Some (loc, ())
      | _ -> None)
    (fun (loc, ()) ->
       Fail_not_in_tail_position loc) ;
  (* Undefined binary operation *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.undefined_binop"
    ~title: "Undefined binop"
    ~description:
      "A binary operation is called on operands of types \
       over which it is not defined."
    (located (obj3
                (req "operator_name" prim_encoding)
                (req "wrong_left_operand_type" Script.expr_encoding)
                (req "wrong_right_operand_type" Script.expr_encoding)))
    (function
      | Undefined_binop (loc, n, tyl, tyr) ->
          Some (loc, (n, tyl, tyr))
      | _ -> None)
    (fun (loc, (n, tyl, tyr)) ->
       Undefined_binop (loc, n, tyl, tyr)) ;
  (* Undefined unary operation *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.undefined_unop"
    ~title: "Undefined unop"
    ~description:
      "A unary operation is called on an operand of type \
       over which it is not defined."
    (located (obj2
                (req "operator_name" prim_encoding)
                (req "wrong_operand_type" Script.expr_encoding)))
    (function
      | Undefined_unop (loc, n, ty) ->
          Some (loc, (n, ty))
      | _ -> None)
    (fun (loc, (n, ty)) ->
       Undefined_unop (loc, n, ty)) ;
  (* Bad return *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.bad_return"
    ~title: "Bad return"
    ~description:
      "Unexpected stack at the end of a lambda or script."
    (located (obj2
                (req "expected_return_type" Script.expr_encoding)
                (req "wrong_stack_type" stack_ty_enc)))
    (function
      | Bad_return (loc, sty, ty) -> Some (loc, (ty, sty))
      | _ -> None)
    (fun (loc, (ty, sty)) ->
       Bad_return (loc, sty, ty)) ;
  (* Bad stack *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.bad_stack"
    ~title: "Bad stack"
    ~description:
      "The stack has an unexpected length or contents."
    (located (obj3
                (req "primitive_name" prim_encoding)
                (req "relevant_stack_portion" int16)
                (req "wrong_stack_type" stack_ty_enc)))
    (function
      | Bad_stack (loc, name, s, sty) -> Some (loc, (name, s, sty))
      | _ -> None)
    (fun (loc, (name, s, sty)) ->
       Bad_stack (loc, name, s, sty)) ;
  (* Inconsistent annotations *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.inconsistent_annotations"
    ~title:"Annotations inconsistent between branches"
    ~description:"The annotations on two types could not be merged"
    (obj2
       (req "annot1" string)
       (req "annot2" string))
    (function Inconsistent_annotations (annot1, annot2) -> Some (annot1, annot2)
            | _ -> None)
    (fun (annot1, annot2) -> Inconsistent_annotations (annot1, annot2)) ;
  (* Inconsistent field annotations *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.inconsistent_field_annotations"
    ~title:"Annotations for field accesses is inconsistent"
    ~description:"The specified field does not match the field annotation in the type"
    (obj2
       (req "annot1" string)
       (req "annot2" string))
    (function Inconsistent_field_annotations (annot1, annot2) -> Some (annot1, annot2)
            | _ -> None)
    (fun (annot1, annot2) -> Inconsistent_field_annotations (annot1, annot2)) ;
  (* Inconsistent type annotations *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.inconsistent_type_annotations"
    ~title:"Types contain inconsistent annotations"
    ~description:"The two types contain annotations that do not match"
    (located (obj2
                (req "type1" Script.expr_encoding)
                (req "type2" Script.expr_encoding)))
    (function
      | Inconsistent_type_annotations (loc, ty1, ty2) -> Some (loc, (ty1, ty2))
      | _ -> None)
    (fun (loc, (ty1, ty2)) -> Inconsistent_type_annotations (loc, ty1, ty2)) ;
  (* Unexpected annotation *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.unexpected_annotation"
    ~title:"An annotation was encountered where no annotation is expected"
    ~description:"A node in the syntax tree was impropperly annotated"
    (located empty)
    (function Unexpected_annotation loc -> Some (loc, ())
            | _ -> None)
    (fun (loc, ()) -> Unexpected_annotation loc);
  (* Ungrouped annotations *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.ungrouped_annotations"
    ~title:"Annotations of the same kind were found spread apart"
    ~description:"Annotations of the same kind must be grouped"
    (located empty)
    (function Ungrouped_annotations loc -> Some (loc, ())
            | _ -> None)
    (fun (loc, ()) -> Ungrouped_annotations loc);
  (* Unmatched branches *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.unmatched_branches"
    ~title: "Unmatched branches"
    ~description:
      "At the join point at the end of two code branches \
       the stacks have inconsistent lengths or contents."
    (located (obj2
                (req "first_stack_type" stack_ty_enc)
                (req "other_stack_type" stack_ty_enc)))
    (function
      | Unmatched_branches (loc, stya, styb) ->
          Some (loc, (stya, styb))
      | _ -> None)
    (fun (loc, (stya, styb)) ->
       Unmatched_branches (loc, stya, styb)) ;
  (* Bad stack item *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.bad_stack_item"
    ~title: "Bad stack item"
    ~description:
      "The type of a stack item is unexpected \
       (this error is always accompanied by a more precise one)."
    (obj1 (req "item_level" int16))
    (function
      | Bad_stack_item n -> Some n
      | _ -> None)
    (fun n ->
       Bad_stack_item n) ;
  (* SELF in lambda *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.self_in_lambda"
    ~title: "SELF instruction in lambda"
    ~description:
      "A SELF instruction was encountered in a lambda expression."
    (located empty)
    (function
      | Self_in_lambda loc -> Some (loc, ())
      | _ -> None)
    (fun (loc, ()) ->
       Self_in_lambda loc) ;
  (* Bad stack length *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.inconsistent_stack_lengths"
    ~title: "Inconsistent stack lengths"
    ~description:
      "A stack was of an unexpected length \
       (this error is always in the context of a located error)."
    empty
    (function
      | Bad_stack_length -> Some ()
      | _ -> None)
    (fun () ->
       Bad_stack_length) ;
  (* -- Value typing errors ------------------- *)
  (* Invalid constant *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_constant"
    ~title: "Invalid constant"
    ~description:
      "A data expression was invalid for its expected type."
    (located (obj2
                (req "expected_type" Script.expr_encoding)
                (req "wrong_expression" Script.expr_encoding)))
    (function
      | Invalid_constant (loc, expr, ty) ->
          Some (loc, (ty, expr))
      | _ -> None)
    (fun (loc, (ty, expr)) ->
       Invalid_constant (loc, expr, ty)) ;
  (* Invalid syntactic constant *)
  register_error_kind
    `Permanent
    ~id:"invalidSyntacticConstantError"
    ~title: "Invalid constant (parse error)"
    ~description:
      "A compile-time constant was invalid for its expected form."
    (located (obj2
                (req "expectedForm" Script.expr_encoding)
                (req "wrongExpression" Script.expr_encoding)))
    (function
      | Invalid_constant (loc, expr, ty) ->
          Some (loc, (ty, expr))
      | _ -> None)
    (fun (loc, (ty, expr)) ->
       Invalid_constant (loc, expr, ty)) ;
  (* Invalid contract *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_contract"
    ~title: "Invalid contract"
    ~description:
      "A script or data expression references a contract that does not \
       exist or assumes a wrong type for an existing contract."
    (located (obj1 (req "contract" Contract.encoding)))
    (function
      | Invalid_contract (loc, c) ->
          Some (loc, c)
      | _ -> None)
    (fun (loc, c) ->
       Invalid_contract (loc, c)) ;
  (* Invalid big_map *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_big_map"
    ~title: "Invalid big_map"
    ~description:
      "A script or data expression references a big_map that does not \
       exist or assumes a wrong type for an existing big_map."
    (located (obj1 (req "big_map" z)))
    (function
      | Invalid_big_map (loc, c) ->
          Some (loc, c)
      | _ -> None)
    (fun (loc, c) ->
       Invalid_big_map (loc, c)) ;
  (* Comparable type expected *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.comparable_type_expected"
    ~title: "Comparable type expected"
    ~description:
      "A non comparable type was used in a place where \
       only comparable types are accepted."
    (located (obj1 (req "wrong_type" Script.expr_encoding)))
    (function
      | Comparable_type_expected (loc, ty) -> Some (loc, ty)
      | _ -> None)
    (fun (loc, ty) ->
       Comparable_type_expected (loc, ty)) ;
  (* Inconsistent types *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.inconsistent_types"
    ~title: "Inconsistent types"
    ~description:
      "This is the basic type clash error, \
       that appears in several places where the equality of \
       two types have to be proven, it is always accompanied \
       with another error that provides more context."
    (obj2
       (req "first_type" Script.expr_encoding)
       (req "other_type" Script.expr_encoding))
    (function
      | Inconsistent_types (tya, tyb) -> Some (tya, tyb)
      | _ -> None)
    (fun (tya, tyb) -> Inconsistent_types (tya, tyb)) ;
  (* -- Instruction typing errors ------------------- *)
  (* Invalid map body *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_map_body"
    ~title: "Invalid map body"
    ~description:
      "The body of a map block did not match the expected type"
    (obj2
       (req "loc" Script.location_encoding)
       (req "body_type" stack_ty_enc))
    (function
      | Invalid_map_body (loc, stack) -> Some (loc, stack)
      | _ -> None)
    (fun (loc, stack) -> Invalid_map_body (loc, stack)) ;
  (* Invalid map block FAIL *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_map_block_fail"
    ~title:"FAIL instruction occurred as body of map block"
    ~description:"FAIL cannot be the only instruction in the body. \
                  The propper type of the return list cannot be inferred."
    (obj1 (req "loc" Script.location_encoding))
    (function
      | Invalid_map_block_fail loc -> Some loc
      | _ -> None)
    (fun loc -> Invalid_map_block_fail loc) ;
  (* Invalid ITER body *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.invalid_iter_body"
    ~title:"ITER body returned wrong stack type"
    ~description:"The body of an ITER instruction \
                  must result in the same stack type as before \
                  the ITER."
    (obj3
       (req "loc" Script.location_encoding)
       (req "bef_stack" stack_ty_enc)
       (req "aft_stack" stack_ty_enc))
    (function
      | Invalid_iter_body (loc, bef, aft) -> Some (loc, bef, aft)
      | _ -> None)
    (fun (loc, bef, aft) -> Invalid_iter_body (loc, bef, aft)) ;
  (* Type too large *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.type_too_large"
    ~title:"Stack item type too large"
    ~description:"An instruction generated a type larger than the limit."
    (obj3
       (req "loc" Script.location_encoding)
       (req "type_size" uint16)
       (req "maximum_type_size" uint16))
    (function
      | Type_too_large (loc, ts, maxts) -> Some (loc, ts, maxts)
      | _ -> None)
    (fun (loc, ts, maxts) -> Type_too_large (loc, ts, maxts)) ;
  (* -- Toplevel errors ------------------- *)
  (* Ill typed data *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.ill_typed_data"
    ~title: "Ill typed data"
    ~description:
      "The toplevel error thrown when trying to typecheck \
       a data expression against a given type \
       (always followed by more precise errors)."
    (obj3
       (opt "identifier" string)
       (req "expected_type" Script.expr_encoding)
       (req "ill_typed_expression" Script.expr_encoding))
    (function
      | Ill_typed_data (name, expr, ty) -> Some (name, ty,  expr)
      | _ -> None)
    (fun (name, ty,  expr) -> Ill_typed_data (name, expr, ty)) ;
  (* Ill formed type *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.ill_formed_type"
    ~title: "Ill formed type"
    ~description:
      "The toplevel error thrown when trying to parse a type expression \
       (always followed by more precise errors)."
    (obj3
       (opt "identifier" string)
       (req "ill_formed_expression" Script.expr_encoding)
       (req "location" Script.location_encoding))
    (function
      | Ill_formed_type (name, expr, loc) -> Some (name, expr, loc)
      | _ -> None)
    (fun (name, expr, loc) ->
       Ill_formed_type (name, expr, loc)) ;
  (* Ill typed contract *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.ill_typed_contract"
    ~title: "Ill typed contract"
    ~description:
      "The toplevel error thrown when trying to typecheck \
       a contract code against given input, output and storage types \
       (always followed by more precise errors)."
    (obj2
       (req "ill_typed_code" Script.expr_encoding)
       (req "type_map" type_map_enc))
    (function
      | Ill_typed_contract (expr, type_map) ->
          Some (expr, type_map)
      | _ -> None)
    (fun (expr, type_map) ->
       Ill_typed_contract (expr, type_map)) ;
  (* Cannot serialize error *)
  register_error_kind
    `Temporary
    ~id:"michelson_v1.cannot_serialize_error"
    ~title:"Not enough gas to serialize error"
    ~description:"The error was too big to be serialized with \
                  the provided gas"
    Data_encoding.empty
    (function Cannot_serialize_error -> Some () | _ -> None)
    (fun () -> Cannot_serialize_error) ;
  (* Deprecated instruction *)
  register_error_kind
    `Permanent
    ~id:"michelson_v1.deprecated_instruction"
    ~title:"Script is using a deprecated instruction"
    ~description:
      "A deprecated instruction usage is disallowed in newly created contracts"
    (obj1 (req "prim" prim_encoding))
    (function Deprecated_instruction prim -> Some prim | _ -> None)
    (fun prim -> Deprecated_instruction prim) ;
