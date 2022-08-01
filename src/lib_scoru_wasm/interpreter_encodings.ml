(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Trili Tech  <contact@trili.tech>                       *)
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

open Tezos_webassembly_interpreter
open Data_encoding_utils

let string_enum cases =
  let open Data_encoding in
  match cases with
  | [(title, value)] -> conv (fun _ -> ()) (fun () -> value) (constant title)
  | cases -> string_enum cases

module Types = struct
  open Types

  let i32_case f = ("i32", f I32Type)

  let i64_case f = ("i64", f I64Type)

  let num_type_cases f = [i32_case f; i64_case f]

  let num_type_encoding = string_enum (num_type_cases Fun.id)

  let v128_case f = ("v128", f V128Type)

  let vec_type_cases f = [v128_case f]

  let vec_type_encoding = string_enum (vec_type_cases Fun.id)

  let funcref_case f = ("funcref", f FuncRefType)

  let externref_case f = ("externref", f ExternRefType)

  let ref_type_cases f = [funcref_case f; externref_case f]

  let ref_type_encoding = string_enum (ref_type_cases Fun.id)

  let value_type_cases f =
    num_type_cases (fun nt -> f (NumType nt))
    @ vec_type_cases (fun vt -> f (VecType vt))
    @ ref_type_cases (fun rt -> f (RefType rt))

  let value_type_encoding = string_enum (value_type_cases Fun.id)

  let result_type_encoding =
    (* : #3076
       Once the AST is adapted this must not be a list but a lazy structure. *)
    Data_encoding.list value_type_encoding

  let func_type_encoding ~params_encoding ~result_encoding =
    let open Data_encoding in
    conv
      (fun (FuncType (params, result)) -> (params, result))
      (fun (params, result) -> FuncType (params, result))
      (obj2 (req "params" params_encoding) (req "result" result_encoding))

  let mutability_encoding =
    string_enum [("mutable", Mutable); ("immutable", Immutable)]

  let pack_size_encoding =
    string_enum
      [
        ("Pack8", Pack8);
        ("Pack16", Pack16);
        ("Pack32", Pack32);
        ("Pack64", Pack64);
      ]

  let pack_shape_encoding =
    string_enum
      [("Pack8x8", Pack8x8); ("Pack16x4", Pack16x4); ("Pack32x2", Pack32x2)]

  let extension_encoding = string_enum [("SX", SX); ("ZX", ZX)]

  let vec_extension_encoding =
    let open Data_encoding in
    union_incr
      [
        case_incr
          "ExtLane"
          (obj2
             (req "pack_shape" pack_shape_encoding)
             (req "extension" extension_encoding))
          (function ExtLane (x, y) -> Some (x, y) | _ -> None)
          (fun (x, y) -> ExtLane (x, y));
        unit_case_incr "ExtSplat" ExtSplat;
        unit_case_incr "ExtZero" ExtZero;
      ]
end

module Values = struct
  open Values

  let op_encoding i32 i64 =
    union_incr
      [
        case_incr
          "I32"
          i32
          (function I32 x -> Some x | _ -> None)
          (fun x -> I32 x);
        case_incr
          "I64"
          i64
          (function I64 x -> Some x | _ -> None)
          (fun x -> I64 x);
      ]

  let vecop_encoding v128 =
    union_incr
      [case_incr "V128" v128 (function V128 x -> Some x) (fun x -> V128 x)]

  let num_encoding : num Data_encoding.t =
    let open Data_encoding in
    op_encoding int32 int64

  let vec_encoding =
    let open Data_encoding in
    vecop_encoding (conv V128.to_bits V128.of_bits string)
end

module V128 = struct
  open V128

  let laneop_encoding i8x16 i16x8 i32x4 i64x2 =
    union_incr
      [
        case_incr
          "I8x16"
          i8x16
          (function I8x16 x -> Some x | _ -> None)
          (fun x -> I8x16 x);
        case_incr
          "I16x8"
          i16x8
          (function I16x8 x -> Some x | _ -> None)
          (fun x -> I16x8 x);
        case_incr
          "I32x4"
          i32x4
          (function I32x4 x -> Some x | _ -> None)
          (fun x -> I32x4 x);
        case_incr
          "I64x2"
          i64x2
          (function I64x2 x -> Some x | _ -> None)
          (fun x -> I64x2 x);
      ]
end

module Ast = struct
  open Ast

  module IntOp = struct
    open IntOp

    let unop_encoding =
      union_incr
        [
          unit_case_incr "Clz" Clz;
          unit_case_incr "Ctz" Ctz;
          unit_case_incr "Popcnt" Popcnt;
          case_incr
            "ExtendS"
            Types.pack_size_encoding
            (function ExtendS x -> Some x | _ -> None)
            (fun x -> ExtendS x);
        ]

    let binop_encoding =
      union_incr
        [
          unit_case_incr "Add" Add;
          unit_case_incr "Sub" Sub;
          unit_case_incr "Mul" Mul;
          unit_case_incr "DivS" DivS;
          unit_case_incr "DivU" DivU;
          unit_case_incr "RemS" RemS;
          unit_case_incr "RemU" RemU;
          unit_case_incr "And" And;
          unit_case_incr "Or" Or;
          unit_case_incr "Xor" Xor;
          unit_case_incr "Shl" Shl;
          unit_case_incr "ShrS" ShrS;
          unit_case_incr "ShrU" ShrU;
          unit_case_incr "Rotl" Rotl;
          unit_case_incr "Rotr" Rotr;
        ]

    let testop_encoding = union_incr [unit_case_incr "Eqz" Ast.IntOp.Eqz]

    let relop_encoding =
      union_incr
        [
          unit_case_incr "Eq" Eq;
          unit_case_incr "Ne" Ne;
          unit_case_incr "LtS" LtS;
          unit_case_incr "LtU" LtU;
          unit_case_incr "GtS" GtS;
          unit_case_incr "GtU" GtU;
          unit_case_incr "LeS" LeS;
          unit_case_incr "LeU" LeU;
          unit_case_incr "GeS" GeS;
          unit_case_incr "GeU" GeU;
        ]

    let cvtop_encoding =
      union_incr
        [
          unit_case_incr "ExtendSI32" ExtendSI32;
          unit_case_incr "ExtendUI32" ExtendUI32;
          unit_case_incr "WrapI64" WrapI64;
          unit_case_incr "TruncSF32" TruncSF32;
          unit_case_incr "TruncUF32" TruncUF32;
          unit_case_incr "TruncSF64" TruncSF64;
          unit_case_incr "TruncUF64" TruncUF64;
          unit_case_incr "TruncSatSF32" TruncSatSF32;
          unit_case_incr "TruncSatUF32" TruncSatUF32;
          unit_case_incr "TruncSatSF64" TruncSatSF64;
          unit_case_incr "TruncSatUF64" TruncSatUF64;
          unit_case_incr "ReinterpretFloat" ReinterpretFloat;
        ]
  end

  module V128Op = struct
    open V128Op

    let itestop_encoding = union_incr [unit_case_incr "AllTrue" AllTrue]

    let iunop_encoding =
      union_incr
        [
          unit_case_incr "Abs" (Abs : iunop);
          unit_case_incr "Neg" (Neg : iunop);
          unit_case_incr "Popcnt" Popcnt;
        ]

    let ibinop_encoding =
      let open Data_encoding in
      union_incr
        [
          unit_case_incr "Add" (Add : ibinop);
          unit_case_incr "Sub" (Sub : ibinop);
          unit_case_incr "Mul" (Mul : ibinop);
          unit_case_incr "MinS" MinS;
          unit_case_incr "MinU" MinU;
          unit_case_incr "MaxS" MaxS;
          unit_case_incr "MaxU" MaxU;
          unit_case_incr "AvgrU" AvgrU;
          unit_case_incr "AddSatS" AddSatS;
          unit_case_incr "AddSatU" AddSatU;
          unit_case_incr "SubSatS" SubSatS;
          unit_case_incr "SubSatU" SubSatU;
          unit_case_incr "DotS" DotS;
          unit_case_incr "Q15MulRSatS" Q15MulRSatS;
          unit_case_incr "ExtMulLowS" ExtMulLowS;
          unit_case_incr "ExtMulHighS" ExtMulHighS;
          unit_case_incr "ExtMulLowU" ExtMulLowU;
          unit_case_incr "ExtMulHighU" ExtMulHighU;
          unit_case_incr "Swizzle" Swizzle;
          case_incr
            "Shuffle"
            (list int8)
            (function Shuffle ints -> Some ints | _ -> None)
            (fun ints -> Shuffle ints);
          unit_case_incr "NarrowS" NarrowS;
          unit_case_incr "NarrowU" NarrowU;
        ]

    let irelop_encoding =
      union_incr
        [
          unit_case_incr "Eq" (Eq : irelop);
          unit_case_incr "Ne" (Ne : irelop);
          unit_case_incr "LtS" LtS;
          unit_case_incr "LtU" LtU;
          unit_case_incr "LeS" LeS;
          unit_case_incr "LeU" LeU;
          unit_case_incr "GtS" GtS;
          unit_case_incr "GtU" GtU;
          unit_case_incr "GeS" GeS;
          unit_case_incr "GeU" GeU;
        ]

    let icvtop_encoding =
      union_incr
        [
          unit_case_incr "ExtendLowS" ExtendLowS;
          unit_case_incr "ExtendLowU" ExtendLowU;
          unit_case_incr "ExtendHighS" ExtendHighS;
          unit_case_incr "ExtendHighU" ExtendHighU;
          unit_case_incr "ExtAddPairwiseS" ExtAddPairwiseS;
          unit_case_incr "ExtAddPairwiseU" ExtAddPairwiseU;
          unit_case_incr "TruncSatSF32x4" TruncSatSF32x4;
          unit_case_incr "TruncSatUF32x4" TruncSatUF32x4;
          unit_case_incr "TruncSatSZeroF64x2" TruncSatSZeroF64x2;
          unit_case_incr "TruncSatUZeroF64x2" TruncSatUZeroF64x2;
        ]

    let ishiftop_encoding =
      union_incr
        [
          unit_case_incr "Shl" Shl;
          unit_case_incr "ShrS" ShrS;
          unit_case_incr "ShrU" ShrU;
        ]

    let ibitmaskop_encoding = union_incr [unit_case_incr "Bitmask" Bitmask]

    let vtestop_encoding = union_incr [unit_case_incr "AnyTrue" AnyTrue]

    let vunop_encoding = union_incr [unit_case_incr "Not" Not]

    let vbinop_encoding =
      union_incr
        [
          unit_case_incr "And" And;
          unit_case_incr "Or" Or;
          unit_case_incr "Xor" Xor;
          unit_case_incr "AndNot" AndNot;
        ]

    let vternop_encoding = union_incr [unit_case_incr "Bitselect" Bitselect]

    let testop_encoding : testop Data_encoding.t =
      V128.laneop_encoding
        itestop_encoding
        itestop_encoding
        itestop_encoding
        itestop_encoding

    let unop_encoding : unop Data_encoding.t =
      V128.laneop_encoding
        iunop_encoding
        iunop_encoding
        iunop_encoding
        iunop_encoding

    let binop_encoding : binop Data_encoding.t =
      V128.laneop_encoding
        ibinop_encoding
        ibinop_encoding
        ibinop_encoding
        ibinop_encoding

    let relop_encoding : relop Data_encoding.t =
      V128.laneop_encoding
        irelop_encoding
        irelop_encoding
        irelop_encoding
        irelop_encoding

    let cvtop_encoding : cvtop Data_encoding.t =
      V128.laneop_encoding
        icvtop_encoding
        icvtop_encoding
        icvtop_encoding
        icvtop_encoding

    let shiftop_encoding : shiftop Data_encoding.t =
      V128.laneop_encoding
        ishiftop_encoding
        ishiftop_encoding
        ishiftop_encoding
        ishiftop_encoding

    let bitmaskop_encoding : bitmaskop Data_encoding.t =
      V128.laneop_encoding
        ibitmaskop_encoding
        ibitmaskop_encoding
        ibitmaskop_encoding
        ibitmaskop_encoding

    let nsplatop_encoding = union_incr [unit_case_incr "Splat" Splat]

    let nextractop_encoding inner =
      let open Data_encoding in
      union_incr
        [
          case_incr
            "Extract"
            (tup2 Data_encoding.int31 inner)
            (function Extract (x, y) -> Some (x, y))
            (fun (x, y) -> Extract (x, y));
        ]

    let nreplaceop_encoding =
      union_incr
        [
          case_incr
            "Replace"
            Data_encoding.int31
            (function Replace x -> Some x)
            (fun x -> Replace x);
        ]

    let splatop_encoding : splatop Data_encoding.t =
      V128.laneop_encoding
        nsplatop_encoding
        nsplatop_encoding
        nsplatop_encoding
        nsplatop_encoding

    let extractop_encoding : extractop Data_encoding.t =
      let open Data_encoding in
      V128.laneop_encoding
        (nextractop_encoding Types.extension_encoding)
        (nextractop_encoding Types.extension_encoding)
        (nextractop_encoding unit)
        (nextractop_encoding unit)

    let replaceop_encoding : replaceop Data_encoding.t =
      V128.laneop_encoding
        nreplaceop_encoding
        nreplaceop_encoding
        nreplaceop_encoding
        nreplaceop_encoding
  end

  let testop_encoding : Ast.testop Data_encoding.t =
    Values.op_encoding IntOp.testop_encoding IntOp.testop_encoding

  let unop_encoding : Ast.unop Data_encoding.t =
    Values.op_encoding IntOp.unop_encoding IntOp.unop_encoding

  let binop_encoding : Ast.binop Data_encoding.t =
    Values.op_encoding IntOp.binop_encoding IntOp.binop_encoding

  let relop_encoding : Ast.relop Data_encoding.t =
    Values.op_encoding IntOp.relop_encoding IntOp.relop_encoding

  let cvtop_encoding : Ast.cvtop Data_encoding.t =
    Values.op_encoding IntOp.cvtop_encoding IntOp.cvtop_encoding

  let vec_testop_encoding = Values.vecop_encoding V128Op.testop_encoding

  let vec_relop_encoding = Values.vecop_encoding V128Op.relop_encoding

  let vec_unop_encoding = Values.vecop_encoding V128Op.unop_encoding

  let vec_binop_encoding = Values.vecop_encoding V128Op.binop_encoding

  let vec_cvtop_encoding = Values.vecop_encoding V128Op.cvtop_encoding

  let vec_shiftop_encoding = Values.vecop_encoding V128Op.shiftop_encoding

  let vec_bitmaskop_encoding = Values.vecop_encoding V128Op.bitmaskop_encoding

  let vec_vtestop_encoding = Values.vecop_encoding V128Op.vtestop_encoding

  let vec_vunop_encoding = Values.vecop_encoding V128Op.vunop_encoding

  let vec_vbinop_encoding = Values.vecop_encoding V128Op.vbinop_encoding

  let vec_vternop_encoding = Values.vecop_encoding V128Op.vternop_encoding

  let vec_splatop_encoding = Values.vecop_encoding V128Op.splatop_encoding

  let vec_extractop_encoding = Values.vecop_encoding V128Op.extractop_encoding

  let vec_replaceop_encoding = Values.vecop_encoding V128Op.replaceop_encoding

  let memop_encoding type_ pack =
    let open Data_encoding in
    conv
      (fun Ast.{ty; align; offset; pack} -> (ty, align, offset, pack))
      (fun (ty, align, offset, pack) -> Ast.{ty; align; offset; pack})
      (obj4
         (req "type" type_)
         (req "align" int31)
         (req "offset" int32)
         (req "pack" pack))

  let loadop_encoding =
    let open Data_encoding in
    memop_encoding
      Types.num_type_encoding
      (option
         (obj2
            (req "pack_size" Types.pack_size_encoding)
            (req "extension" Types.extension_encoding)))

  let storeop_encoding =
    let open Data_encoding in
    memop_encoding Types.num_type_encoding (option Types.pack_size_encoding)

  let vec_loadop_encoding =
    let open Data_encoding in
    memop_encoding
      Types.vec_type_encoding
      (option
         (obj2
            (req "pack_size" Types.pack_size_encoding)
            (req "extension" Types.vec_extension_encoding)))

  let vec_storeop_encoding =
    let open Data_encoding in
    memop_encoding Types.vec_type_encoding unit

  let vec_laneop_encoding =
    let open Data_encoding in
    conv
      (fun (x, y) -> (x, y))
      (fun (x, y) -> (x, y))
      (obj2
         (req
            "op"
            (memop_encoding Types.vec_type_encoding Types.pack_size_encoding))
         (req "lane" int31))

  let var_encoding =
    let open Data_encoding in
    let open Source in
    conv (fun x -> x.it) (fun var -> var @@ no_region) Data_encoding.int32

  let num_encoding =
    let open Data_encoding in
    let open Source in
    conv (fun x -> x.it) (fun x -> x @@ no_region) Values.num_encoding

  let vec_encoding =
    let open Data_encoding in
    let open Source in
    conv (fun x -> x.it) (fun vec -> vec @@ no_region) Values.vec_encoding

  let block_type_encoding =
    let open Data_encoding in
    let open Ast in
    union_incr
      [
        case_incr
          "VarBlockType"
          var_encoding
          (function VarBlockType x -> Some x | _ -> None)
          (fun var -> VarBlockType var);
        case_incr
          "ValBlockType"
          (option Types.value_type_encoding)
          (function ValBlockType x -> Some x | _ -> None)
          (fun var -> ValBlockType var);
      ]
end
