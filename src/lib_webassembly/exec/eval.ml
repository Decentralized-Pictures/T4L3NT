open Lwt.Syntax
open Values
open Types
open Instance
open Ast
open Source

(* Errors *)

module Link = Error.Make ()

module Trap = Error.Make ()

module Crash = Error.Make ()

module Exhaustion = Error.Make ()

exception Link = Link.Error

exception Trap = Trap.Error

exception Crash = Crash.Error (* failure that cannot happen in valid code *)

exception Exhaustion = Exhaustion.Error

let table_error at = function
  | Table.Bounds -> "out of bounds table access"
  | Table.SizeOverflow -> "table size overflow"
  | Table.SizeLimit -> "table size limit reached"
  | Table.Type -> Crash.error at "type mismatch at table access"
  | Lazy_map.UnexpectedAccess -> "unexpected access in lazy map"
  | exn -> raise exn

let memory_error at = function
  | Memory.Bounds -> "out of bounds memory access"
  | Memory.SizeOverflow -> "memory size overflow"
  | Memory.SizeLimit -> "memory size limit reached"
  | Memory.Type -> Crash.error at "type mismatch at memory access"
  | Lazy_map.UnexpectedAccess -> "unexpected access in lazy map"
  | exn -> raise exn

let numeric_error at = function
  | Ixx.Overflow -> "integer overflow"
  | Ixx.DivideByZero -> "integer divide by zero"
  | Ixx.InvalidConversion -> "invalid conversion to integer"
  | Values.TypeError (i, v, t) ->
      Crash.error
        at
        ("type error, expected " ^ Types.string_of_num_type t ^ " as operand "
       ^ string_of_int i ^ ", got "
        ^ Types.string_of_num_type (type_of_num v))
  | exn -> raise exn

(* Administrative Expressions & Configurations *)

type 'a stack = 'a list

type frame = {inst : module_inst; locals : value ref list}

type code = value stack * admin_instr list

and admin_instr = admin_instr' phrase

and admin_instr' =
  | Plain of instr'
  | Refer of ref_
  | Invoke of func_inst
  | Trapping of string
  | Returning of value stack
  | Breaking of int32 * value stack
  | Label of int32 * instr list * code
  | Frame of int32 * frame * code

type config = {
  frame : frame;
  input : input_inst;
  code : code;
  budget : int; (* to model stack overflow *)
}

let frame inst locals = {inst; locals}

let config ?(input = Input_buffer.alloc ()) inst vs es =
  {frame = frame inst []; input; code = (vs, es); budget = 300}

let plain e = Plain e.it @@ e.at

let lookup category list x =
  try Lib.List32.nth list x.it
  with Failure _ ->
    Crash.error x.at ("undefined " ^ category ^ " " ^ Int32.to_string x.it)

let lookup_intmap category store x =
  Lwt.catch
    (fun () -> Instance.Vector.get x.it store)
    (function
      | Memory_exn.Bounds ->
          Crash.error x.at ("undefined " ^ category ^ " " ^ Int32.to_string x.it)
      | Lazy_map.UnexpectedAccess ->
          Crash.error
            x.at
            ("unexpected access in lazy map for " ^ category ^ " "
           ^ Int32.to_string x.it)
      | exn -> Lwt.fail exn)

let type_ (inst : module_inst) x = lookup_intmap "type" inst.types x

let func (inst : module_inst) x = lookup_intmap "function" inst.funcs x

let table (inst : module_inst) x = lookup_intmap "table" inst.tables x

let memory (inst : module_inst) x = lookup_intmap "memory" inst.memories x

let global (inst : module_inst) x = lookup_intmap "global" inst.globals x

let elem (inst : module_inst) x = lookup_intmap "element segment" inst.elems x

let data (inst : module_inst) x = lookup_intmap "data segment" inst.datas x

let local (frame : frame) x = lookup "local" frame.locals x

let any_ref inst x i at =
  Lwt.catch
    (fun () ->
      let* tbl = table inst x in
      Table.load tbl i)
    (function
      | Table.Bounds -> Trap.error at ("undefined element " ^ Int32.to_string i)
      | exn -> Lwt.fail exn)

let func_ref inst x i at =
  let+ value = any_ref inst x i at in
  match value with
  | FuncRef f -> f
  | NullRef _ -> Trap.error at ("uninitialized element " ^ Int32.to_string i)
  | _ -> Crash.error at ("type mismatch for element " ^ Int32.to_string i)

let func_type_of = function
  | Func.AstFunc (t, inst, f) -> t
  | Func.HostFunc (t, _) -> t

let block_type inst bt =
  let empty () = Lazy_vector.LwtInt32Vector.create 0l in
  let singleton i = Lazy_vector.LwtInt32Vector.(create 1l |> set 0l i) in
  match bt with
  | VarBlockType x -> type_ inst x
  | ValBlockType None -> FuncType (empty (), empty ()) |> Lwt.return
  | ValBlockType (Some t) -> FuncType (empty (), singleton t) |> Lwt.return

let take n (vs : 'a stack) at =
  try Lib.List32.take n vs with Failure _ -> Crash.error at "stack underflow"

let drop n (vs : 'a stack) at =
  try Lib.List32.drop n vs with Failure _ -> Crash.error at "stack underflow"

(* Evaluation *)

(*
 * Conventions:
 *   e  : instr
 *   v  : value
 *   es : instr list
 *   vs : value stack
 *   c : config
 *)

let mem_oob frame x i n =
  let+ mem = memory frame.inst x in
  I64.gt_u
    (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (Memory.bound mem)

let data_oob frame x i n =
  let+ data = data frame.inst x in
  I64.gt_u
    (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (Chunked_byte_vector.Lwt.length !data)

let table_oob frame x i n =
  let+ tbl = table frame.inst x in
  I64.gt_u
    (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (I64_convert.extend_i32_u (Table.size tbl))

let elem_oob frame x i n =
  let+ elem = elem frame.inst x in
  I64.gt_u
    (I64.add (I64_convert.extend_i32_u i) (I64_convert.extend_i32_u n))
    (Int64.of_int32 (Instance.Vector.num_elements !elem))

let rec step (c : config) : config Lwt.t =
  let {frame; code = vs, es; input; _} = c in
  let e = List.hd es in
  let+ vs', es' =
    match (e.it, vs) with
    | Plain e', vs -> (
        match (e', vs) with
        | Unreachable, vs ->
            Lwt.return (vs, [Trapping "unreachable executed" @@ e.at])
        | Nop, vs -> Lwt.return (vs, [])
        | Block (bt, es'), vs ->
            let+ (FuncType (ts1, ts2)) = block_type frame.inst bt in
            let n1 = Lazy_vector.LwtInt32Vector.num_elements ts1 in
            let n2 = Lazy_vector.LwtInt32Vector.num_elements ts2 in
            let args, vs' = (take n1 vs e.at, drop n1 vs e.at) in
            (vs', [Label (n2, [], (args, List.map plain es')) @@ e.at])
        | Loop (bt, es'), vs ->
            let+ (FuncType (ts1, ts2)) = block_type frame.inst bt in
            let n1 = Lazy_vector.LwtInt32Vector.num_elements ts1 in
            let args, vs' = (take n1 vs e.at, drop n1 vs e.at) in
            (vs', [Label (n1, [e' @@ e.at], (args, List.map plain es')) @@ e.at])
        | If (bt, es1, es2), Num (I32 i) :: vs' ->
            Lwt.return
              (if i = 0l then (vs', [Plain (Block (bt, es2)) @@ e.at])
              else (vs', [Plain (Block (bt, es1)) @@ e.at]))
        | Br x, vs -> Lwt.return ([], [Breaking (x.it, vs) @@ e.at])
        | BrIf x, Num (I32 i) :: vs' ->
            Lwt.return
              (if i = 0l then (vs', []) else (vs', [Plain (Br x) @@ e.at]))
        | BrTable (xs, x), Num (I32 i) :: vs' ->
            Lwt.return
              (if I32.ge_u i (Lib.List32.length xs) then
               (vs', [Plain (Br x) @@ e.at])
              else (vs', [Plain (Br (Lib.List32.nth xs i)) @@ e.at]))
        | Return, vs -> Lwt.return ([], [Returning vs @@ e.at])
        | Call x, vs ->
            let+ func = func frame.inst x in
            (vs, [Invoke func @@ e.at])
        | CallIndirect (x, y), Num (I32 i) :: vs ->
            let* func = func_ref frame.inst x i e.at
            and* type_ = type_ frame.inst y in
            let+ check_eq = Types.func_types_equal type_ (Func.type_of func) in
            if not check_eq then
              (vs, [Trapping "indirect call type mismatch" @@ e.at])
            else (vs, [Invoke func @@ e.at])
        | Drop, v :: vs' -> Lwt.return (vs', [])
        | Select _, Num (I32 i) :: v2 :: v1 :: vs' ->
            Lwt.return (if i = 0l then (v2 :: vs', []) else (v1 :: vs', []))
        | LocalGet x, vs -> Lwt.return (!(local frame x) :: vs, [])
        | LocalSet x, v :: vs' ->
            Lwt.return
              (local frame x := v ;
               (vs', []))
        | LocalTee x, v :: vs' ->
            Lwt.return
              (local frame x := v ;
               (v :: vs', []))
        | GlobalGet x, vs ->
            let+ glob = global frame.inst x in
            let value = Global.load glob in
            (value :: vs, [])
        | GlobalSet x, v :: vs' ->
            Lwt.catch
              (fun () ->
                let+ glob = global frame.inst x in
                Global.store glob v ;
                (vs', []))
              (function
                | Global.NotMutable ->
                    Crash.error e.at "write to immutable global"
                | Global.Type ->
                    Crash.error e.at "type mismatch at global write"
                | exn -> Lwt.fail exn)
        | TableGet x, Num (I32 i) :: vs' ->
            Lwt.catch
              (fun () ->
                let* tbl = table frame.inst x in
                let+ value = Table.load tbl i in
                (Ref value :: vs', []))
              (fun exn ->
                Lwt.return (vs', [Trapping (table_error e.at exn) @@ e.at]))
        | TableSet x, Ref r :: Num (I32 i) :: vs' ->
            Lwt.catch
              (fun () ->
                let+ tbl = table frame.inst x in
                Table.store tbl i r ;
                (vs', []))
              (fun exn ->
                Lwt.return (vs', [Trapping (table_error e.at exn) @@ e.at]))
        | TableSize x, vs ->
            let+ tbl = table frame.inst x in
            (Num (I32 (Table.size tbl)) :: vs, [])
        | TableGrow x, Num (I32 delta) :: Ref r :: vs' ->
            let+ tab = table frame.inst x in
            let old_size = Table.size tab in
            let result =
              try
                Table.grow tab delta r ;
                old_size
              with Table.SizeOverflow | Table.SizeLimit | Table.OutOfMemory ->
                -1l
            in
            (Num (I32 result) :: vs', [])
        | TableFill x, Num (I32 n) :: Ref r :: Num (I32 i) :: vs' ->
            let+ oob = table_oob frame x i n in
            if oob then (vs', [Trapping (table_error e.at Table.Bounds) @@ e.at])
            else if n = 0l then (vs', [])
            else
              let _ = assert (I32.lt_u i 0xffff_ffffl) in
              ( vs',
                List.map
                  (at e.at)
                  [
                    Plain (Const (I32 i @@ e.at));
                    Refer r;
                    Plain (TableSet x);
                    Plain (Const (I32 (I32.add i 1l) @@ e.at));
                    Refer r;
                    Plain (Const (I32 (I32.sub n 1l) @@ e.at));
                    Plain (TableFill x);
                  ] )
        | TableCopy (x, y), Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
            let+ oob_d = table_oob frame x d n
            and+ oob_s = table_oob frame y s n in
            if oob_d || oob_s then
              (vs', [Trapping (table_error e.at Table.Bounds) @@ e.at])
            else if n = 0l then (vs', [])
            else if I32.le_u d s then
              ( vs',
                List.map
                  (at e.at)
                  [
                    Plain (Const (I32 d @@ e.at));
                    Plain (Const (I32 s @@ e.at));
                    Plain (TableGet y);
                    Plain (TableSet x);
                    Plain (Const (I32 (I32.add d 1l) @@ e.at));
                    Plain (Const (I32 (I32.add s 1l) @@ e.at));
                    Plain (Const (I32 (I32.sub n 1l) @@ e.at));
                    Plain (TableCopy (x, y));
                  ] )
            else
              (* d > s *)
              ( vs',
                List.map
                  (at e.at)
                  [
                    Plain (Const (I32 (I32.add d 1l) @@ e.at));
                    Plain (Const (I32 (I32.add s 1l) @@ e.at));
                    Plain (Const (I32 (I32.sub n 1l) @@ e.at));
                    Plain (TableCopy (x, y));
                    Plain (Const (I32 d @@ e.at));
                    Plain (Const (I32 s @@ e.at));
                    Plain (TableGet y);
                    Plain (TableSet x);
                  ] )
        | TableInit (x, y), Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
            let* oob_d = table_oob frame x d n in
            let* oob_s = elem_oob frame y s n in
            if oob_d || oob_s then
              Lwt.return
                (vs', [Trapping (table_error e.at Table.Bounds) @@ e.at])
            else if n = 0l then Lwt.return (vs', [])
            else
              let* seg = elem frame.inst y in
              let+ value = Instance.Vector.get s !seg in
              ( vs',
                List.map
                  (at e.at)
                  [
                    Plain (Const (I32 d @@ e.at));
                    (* Note, the [Instance.Vector.get] is logarithmic in the number of
                       contained elements in [seg]. However, in a scenario where the PVM
                       runs, only the element that will be looked up is in the map
                       making the look up cheap. *)
                    Refer value;
                    Plain (TableSet x);
                    Plain (Const (I32 (I32.add d 1l) @@ e.at));
                    Plain (Const (I32 (I32.add s 1l) @@ e.at));
                    Plain (Const (I32 (I32.sub n 1l) @@ e.at));
                    Plain (TableInit (x, y));
                  ] )
        | ElemDrop x, vs ->
            let+ seg = elem frame.inst x in
            seg := Instance.Vector.create 0l ;
            (vs, [])
        | Load {offset; ty; pack; _}, Num (I32 i) :: vs' ->
            let* mem = memory frame.inst (0l @@ e.at) in
            Lwt.catch
              (fun () ->
                let+ n =
                  match pack with
                  | None -> Memory.load_num mem i offset ty
                  | Some (sz, ext) ->
                      Memory.load_num_packed sz ext mem i offset ty
                in
                (Num n :: vs', []))
              (fun exn ->
                Lwt.return (vs', [Trapping (memory_error e.at exn) @@ e.at]))
        | Store {offset; pack; _}, Num n :: Num (I32 i) :: vs' ->
            let* mem = memory frame.inst (0l @@ e.at) in
            Lwt.catch
              (fun () ->
                let+ () =
                  match pack with
                  | None -> Memory.store_num mem i offset n
                  | Some sz -> Memory.store_num_packed sz mem i offset n
                in
                (vs', []))
              (fun exn ->
                Lwt.return (vs', [Trapping (memory_error e.at exn) @@ e.at]))
        | VecLoad {offset; ty; pack; _}, Num (I32 i) :: vs' ->
            let* mem = memory frame.inst (0l @@ e.at) in
            Lwt.catch
              (fun () ->
                let+ v =
                  match pack with
                  | None -> Memory.load_vec mem i offset ty
                  | Some (sz, ext) ->
                      Memory.load_vec_packed sz ext mem i offset ty
                in
                (Vec v :: vs', []))
              (fun exn ->
                Lwt.return (vs', [Trapping (memory_error e.at exn) @@ e.at]))
        | VecStore {offset; _}, Vec v :: Num (I32 i) :: vs' ->
            let* mem = memory frame.inst (0l @@ e.at) in
            Lwt.catch
              (fun () ->
                let+ () = Memory.store_vec mem i offset v in
                (vs', []))
              (fun exn ->
                Lwt.return (vs', [Trapping (memory_error e.at exn) @@ e.at]))
        | ( VecLoadLane ({offset; ty; pack; _}, j),
            Vec (V128 v) :: Num (I32 i) :: vs' ) ->
            let* mem = memory frame.inst (0l @@ e.at) in
            Lwt.catch
              (fun () ->
                let+ v =
                  match pack with
                  | Pack8 ->
                      let+ mem =
                        Memory.load_num_packed Pack8 SX mem i offset I32Type
                      in
                      V128.I8x16.replace_lane j v (I32Num.of_num 0 mem)
                  | Pack16 ->
                      let+ mem =
                        Memory.load_num_packed Pack16 SX mem i offset I32Type
                      in
                      V128.I16x8.replace_lane j v (I32Num.of_num 0 mem)
                  | Pack32 ->
                      let+ mem = Memory.load_num mem i offset I32Type in
                      V128.I32x4.replace_lane j v (I32Num.of_num 0 mem)
                  | Pack64 ->
                      let+ mem = Memory.load_num mem i offset I64Type in
                      V128.I64x2.replace_lane j v (I64Num.of_num 0 mem)
                in
                (Vec (V128 v) :: vs', []))
              (fun exn ->
                Lwt.return (vs', [Trapping (memory_error e.at exn) @@ e.at]))
        | ( VecStoreLane ({offset; ty; pack; _}, j),
            Vec (V128 v) :: Num (I32 i) :: vs' ) ->
            let* mem = memory frame.inst (0l @@ e.at) in
            Lwt.catch
              (fun () ->
                let+ () =
                  match pack with
                  | Pack8 ->
                      Memory.store_num_packed
                        Pack8
                        mem
                        i
                        offset
                        (I32 (V128.I8x16.extract_lane_s j v))
                  | Pack16 ->
                      Memory.store_num_packed
                        Pack16
                        mem
                        i
                        offset
                        (I32 (V128.I16x8.extract_lane_s j v))
                  | Pack32 ->
                      Memory.store_num
                        mem
                        i
                        offset
                        (I32 (V128.I32x4.extract_lane_s j v))
                  | Pack64 ->
                      Memory.store_num
                        mem
                        i
                        offset
                        (I64 (V128.I64x2.extract_lane_s j v))
                in
                (vs', []))
              (fun exn ->
                Lwt.return (vs', [Trapping (memory_error e.at exn) @@ e.at]))
        | MemorySize, vs ->
            let+ mem = memory frame.inst (0l @@ e.at) in
            (Num (I32 (Memory.size mem)) :: vs, [])
        | MemoryGrow, Num (I32 delta) :: vs' ->
            let+ mem = memory frame.inst (0l @@ e.at) in
            let old_size = Memory.size mem in
            let result =
              try
                Memory.grow mem delta ;
                old_size
              with
              | Memory.SizeOverflow | Memory.SizeLimit | Memory.OutOfMemory ->
                -1l
            in
            (Num (I32 result) :: vs', [])
        | MemoryFill, Num (I32 n) :: Num k :: Num (I32 i) :: vs' ->
            let+ oob = mem_oob frame (0l @@ e.at) i n in
            if oob then
              (vs', [Trapping (memory_error e.at Memory.Bounds) @@ e.at])
            else if n = 0l then (vs', [])
            else
              ( vs',
                List.map
                  (at e.at)
                  [
                    Plain (Const (I32 i @@ e.at));
                    Plain (Const (k @@ e.at));
                    Plain
                      (Store
                         {
                           ty = I32Type;
                           align = 0;
                           offset = 0l;
                           pack = Some Pack8;
                         });
                    Plain (Const (I32 (I32.add i 1l) @@ e.at));
                    Plain (Const (k @@ e.at));
                    Plain (Const (I32 (I32.sub n 1l) @@ e.at));
                    Plain MemoryFill;
                  ] )
        | MemoryCopy, Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
            let+ oob_s = mem_oob frame (0l @@ e.at) s n
            and+ oob_d = mem_oob frame (0l @@ e.at) d n in
            if oob_s || oob_d then
              (vs', [Trapping (memory_error e.at Memory.Bounds) @@ e.at])
            else if n = 0l then (vs', [])
            else if I32.le_u d s then
              ( vs',
                List.map
                  (at e.at)
                  [
                    Plain (Const (I32 d @@ e.at));
                    Plain (Const (I32 s @@ e.at));
                    Plain
                      (Load
                         {
                           ty = I32Type;
                           align = 0;
                           offset = 0l;
                           pack = Some (Pack8, ZX);
                         });
                    Plain
                      (Store
                         {
                           ty = I32Type;
                           align = 0;
                           offset = 0l;
                           pack = Some Pack8;
                         });
                    Plain (Const (I32 (I32.add d 1l) @@ e.at));
                    Plain (Const (I32 (I32.add s 1l) @@ e.at));
                    Plain (Const (I32 (I32.sub n 1l) @@ e.at));
                    Plain MemoryCopy;
                  ] )
            else
              (* d > s *)
              ( vs',
                List.map
                  (at e.at)
                  [
                    Plain (Const (I32 (I32.add d 1l) @@ e.at));
                    Plain (Const (I32 (I32.add s 1l) @@ e.at));
                    Plain (Const (I32 (I32.sub n 1l) @@ e.at));
                    Plain MemoryCopy;
                    Plain (Const (I32 d @@ e.at));
                    Plain (Const (I32 s @@ e.at));
                    Plain
                      (Load
                         {
                           ty = I32Type;
                           align = 0;
                           offset = 0l;
                           pack = Some (Pack8, ZX);
                         });
                    Plain
                      (Store
                         {
                           ty = I32Type;
                           align = 0;
                           offset = 0l;
                           pack = Some Pack8;
                         });
                  ] )
        | MemoryInit x, Num (I32 n) :: Num (I32 s) :: Num (I32 d) :: vs' ->
            let* mem_oob = mem_oob frame (0l @@ e.at) d n in
            let* data_oob = data_oob frame x s n in
            if mem_oob || data_oob then
              Lwt.return
                (vs', [Trapping (memory_error e.at Memory.Bounds) @@ e.at])
            else if n = 0l then Lwt.return (vs', [])
            else
              let* seg = data frame.inst x in
              let+ b =
                Chunked_byte_vector.Lwt.load_byte !seg (Int64.of_int32 s)
              in
              let b = Int32.of_int b in
              ( vs',
                List.map
                  (at e.at)
                  [
                    Plain (Const (I32 d @@ e.at));
                    Plain (Const (I32 b @@ e.at));
                    Plain
                      (Store
                         {
                           ty = I32Type;
                           align = 0;
                           offset = 0l;
                           pack = Some Pack8;
                         });
                    Plain (Const (I32 (I32.add d 1l) @@ e.at));
                    Plain (Const (I32 (I32.add s 1l) @@ e.at));
                    Plain (Const (I32 (I32.sub n 1l) @@ e.at));
                    Plain (MemoryInit x);
                  ] )
        | DataDrop x, vs ->
            let+ seg = data frame.inst x in
            seg := Chunked_byte_vector.Lwt.create 0L ;
            (vs, [])
        | RefNull t, vs' -> Lwt.return (Ref (NullRef t) :: vs', [])
        | RefIsNull, Ref r :: vs' ->
            Lwt.return
              (match r with
              | NullRef _ -> (Num (I32 1l) :: vs', [])
              | _ -> (Num (I32 0l) :: vs', []))
        | RefFunc x, vs' ->
            let+ f = func frame.inst x in
            (Ref (FuncRef f) :: vs', [])
        | Const n, vs -> Lwt.return (Num n.it :: vs, [])
        | Test testop, Num n :: vs' ->
            Lwt.return
              (try (value_of_bool (Eval_num.eval_testop testop n) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | Compare relop, Num n2 :: Num n1 :: vs' ->
            Lwt.return
              (try (value_of_bool (Eval_num.eval_relop relop n1 n2) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | Unary unop, Num n :: vs' ->
            Lwt.return
              (try (Num (Eval_num.eval_unop unop n) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | Binary binop, Num n2 :: Num n1 :: vs' ->
            Lwt.return
              (try (Num (Eval_num.eval_binop binop n1 n2) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | Convert cvtop, Num n :: vs' ->
            Lwt.return
              (try (Num (Eval_num.eval_cvtop cvtop n) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecConst v, vs -> Lwt.return (Vec v.it :: vs, [])
        | VecTest testop, Vec n :: vs' ->
            Lwt.return
              (try (value_of_bool (Eval_vec.eval_testop testop n) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecUnary unop, Vec n :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_unop unop n) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecBinary binop, Vec n2 :: Vec n1 :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_binop binop n1 n2) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecCompare relop, Vec n2 :: Vec n1 :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_relop relop n1 n2) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecConvert cvtop, Vec n :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_cvtop cvtop n) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecShift shiftop, Num s :: Vec v :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_shiftop shiftop v s) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecBitmask bitmaskop, Vec v :: vs' ->
            Lwt.return
              (try (Num (Eval_vec.eval_bitmaskop bitmaskop v) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecTestBits vtestop, Vec n :: vs' ->
            Lwt.return
              (try (value_of_bool (Eval_vec.eval_vtestop vtestop n) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecUnaryBits vunop, Vec n :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_vunop vunop n) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecBinaryBits vbinop, Vec n2 :: Vec n1 :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_vbinop vbinop n1 n2) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecTernaryBits vternop, Vec v3 :: Vec v2 :: Vec v1 :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_vternop vternop v1 v2 v3) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecSplat splatop, Num n :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_splatop splatop n) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecExtract extractop, Vec v :: vs' ->
            Lwt.return
              (try (Num (Eval_vec.eval_extractop extractop v) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | VecReplace replaceop, Num r :: Vec v :: vs' ->
            Lwt.return
              (try (Vec (Eval_vec.eval_replaceop replaceop v r) :: vs', [])
               with exn -> (vs', [Trapping (numeric_error e.at exn) @@ e.at]))
        | _ ->
            let s1 = string_of_values (List.rev vs) in
            let s2 =
              string_of_value_types (List.map type_of_value (List.rev vs))
            in
            Crash.error
              e.at
              ("missing or ill-typed operand on stack (" ^ s1 ^ " : " ^ s2 ^ ")")
        )
    | Refer r, vs -> Lwt.return (Ref r :: vs, [])
    | Trapping msg, vs -> assert false
    | Returning vs', vs -> Crash.error e.at "undefined frame"
    | Breaking (k, vs'), vs -> Crash.error e.at "undefined label"
    | Label (n, es0, (vs', [])), vs -> Lwt.return (vs' @ vs, [])
    | Label (n, es0, (vs', {it = Trapping msg; at} :: es')), vs ->
        Lwt.return (vs, [Trapping msg @@ at])
    | Label (n, es0, (vs', {it = Returning vs0; at} :: es')), vs ->
        Lwt.return (vs, [Returning vs0 @@ at])
    | Label (n, es0, (vs', {it = Breaking (0l, vs0); at} :: es')), vs ->
        Lwt.return (take n vs0 e.at @ vs, List.map plain es0)
    | Label (n, es0, (vs', {it = Breaking (k, vs0); at} :: es')), vs ->
        Lwt.return (vs, [Breaking (Int32.sub k 1l, vs0) @@ at])
    | Label (n, es0, code'), vs ->
        let+ c' = step {c with code = code'} in
        (vs, [Label (n, es0, c'.code) @@ e.at])
    | Frame (n, frame', (vs', [])), vs -> Lwt.return (vs' @ vs, [])
    | Frame (n, frame', (vs', {it = Trapping msg; at} :: es')), vs ->
        Lwt.return (vs, [Trapping msg @@ at])
    | Frame (n, frame', (vs', {it = Returning vs0; at} :: es')), vs ->
        Lwt.return (take n vs0 e.at @ vs, [])
    | Frame (n, frame', code'), vs ->
        let+ c' =
          step
            {
              frame = frame';
              code = code';
              budget = c.budget - 1;
              input = c.input;
            }
        in
        (vs, [Frame (n, c'.frame, c'.code) @@ e.at])
    | Invoke func, vs when c.budget = 0 ->
        Exhaustion.error e.at "call stack exhausted"
    | Invoke func, vs -> (
        let (FuncType (ins, out)) = func_type_of func in
        let n1, n2 =
          (Instance.Vector.num_elements ins, Instance.Vector.num_elements out)
        in
        let args, vs' = (take n1 vs e.at, drop n1 vs e.at) in
        match func with
        | Func.AstFunc (t, inst', f) ->
            (* TODO: https://gitlab.com/tezos/tezos/-/issues/3366 &
               https://gitlab.com/tezos/tezos/-/issues/3082

               This conversion to list can probably be avoided by using
               Lazy_vector in the config for local variables. *)
            let+ locals = Lazy_vector.LwtInt32Vector.to_list f.it.locals in
            let locals' = List.rev args @ List.map default_value locals in
            let frame' = {inst = !inst'; locals = List.map ref locals'} in
            let instr' =
              [Label (n2, [], ([], List.map plain f.it.body)) @@ f.at]
            in
            (vs', [Frame (n2, frame', ([], instr')) @@ e.at])
        | Func.HostFunc (t, f) ->
            let inst = ref frame.inst in
            Lwt.catch
              (fun () ->
                let+ res = f input inst (List.rev args) in
                (List.rev res @ vs', []))
              (function
                | Crash (_, msg) -> Crash.error e.at msg | exn -> raise exn))
  in
  {c with code = (vs', es' @ List.tl es)}

let rec eval (c : config) : value stack Lwt.t =
  match c.code with
  | vs, [] -> Lwt.return vs
  | vs, {it = Trapping msg; at} :: _ -> Trap.error at msg
  | vs, es ->
      let* c = step c in
      eval c

(* Functions & Constants *)

let invoke ?(module_inst = empty_module_inst) ?(input = Input_buffer.alloc ())
    (func : func_inst) (vs : value list) : (module_inst * value list) Lwt.t =
  let at = match func with Func.AstFunc (_, _, f) -> f.at | _ -> no_region in
  let (FuncType (ins, out)) = Func.type_of func in
  let* ins_l = Lazy_vector.LwtInt32Vector.to_list ins in
  if
    List.length vs
    <> (Lazy_vector.LwtInt32Vector.num_elements ins |> Int32.to_int)
  then Crash.error at "wrong number of arguments" ;
  (* TODO: tickify? *)
  if not (List.for_all2 (fun v -> ( = ) (type_of_value v)) vs ins_l) then
    Crash.error at "wrong types of arguments" ;

  let c = config ~input module_inst (List.rev vs) [Invoke func @@ at] in
  Lwt.catch
    (fun () ->
      let+ values = eval c in
      (c.frame.inst, List.rev values))
    (function
      | Stack_overflow -> Exhaustion.error at "call stack exhausted"
      | exn -> Lwt.fail exn)

let eval_const (inst : module_inst) (const : const) : value Lwt.t =
  let c = config inst [] (List.map plain const.it) in
  let+ vs = eval c in
  match vs with
  | [v] -> v
  | vs -> Crash.error const.at "wrong number of results on stack"

(* Modules *)

let create_func (inst : module_inst) (f : func) : func_inst Lwt.t =
  let+ type_ = type_ inst f.it.ftype in
  Func.alloc type_ (ref inst) f

let create_table (inst : module_inst) (tab : table) : table_inst =
  let {ttype} = tab.it in
  let (TableType (_lim, t)) = ttype in
  Table.alloc ttype (NullRef t)

let create_memory (inst : module_inst) (mem : memory) : memory_inst =
  let {mtype} = mem.it in
  Memory.alloc mtype

let create_global (inst : module_inst) (glob : global) : global_inst Lwt.t =
  let {gtype; ginit} = glob.it in
  let+ v = eval_const inst ginit in
  Global.alloc gtype v

let create_export (inst : module_inst) (ex : export) : export_inst Lwt.t =
  let {name; edesc} = ex.it in
  let+ ext =
    match edesc.it with
    | FuncExport x ->
        let+ func = func inst x in
        ExternFunc func
    | TableExport x ->
        let+ tbl = table inst x in
        ExternTable tbl
    | MemoryExport x ->
        let+ mem = memory inst x in
        ExternMemory mem
    | GlobalExport x ->
        let+ glob = global inst x in
        ExternGlobal glob
  in
  (name, ext)

let create_elem (inst : module_inst) (seg : elem_segment) : elem_inst Lwt.t =
  let {etype; einit; _} = seg.it in
  (* TODO: #3076
     [einit] should be changed to a lazy structure. We want to avoid traversing
     it whole. *)
  let* einit = Lazy_vector.LwtInt32Vector.to_list einit in
  let+ init =
    TzStdLib.List.map_s
      (fun v ->
        let+ r = eval_const inst v in
        as_ref r)
      einit
  in
  ref (Instance.Vector.of_list init)

let create_data (inst : module_inst) (seg : data_segment) : data_inst Lwt.t =
  let {dinit; _} = seg.it in
  let data = Chunked_byte_vector.Lwt.Buffer.to_byte_vector dinit in
  Lwt.return (ref data)

let add_import (m : module_) (ext : extern) (im : import) (inst : module_inst) :
    module_inst Lwt.t =
  let* t = import_type m im in
  let* type_match = match_extern_type (extern_type_of ext) t in
  let+ () =
    if not type_match then
      let* module_name = Utf8.encode im.it.module_name in
      let+ item_name = Utf8.encode im.it.item_name in
      Link.error
        im.at
        ("incompatible import type for " ^ "\"" ^ module_name ^ "\" " ^ "\""
       ^ item_name ^ "\": " ^ "expected "
        ^ Types.string_of_extern_type t
        ^ ", got "
        ^ Types.string_of_extern_type (extern_type_of ext))
    else Lwt.return_unit
  in
  match ext with
  | ExternFunc func -> {inst with funcs = Vector.cons func inst.funcs}
  | ExternTable tab -> {inst with tables = Vector.cons tab inst.tables}
  | ExternMemory mem -> {inst with memories = Vector.cons mem inst.memories}
  | ExternGlobal glob -> {inst with globals = Vector.cons glob inst.globals}

let init_func (inst : module_inst) (func : func_inst) =
  match func with
  | Func.AstFunc (_, inst_ref, _) -> inst_ref := inst
  | _ -> assert false

let run_elem i elem =
  let at = elem.it.emode.at in
  let x = i @@ at in
  match elem.it.emode.it with
  | Passive -> []
  | Active {index; offset} ->
      offset.it
      @ [
          Const (I32 0l @@ at) @@ at;
          Const
            (I32 (Lazy_vector.LwtInt32Vector.num_elements elem.it.einit) @@ at)
          @@ at;
          TableInit (index, x) @@ at;
          ElemDrop x @@ at;
        ]
  | Declarative -> [ElemDrop x @@ at]

let run_data i data =
  let at = data.it.dmode.at in
  let x = i @@ at in
  match data.it.dmode.it with
  | Passive -> []
  | Active {index; offset} ->
      assert (index.it = 0l) ;
      offset.it
      @ [
          Const (I32 0l @@ at) @@ at;
          Const
            (I32
               (Int32.of_int
                  (Int64.to_int
                     (Chunked_byte_vector.Lwt.Buffer.length data.it.dinit)))
            @@ at)
          @@ at;
          MemoryInit x @@ at;
          DataDrop x @@ at;
        ]
  | Declarative -> assert false

let run_start start = [Call start.it.sfunc @@ start.at]

let init (m : module_) (exts : extern list) : module_inst Lwt.t =
  let open Lwt.Syntax in
  let {
    imports;
    tables;
    memories;
    globals;
    funcs;
    types;
    exports;
    elems;
    datas;
    start;
  } =
    m.it
  in

  (* TODO: #3076

     These transformations should be refactored and abadoned during the
     tickification, to avoid the roundtrip vector -> list -> vector. *)
  let* types = Vector.to_list types in
  let* imports = Vector.to_list imports in
  let* tables = Vector.to_list tables in
  let* memories = Vector.to_list memories in
  let* globals = Vector.to_list globals in
  let* funcs = Vector.to_list funcs in
  let* elems = Vector.to_list elems in
  let* datas = Vector.to_list datas in
  let* exports = Vector.to_list exports in

  (* TODO: #3076
     To refactor during the tickification. *)
  let* init_inst0 =
    TzStdLib.List.fold_right2_s
      ~when_different_lengths:()
      (add_import m)
      exts
      imports
      empty_module_inst
  in
  let init_inst0 =
    match init_inst0 with
    | Ok i -> i
    | Error () ->
        Link.error m.at "wrong number of imports provided for initialisation"
  in
  let inst0 =
    {
      init_inst0 with
      types =
        (* TODO: #3076
           [types] should be a lazy structure so we can avoid traversing it
           whole. *)
        List.map (fun type_ -> type_.it) types |> Vector.of_list;
    }
  in
  let* fs = TzStdLib.List.map_s (create_func inst0) funcs in
  let inst1 =
    {
      inst0 with
      (* TODO: #3076
         [fs]/[funcs] should be a lazy structure so we can avoid traversing it
         completely. *)
      funcs = Vector.concat inst0.funcs (Vector.of_list fs);
    }
  in
  let* new_globals = TzStdLib.List.map_s (create_global inst1) globals in
  let inst2 =
    {
      inst1 with
      tables =
        (* TODO: #3076
           [tables] should be a lazy structure. *)
        List.map (create_table inst1) tables
        |> Vector.of_list |> Vector.concat inst1.tables;
      memories =
        (* TODO: #3076
           [memories] should be a lazy structure. *)
        List.map (create_memory inst1) memories
        |> Vector.of_list
        |> Vector.concat inst1.memories;
      globals =
        (* TODO: #3076
           [new_globals]/[globals] should be lazy structures. *)
        Vector.concat inst1.globals (Vector.of_list new_globals);
    }
  in
  let* new_exports = TzStdLib.List.map_s (create_export inst2) exports in
  let* new_elems = TzStdLib.List.map_s (create_elem inst2) elems in
  let* new_datas = TzStdLib.List.map_s (create_data inst2) datas in
  let* exports =
    (* TODO: #3076
       [new_exports]/[exports] should be lazy structures. *)
    TzStdLib.List.fold_left_s
      (fun exports (k, v) ->
        let+ k = Instance.Vector.to_list k in
        NameMap.set k v exports)
      (NameMap.create ~produce_value:(fun _ -> Lwt.fail Not_found) ())
      new_exports
  in
  let inst =
    {
      inst2 with
      exports;
      elems =
        (* TODO: #3076
           [new_elems]/[elems] should be lazy structures. *)
        Vector.of_list new_elems;
      datas =
        (* TODO: #3076
           [new_data]/[datas] should be lazy structures. *)
        Vector.of_list new_datas;
    }
  in
  List.iter (init_func inst) fs ;
  let es_elem = List.concat (Lib.List32.mapi run_elem elems) in
  let es_data = List.concat (Lib.List32.mapi run_data datas) in
  let es_start = Lib.Option.get (Lib.Option.map run_start start) [] in
  let+ (_ : Values.value stack) =
    eval (config inst [] (List.map plain (es_elem @ es_data @ es_start)))
  in
  inst
