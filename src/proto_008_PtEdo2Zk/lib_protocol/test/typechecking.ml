open Protocol
open Alpha_context
open Script_interpreter
open Micheline

exception Expression_from_string

let expression_from_string str : Script.expr tzresult Lwt.t =
  let (ast, errs) = Michelson_v1_parser.parse_expression ~check:false str in
  ( match errs with
  | [] ->
      ()
  | lst ->
      Format.printf "expr_from_string: %a\n" Error_monad.pp_print_error lst ;
      raise Expression_from_string ) ;
  return ast.expanded

let ( >>=?? ) x y =
  x
  >>= function
  | Ok s ->
      y s
  | Error errs ->
      Lwt.return
      @@ Error (List.map (fun x -> Environment.Ecoproto_error x) errs)

let wrap_error_lwt x = x >>= fun x -> Lwt.return @@ Environment.wrap_error x

let test_context () =
  Context.init 3
  >>=? fun (b, _cs) ->
  Incremental.begin_construction b
  >>=? fun v -> return (Incremental.alpha_ctxt v)

let test_context_with_nat_nat_big_map () =
  Context.init 3
  >>=? fun (b, contracts) ->
  let source = List.hd contracts in
  Op.origination (B b) source ~script:Op.dummy_script
  >>=? fun (operation, originated) ->
  Block.bake ~operation b
  >>=? fun b ->
  Incremental.begin_construction b
  >>=? fun v ->
  let ctxt = Incremental.alpha_ctxt v in
  wrap_error_lwt @@ Big_map.fresh ~temporary:false ctxt
  >>=? fun (ctxt, id) ->
  let nat_ty = Script_typed_ir.Nat_t None in
  wrap_error_lwt @@ Lwt.return @@ Script_ir_translator.unparse_ty ctxt nat_ty
  >>=? fun (nat_ty_node, ctxt) ->
  let nat_ty_expr = Micheline.strip_locations nat_ty_node in
  let alloc = Big_map.{key_type = nat_ty_expr; value_type = nat_ty_expr} in
  let init = Lazy_storage.Alloc alloc in
  let diffs =
    [ Lazy_storage.make
        Lazy_storage.Kind.Big_map
        id
        (Update {init; updates = []}) ]
  in
  wrap_error_lwt
  @@ Contract.update_script_storage ctxt originated nat_ty_expr (Some diffs)
  >>=? fun ctxt -> return (ctxt, id)

let default_source = Contract.implicit_contract Signature.Public_key_hash.zero

let default_step_constants =
  {
    source = default_source;
    payer = default_source;
    self = default_source;
    amount = Tez.zero;
    chain_id = Chain_id.zero;
  }

(** Helper function that parses and types a script, its initial storage and
   parameters from strings. It then executes the typed script with the storage
   and parameter and returns the result. *)
let run_script ctx ?(step_constants = default_step_constants) contract
    ?(entrypoint = "default") ~storage ~parameter () =
  expression_from_string contract
  >>=? fun contract_expr ->
  expression_from_string storage
  >>=? fun storage_expr ->
  expression_from_string parameter
  >>=? fun parameter_expr ->
  let script =
    Script.{code = lazy_expr contract_expr; storage = lazy_expr storage_expr}
  in
  Script_interpreter.execute
    ctx
    Readable
    step_constants
    ~script
    ~entrypoint
    ~parameter:parameter_expr
    ~internal:false
  >>=?? fun res -> return res

let read_file filename =
  let ch = open_in filename in
  let s = really_input_string ch (in_channel_length ch) in
  close_in ch ; s

(* Check that the custom stack overflow exception is triggered when it should be *)
let test_typecheck_stack_overflow () =
  test_context ()
  >>=? fun ctxt ->
  let storage = "Unit" in
  let parameter = "Unit" in
  let script = read_file "./contracts/big_interpreter_stack.tz" in
  run_script ctxt script ~storage ~parameter ()
  >>= function
  | Ok _ ->
      Alcotest.fail "expected an error"
  | Error lst
    when List.mem
           (Environment.Ecoproto_error
              Script_tc_errors.Typechecking_too_many_recursive_calls)
           lst ->
      return ()
  | Error errs ->
      Alcotest.failf "Unexpected error: %a" Error_monad.pp_print_error errs

let test_unparse_stack_overflow () =
  test_context ()
  >>=? fun ctxt ->
  (* Meme *)
  let enorme_et_seq n =
    let rec aux n acc = aux (n - 1) @@ Micheline.Seq (0, [acc]) in
    aux n (Micheline.Int (0, Z.zero))
  in
  Script_ir_translator.(unparse_code ctxt Readable (enorme_et_seq 10_001))
  >>= function
  | Ok _ ->
      Alcotest.fail "expected an error"
  | Error lst
    when List.mem Script_tc_errors.Unparsing_too_many_recursive_calls lst ->
      return ()
  | Error _ ->
      Alcotest.failf "Unexpected error: %s" __LOC__

let location = function
  | Prim (loc, _, _, _)
  | Int (loc, _)
  | String (loc, _)
  | Bytes (loc, _)
  | Seq (loc, _) ->
      loc

let test_parse_ty ctxt node expected =
  let legacy = false in
  let allow_lazy_storage = true in
  let allow_operation = true in
  let allow_contract = true in
  let allow_ticket = true in
  Environment.wrap_error
    ( Script_ir_translator.parse_ty
        ctxt
        ~legacy
        ~allow_lazy_storage
        ~allow_operation
        ~allow_contract
        ~allow_ticket
        node
    >>? fun (Script_ir_translator.Ex_ty actual, ctxt) ->
    Script_ir_translator.ty_eq ctxt (location node) actual expected
    >|? fun (_, ctxt) -> ctxt )

let test_parse_comb_type () =
  let open Script in
  let open Script_typed_ir in
  let nat_prim = Prim (-1, T_nat, [], []) in
  let nat_prim_a = Prim (-1, T_nat, [], ["%a"]) in
  let nat_prim_b = Prim (-1, T_nat, [], ["%b"]) in
  let nat_prim_c = Prim (-1, T_nat, [], ["%c"]) in
  let nat_ty = Nat_t None in
  let pair_prim l = Prim (-1, T_pair, l, []) in
  let pair_ty ty1 ty2 = Pair_t ((ty1, None, None), (ty2, None, None), None) in
  let pair_prim2 a b = pair_prim [a; b] in
  let pair_nat_nat_prim = pair_prim2 nat_prim nat_prim in
  let pair_nat_nat_ty = pair_ty nat_ty nat_ty in
  test_context ()
  >>=? fun ctxt ->
  (* pair nat nat *)
  test_parse_ty ctxt pair_nat_nat_prim pair_nat_nat_ty
  >>?= fun ctxt ->
  (* pair (pair nat nat) nat *)
  test_parse_ty
    ctxt
    (pair_prim2 pair_nat_nat_prim nat_prim)
    (pair_ty pair_nat_nat_ty nat_ty)
  >>?= fun ctxt ->
  (* pair nat (pair nat nat) *)
  test_parse_ty
    ctxt
    (pair_prim2 nat_prim pair_nat_nat_prim)
    (pair_ty nat_ty pair_nat_nat_ty)
  >>?= fun ctxt ->
  (* pair nat nat nat *)
  test_parse_ty
    ctxt
    (pair_prim [nat_prim; nat_prim; nat_prim])
    (pair_ty nat_ty pair_nat_nat_ty)
  >>?= fun ctxt ->
  (* pair (nat %a) nat *)
  test_parse_ty
    ctxt
    (pair_prim2 nat_prim_a nat_prim)
    (Pair_t ((nat_ty, Some (Field_annot "a"), None), (nat_ty, None, None), None))
  >>?= fun ctxt ->
  (* pair nat (nat %b) *)
  test_parse_ty
    ctxt
    (pair_prim2 nat_prim nat_prim_b)
    (Pair_t ((nat_ty, None, None), (nat_ty, Some (Field_annot "b"), None), None))
  >>?= fun ctxt ->
  (* pair (nat %a) (nat %b) *)
  test_parse_ty
    ctxt
    (pair_prim2 nat_prim_a nat_prim_b)
    (Pair_t
       ( (nat_ty, Some (Field_annot "a"), None),
         (nat_ty, Some (Field_annot "b"), None),
         None ))
  >>?= fun ctxt ->
  (* pair (nat %a) (nat %b) (nat %c) *)
  test_parse_ty
    ctxt
    (pair_prim [nat_prim_a; nat_prim_b; nat_prim_c])
    (Pair_t
       ( (nat_ty, Some (Field_annot "a"), None),
         ( Pair_t
             ( (nat_ty, Some (Field_annot "b"), None),
               (nat_ty, Some (Field_annot "c"), None),
               None ),
           None,
           None ),
         None ))
  >>?= fun ctxt ->
  (* pair (nat %a) (pair %b nat nat) *)
  test_parse_ty
    ctxt
    (pair_prim2 nat_prim_a (Prim (-1, T_pair, [nat_prim; nat_prim], ["%b"])))
    (Pair_t
       ( (nat_ty, Some (Field_annot "a"), None),
         ( Pair_t ((nat_ty, None, None), (nat_ty, None, None), None),
           Some (Field_annot "b"),
           None ),
         None ))
  >>?= fun _ -> return_unit

let test_unparse_ty loc ctxt expected ty =
  Environment.wrap_error
    ( Script_ir_translator.unparse_ty ctxt ty
    >>? fun (actual, ctxt) ->
    if actual = expected then ok ctxt
    else Alcotest.failf "Unexpected error: %s" loc )

let test_unparse_comb_type () =
  let open Script in
  let open Script_typed_ir in
  let nat_prim = Prim (-1, T_nat, [], []) in
  let nat_prim_a = Prim (-1, T_nat, [], ["%a"]) in
  let nat_prim_b = Prim (-1, T_nat, [], ["%b"]) in
  let nat_prim_c = Prim (-1, T_nat, [], ["%c"]) in
  let nat_ty = Nat_t None in
  let pair_prim l = Prim (-1, T_pair, l, []) in
  let pair_ty ty1 ty2 = Pair_t ((ty1, None, None), (ty2, None, None), None) in
  let pair_prim2 a b = pair_prim [a; b] in
  let pair_nat_nat_prim = pair_prim2 nat_prim nat_prim in
  let pair_nat_nat_ty = pair_ty nat_ty nat_ty in
  test_context ()
  >>=? fun ctxt ->
  (* pair nat nat *)
  test_unparse_ty __LOC__ ctxt pair_nat_nat_prim pair_nat_nat_ty
  >>?= fun ctxt ->
  (* pair (pair nat nat) nat *)
  test_unparse_ty
    __LOC__
    ctxt
    (pair_prim2 pair_nat_nat_prim nat_prim)
    (pair_ty pair_nat_nat_ty nat_ty)
  >>?= fun ctxt ->
  (* pair nat nat nat *)
  test_unparse_ty
    __LOC__
    ctxt
    (pair_prim [nat_prim; nat_prim; nat_prim])
    (pair_ty nat_ty pair_nat_nat_ty)
  >>?= fun ctxt ->
  (* pair (nat %a) nat *)
  test_unparse_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim_a nat_prim)
    (Pair_t ((nat_ty, Some (Field_annot "a"), None), (nat_ty, None, None), None))
  >>?= fun ctxt ->
  (* pair nat (nat %b) *)
  test_unparse_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim nat_prim_b)
    (Pair_t ((nat_ty, None, None), (nat_ty, Some (Field_annot "b"), None), None))
  >>?= fun ctxt ->
  (* pair (nat %a) (nat %b) *)
  test_unparse_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim_a nat_prim_b)
    (Pair_t
       ( (nat_ty, Some (Field_annot "a"), None),
         (nat_ty, Some (Field_annot "b"), None),
         None ))
  >>?= fun ctxt ->
  (* pair (nat %a) (nat %b) (nat %c) *)
  test_unparse_ty
    __LOC__
    ctxt
    (pair_prim [nat_prim_a; nat_prim_b; nat_prim_c])
    (Pair_t
       ( (nat_ty, Some (Field_annot "a"), None),
         ( Pair_t
             ( (nat_ty, Some (Field_annot "b"), None),
               (nat_ty, Some (Field_annot "c"), None),
               None ),
           None,
           None ),
         None ))
  >>?= fun ctxt ->
  (* pair (nat %a) (pair %b nat nat) *)
  test_unparse_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim_a (Prim (-1, T_pair, [nat_prim; nat_prim], ["%b"])))
    (Pair_t
       ( (nat_ty, Some (Field_annot "a"), None),
         ( Pair_t ((nat_ty, None, None), (nat_ty, None, None), None),
           Some (Field_annot "b"),
           None ),
         None ))
  >>?= fun ctxt ->
  (* pair nat (pair @b nat nat) *)
  test_unparse_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim (Prim (-1, T_pair, [nat_prim; nat_prim], ["@b"])))
    (Pair_t
       ( (nat_ty, None, None),
         ( Pair_t ((nat_ty, None, None), (nat_ty, None, None), None),
           None,
           Some (Var_annot "b") ),
         None ))
  >>?= fun ctxt ->
  (* pair nat (pair :b nat nat) *)
  test_unparse_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim (Prim (-1, T_pair, [nat_prim; nat_prim], [":b"])))
    (Pair_t
       ( (nat_ty, None, None),
         ( Pair_t
             ((nat_ty, None, None), (nat_ty, None, None), Some (Type_annot "b")),
           None,
           None ),
         None ))
  >>?= fun _ -> return_unit

let test_unparse_comparable_ty loc ctxt expected ty =
  (* unparse_comparable_ty is not exported, the simplest way to call it is to
     call parse_ty on a set type *)
  Environment.wrap_error
    ( Script_ir_translator.unparse_ty ctxt (Set_t (ty, None))
    >>? fun (actual, ctxt) ->
    if actual = Prim (-1, T_set, [expected], []) then ok ctxt
    else Alcotest.failf "Unexpected error: %s" loc )

let test_unparse_comb_comparable_type () =
  let open Script in
  let open Script_typed_ir in
  let nat_prim = Prim (-1, T_nat, [], []) in
  let nat_prim_a = Prim (-1, T_nat, [], ["%a"]) in
  let nat_prim_b = Prim (-1, T_nat, [], ["%b"]) in
  let nat_prim_c = Prim (-1, T_nat, [], ["%c"]) in
  let nat_ty = Nat_key None in
  let pair_prim l = Prim (-1, T_pair, l, []) in
  let pair_ty ty1 ty2 = Pair_key ((ty1, None), (ty2, None), None) in
  let pair_prim2 a b = pair_prim [a; b] in
  let pair_nat_nat_prim = pair_prim2 nat_prim nat_prim in
  let pair_nat_nat_ty = pair_ty nat_ty nat_ty in
  test_context ()
  >>=? fun ctxt ->
  (* pair nat nat *)
  test_unparse_comparable_ty __LOC__ ctxt pair_nat_nat_prim pair_nat_nat_ty
  >>?= fun ctxt ->
  (* pair (pair nat nat) nat *)
  test_unparse_comparable_ty
    __LOC__
    ctxt
    (pair_prim2 pair_nat_nat_prim nat_prim)
    (pair_ty pair_nat_nat_ty nat_ty)
  >>?= fun ctxt ->
  (* pair nat nat nat *)
  test_unparse_comparable_ty
    __LOC__
    ctxt
    (pair_prim [nat_prim; nat_prim; nat_prim])
    (pair_ty nat_ty pair_nat_nat_ty)
  >>?= fun ctxt ->
  (* pair (nat %a) nat *)
  test_unparse_comparable_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim_a nat_prim)
    (Pair_key ((nat_ty, Some (Field_annot "a")), (nat_ty, None), None))
  >>?= fun ctxt ->
  (* pair nat (nat %b) *)
  test_unparse_comparable_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim nat_prim_b)
    (Pair_key ((nat_ty, None), (nat_ty, Some (Field_annot "b")), None))
  >>?= fun ctxt ->
  (* pair (nat %a) (nat %b) *)
  test_unparse_comparable_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim_a nat_prim_b)
    (Pair_key
       ( (nat_ty, Some (Field_annot "a")),
         (nat_ty, Some (Field_annot "b")),
         None ))
  >>?= fun ctxt ->
  (* pair (nat %a) (nat %b) (nat %c) *)
  test_unparse_comparable_ty
    __LOC__
    ctxt
    (pair_prim [nat_prim_a; nat_prim_b; nat_prim_c])
    (Pair_key
       ( (nat_ty, Some (Field_annot "a")),
         ( Pair_key
             ( (nat_ty, Some (Field_annot "b")),
               (nat_ty, Some (Field_annot "c")),
               None ),
           None ),
         None ))
  >>?= fun ctxt ->
  (* pair (nat %a) (pair %b nat nat) *)
  test_unparse_comparable_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim_a (Prim (-1, T_pair, [nat_prim; nat_prim], ["%b"])))
    (Pair_key
       ( (nat_ty, Some (Field_annot "a")),
         ( Pair_key ((nat_ty, None), (nat_ty, None), None),
           Some (Field_annot "b") ),
         None ))
  >>?= fun ctxt ->
  (* pair nat (pair :b nat nat) *)
  test_unparse_comparable_ty
    __LOC__
    ctxt
    (pair_prim2 nat_prim (Prim (-1, T_pair, [nat_prim; nat_prim], [":b"])))
    (Pair_key
       ( (nat_ty, None),
         ( Pair_key ((nat_ty, None), (nat_ty, None), Some (Type_annot "b")),
           None ),
         None ))
  >>?= fun _ -> return_unit

let test_parse_data ?(equal = Stdlib.( = )) loc ctxt ty node expected =
  let legacy = false in
  let allow_forged = true in
  wrap_error_lwt
    ( Script_ir_translator.parse_data ctxt ~legacy ~allow_forged ty node
    >>=? fun (actual, ctxt) ->
    if equal actual expected then return ctxt
    else Alcotest.failf "Unexpected error: %s" loc )

let test_parse_data_fails loc ctxt ty node =
  let legacy = false in
  let allow_forged = false in
  wrap_error_lwt
    ( Script_ir_translator.parse_data ctxt ~legacy ~allow_forged ty node
    >>= function
    | Ok _ ->
        Alcotest.failf "Unexpected typechecking success: %s" loc
    | Error
        (Tezos_raw_protocol_008_PtEdo2Zk.Script_tc_errors.Invalid_constant _
        :: _) ->
        return_unit
    | Error _ as res ->
        Lwt.return res )

let test_parse_comb_data () =
  let open Script in
  let open Script_typed_ir in
  let z = Script_int.zero_n in
  let z_prim = Micheline.Int (-1, Z.zero) in
  let nat_ty = Nat_t None in
  let pair_prim l = Prim (-1, D_Pair, l, []) in
  let pair_ty ty1 ty2 = Pair_t ((ty1, None, None), (ty2, None, None), None) in
  let pair_nat_nat_ty = pair_ty nat_ty nat_ty in
  let pair_prim2 a b = pair_prim [a; b] in
  let pair_z_z_prim = pair_prim2 z_prim z_prim in
  let list_nat_ty = List_t (nat_ty, None) in
  let big_map_nat_nat_ty = Big_map_t (Nat_key None, nat_ty, None) in
  test_context_with_nat_nat_big_map ()
  >>=? fun (ctxt, big_map_id) ->
  (* Pair 0 0 *)
  test_parse_data __LOC__ ctxt (pair_ty nat_ty nat_ty) pair_z_z_prim (z, z)
  >>=? fun ctxt ->
  (* {0; 0} *)
  test_parse_data
    __LOC__
    ctxt
    (pair_ty nat_ty nat_ty)
    (Micheline.Seq (-1, [z_prim; z_prim]))
    (z, z)
  >>=? fun ctxt ->
  (* Pair (Pair 0 0) 0 *)
  test_parse_data
    __LOC__
    ctxt
    (pair_ty pair_nat_nat_ty nat_ty)
    (pair_prim2 pair_z_z_prim z_prim)
    ((z, z), z)
  >>=? fun ctxt ->
  (* Pair 0 (Pair 0 0) *)
  test_parse_data
    __LOC__
    ctxt
    (pair_ty nat_ty pair_nat_nat_ty)
    (pair_prim2 z_prim pair_z_z_prim)
    (z, (z, z))
  >>=? fun ctxt ->
  (* Pair 0 0 0 *)
  test_parse_data
    __LOC__
    ctxt
    (pair_ty nat_ty pair_nat_nat_ty)
    (pair_prim [z_prim; z_prim; z_prim])
    (z, (z, z))
  >>=? fun ctxt ->
  (* {0; 0; 0} *)
  test_parse_data
    __LOC__
    ctxt
    (pair_ty nat_ty pair_nat_nat_ty)
    (Micheline.Seq (-1, [z_prim; z_prim; z_prim]))
    (z, (z, z))
  >>=? fun ctxt ->
  (* Should fail: {0} against pair nat (list nat) *)
  test_parse_data_fails
    __LOC__
    ctxt
    (pair_ty nat_ty list_nat_ty)
    (Micheline.Seq (-1, [z_prim]))
  >>=? fun () ->
  (* Should fail: {0; 0; 0} against pair nat (list nat) *)
  test_parse_data_fails
    __LOC__
    ctxt
    (pair_ty nat_ty list_nat_ty)
    (Micheline.Seq (-1, [z_prim; z_prim; z_prim]))
  >>=? fun () ->
  (* check Pair 0 (Pair 0 {}) against pair nat (big_map nat nat)
     so that the following test fails for the good reason and not because
     the big map doesn't exist
   *)
  let id_z = Big_map.Id.unparse_to_z big_map_id in
  let id_prim = Int (-1, id_z) in
  let module M = struct
    open Script_int

    type key = n num

    type value = n num option

    let key_ty = Nat_key None

    module OPS = Environment.Map.Make (struct
      type t = key

      let compare = compare
    end)

    let boxed = (OPS.empty, 0)

    module type S =
      Boxed_map with type key = n num and type value = n num option
  end in
  let expected_big_map =
    let open Script_typed_ir in
    let diff = (module M : M.S) in
    let nat_key_ty = Nat_key None in
    {id = Some big_map_id; diff; key_type = nat_key_ty; value_type = nat_ty}
  in
  let equal (nat1, big_map1) (nat2, big_map2) =
    (* Custom equal needed because big maps contain boxed maps containing functional values *)
    nat1 = nat2 && big_map1.id = big_map2.id
    && big_map1.key_type = big_map2.key_type
    && big_map1.value_type = big_map2.value_type
    &&
    let module Diff1 = (val big_map1.diff : M.S) in
    let module Diff2 = (val big_map2.diff : M.S) in
    snd Diff1.boxed = snd Diff2.boxed
    && Diff1.OPS.bindings (fst Diff1.boxed)
       = Diff2.OPS.bindings (fst Diff2.boxed)
  in
  test_parse_data
    ~equal
    __LOC__
    ctxt
    (pair_ty nat_ty big_map_nat_nat_ty)
    (pair_prim2 z_prim (pair_prim2 id_prim (Seq (-1, []))))
    (Script_int.zero_n, expected_big_map)
  >>=? fun ctxt ->
  (* Should fail: Pair 0 0 {} against pair nat (big_map nat nat) *)
  test_parse_data_fails
    __LOC__
    ctxt
    (pair_ty nat_ty big_map_nat_nat_ty)
    (pair_prim [z_prim; id_prim; Seq (-1, [])])

let test_unparse_data loc ctxt ty x ~expected_readable ~expected_optimized =
  wrap_error_lwt
    ( Script_ir_translator.unparse_data ctxt Script_ir_translator.Readable ty x
    >>=? fun (actual_readable, ctxt) ->
    ( if actual_readable = expected_readable then return ctxt
    else Alcotest.failf "Error in readable unparsing: %s" loc )
    >>=? fun ctxt ->
    Script_ir_translator.unparse_data ctxt Script_ir_translator.Optimized ty x
    >>=? fun (actual_optimized, ctxt) ->
    if actual_optimized = expected_optimized then return ctxt
    else Alcotest.failf "Error in optimized unparsing: %s" loc )

let test_unparse_comb_data () =
  let open Script in
  let open Script_typed_ir in
  let z = Script_int.zero_n in
  let z_prim = Micheline.Int (-1, Z.zero) in
  let nat_ty = Nat_t None in
  let pair_prim l = Prim (-1, D_Pair, l, []) in
  let pair_ty ty1 ty2 = Pair_t ((ty1, None, None), (ty2, None, None), None) in
  let pair_nat_nat_ty = pair_ty nat_ty nat_ty in
  let pair_prim2 a b = pair_prim [a; b] in
  let pair_z_z_prim = pair_prim2 z_prim z_prim in
  test_context ()
  >>=? fun ctxt ->
  (* Pair 0 0 *)
  test_unparse_data
    __LOC__
    ctxt
    (pair_ty nat_ty nat_ty)
    (z, z)
    ~expected_readable:pair_z_z_prim
    ~expected_optimized:pair_z_z_prim
  >>=? fun ctxt ->
  (* Pair (Pair 0 0) 0 *)
  test_unparse_data
    __LOC__
    ctxt
    (pair_ty pair_nat_nat_ty nat_ty)
    ((z, z), z)
    ~expected_readable:(pair_prim2 pair_z_z_prim z_prim)
    ~expected_optimized:(pair_prim2 pair_z_z_prim z_prim)
  >>=? fun ctxt ->
  (* Readable: Pair 0 0 0; Optimized: Pair 0 (Pair 0 0) *)
  test_unparse_data
    __LOC__
    ctxt
    (pair_ty nat_ty pair_nat_nat_ty)
    (z, (z, z))
    ~expected_readable:(pair_prim [z_prim; z_prim; z_prim])
    ~expected_optimized:(pair_prim2 z_prim pair_z_z_prim)
  >>=? fun ctxt ->
  (* Readable: Pair 0 0 0 0; Optimized: {0; 0; 0; 0} *)
  test_unparse_data
    __LOC__
    ctxt
    (pair_ty nat_ty (pair_ty nat_ty pair_nat_nat_ty))
    (z, (z, (z, z)))
    ~expected_readable:(pair_prim [z_prim; z_prim; z_prim; z_prim])
    ~expected_optimized:(Micheline.Seq (-1, [z_prim; z_prim; z_prim; z_prim]))
  >>=? fun _ -> return_unit

(* Generate all the possible syntaxes for pairs *)
let gen_pairs left right =
  [Prim (-1, Script.D_Pair, [left; right], []); Seq (-1, [left; right])]

(* Generate all the possible syntaxes for combs *)
let rec gen_combs leaf arity =
  assert (arity >= 2) ;
  if arity = 2 then gen_pairs leaf leaf
  else
    gen_combs leaf (arity - 1)
    |> List.map (fun smaller ->
           ( match smaller with
           | Prim (loc, Script.D_Pair, vs, []) ->
               Prim (loc, Script.D_Pair, leaf :: vs, [])
           | Seq (loc, vs) ->
               Seq (loc, leaf :: vs)
           | _ ->
               assert false )
           :: gen_pairs leaf smaller)
    |> List.flatten

(* Checks the optimality of the Optimized Micheline representation for combs *)
let test_optimal_comb () =
  let open Script_typed_ir in
  let leaf_ty = Nat_t None in
  let leaf_mich = Int (-1, Z.zero) in
  let leaf_v = Script_int.zero_n in
  let size_of_micheline mich =
    let canonical = Micheline.strip_locations mich in
    ( canonical,
      Bytes.length
      @@ Data_encoding.Binary.to_bytes_exn Script.expr_encoding canonical )
  in
  let check_optimal_comb loc ctxt ty v arity =
    wrap_error_lwt
      ( Script_ir_translator.unparse_data
          ctxt
          Script_ir_translator.Optimized
          ty
          v
      >>=? fun (unparsed, ctxt) ->
      let (unparsed_canonical, unparsed_size) = size_of_micheline unparsed in
      Error_monad.iter_s (fun other_repr ->
          let (other_repr_canonical, other_repr_size) =
            size_of_micheline other_repr
          in
          if other_repr_size < unparsed_size then
            Alcotest.failf
              "At %s, for comb of arity %d, representation %a (size %d bytes) \
               is shorter than representation %a (size %d bytes) returned by \
               unparse_data in Optimized mode"
              loc
              arity
              Michelson_v1_printer.print_expr
              other_repr_canonical
              other_repr_size
              Michelson_v1_printer.print_expr
              unparsed_canonical
              unparsed_size
          else return_unit)
      @@ gen_combs leaf_mich arity
      >>=? fun () -> return ctxt )
  in
  let pair_ty ty1 ty2 = Pair_t ((ty1, None, None), (ty2, None, None), None) in
  test_context ()
  >>=? fun ctxt ->
  let comb2_ty = pair_ty leaf_ty leaf_ty in
  let comb2_v = (leaf_v, leaf_v) in
  check_optimal_comb __LOC__ ctxt comb2_ty comb2_v 2
  >>=? fun ctxt ->
  let comb3_ty = pair_ty leaf_ty comb2_ty in
  let comb3_v = (leaf_v, comb2_v) in
  check_optimal_comb __LOC__ ctxt comb3_ty comb3_v 3
  >>=? fun ctxt ->
  let comb4_ty = pair_ty leaf_ty comb3_ty in
  let comb4_v = (leaf_v, comb3_v) in
  check_optimal_comb __LOC__ ctxt comb4_ty comb4_v 4
  >>=? fun ctxt ->
  let comb5_ty = pair_ty leaf_ty comb4_ty in
  let comb5_v = (leaf_v, comb4_v) in
  check_optimal_comb __LOC__ ctxt comb5_ty comb5_v 5
  >>=? fun _ctxt -> return_unit

let tests =
  [ Test.tztest
      "test typecheck stack overflow error"
      `Quick
      test_typecheck_stack_overflow;
    Test.tztest
      "test unparsing stack overflow error"
      `Quick
      test_typecheck_stack_overflow;
    Test.tztest "test comb type parsing" `Quick test_parse_comb_type;
    Test.tztest "test comb type unparsing" `Quick test_unparse_comb_type;
    Test.tztest
      "test comb comparable type unparsing"
      `Quick
      test_unparse_comb_comparable_type;
    Test.tztest "test comb data parsing" `Quick test_parse_comb_data;
    Test.tztest "test comb data unparsing" `Quick test_unparse_comb_data;
    Test.tztest "test optimal comb data unparsing" `Quick test_optimal_comb ]
