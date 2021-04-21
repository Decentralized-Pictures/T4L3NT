(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2019 Nomadic Labs <contact@tezos.com>                       *)
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

(** Testing
    -------
    Component:    Micheline
    Invocation:   dune build @src/lib_benchmark/lib_micheline_rewriting/runtest_test_rewriting
    Subject:      Rewriting
*)

open Tezos_micheline_rewriting
open Tezos_protocol_alpha.Protocol

let rec update_contract_script :
    ('l, 'p) Micheline.node -> ('l, 'p) Micheline.node = function
  | Micheline.Seq
      (_, Micheline.Prim (_, Michelson_v1_primitives.I_ADDRESS, [], []) :: l)
    ->
      Micheline.Seq
        ( 0,
          Micheline.Prim (0, Michelson_v1_primitives.I_ADDRESS, [], [])
          :: Micheline.Prim (0, Michelson_v1_primitives.I_CHAIN_ID, [], [])
          :: Micheline.Prim (0, Michelson_v1_primitives.I_PAIR, [], [])
          :: l )
  | Micheline.Seq (_, a :: l) -> (
      let a' = update_contract_script a in
      let b = Micheline.Seq (0, l) in
      let b' = update_contract_script b in
      match b' with
      | Micheline.Seq (_, l') ->
          Micheline.Seq (0, a' :: l')
      | _ ->
          assert false )
  | Micheline.Prim (_, p, l, annot) ->
      Micheline.Prim (0, p, List.map update_contract_script l, annot)
  | script ->
      script

let update_contract_script : Script_repr.expr -> Script_repr.expr =
 fun script ->
  Micheline.strip_locations (update_contract_script (Micheline.root script))

module Michelson_signature :
  Signature.S with type t = Michelson_v1_primitives.prim = struct
  type t = Michelson_v1_primitives.prim

  let compare (x : t) (y : t) = Stdlib.compare x y

  let hash (x : t) = Hashtbl.hash x

  let pp fmtr prim =
    Format.fprintf fmtr "%s" (Michelson_v1_primitives.string_of_prim prim)
end

module Michelson =
  Micheline_with_hash_consing.Make
    (Michelson_signature)
    (struct
      let initial_size = None
    end)

module Michelson_path = Path.With_hash_consing (struct
  let initial_size = None
end)

module Michelson_pattern =
  Pattern.Make (Michelson_signature) (Michelson) (Michelson_path)
module Michelson_rewriter =
  Rewrite.Make (Michelson_signature) (Michelson) (Michelson_path)
    (Michelson_pattern)

let pattern =
  let open Michelson_pattern in
  seq
    ( any @. any @. any
    @. focus (prim Michelson_v1_primitives.I_ADDRESS list_empty)
    @. list_any )

let replacement =
  let open Michelson in
  seq
    [ prim Michelson_v1_primitives.I_ADDRESS [] [];
      prim Michelson_v1_primitives.I_CHAIN_ID [] [];
      prim Michelson_v1_primitives.I_PAIR [] [] ]

let rewrite_contract : Script_repr.expr -> Script_repr.expr =
 fun script ->
  let node = Micheline.root script in
  let node =
    Micheline.map_node (fun _ -> Michelson.default_label) (fun h -> h) node
  in
  let focuses = Michelson_rewriter.all_matches pattern node in
  match focuses with
  | [] ->
      assert false
  | paths ->
      let result =
        List.fold_left
          (fun term path -> Michelson_rewriter.subst ~term ~path ~replacement)
          node
          paths
      in
      Micheline.strip_locations result

(* The multisig contract script written by Arthur Breitman
     https://github.com/murbard/smart-contracts/blob/master/multisig/michelson/multisig.tz *)
(* 004 version *)
let multisig_script_string =
  "parameter (pair\n\
  \             (pair :payload\n\
  \                (nat %counter) # counter, used to prevent replay attacks\n\
  \                (or :action    # payload to sign, represents the requested \
   action\n\
  \                   (pair :transfer    # transfer tokens\n\
  \                      (mutez %amount) # amount to transfer\n\
  \                      (contract %dest unit)) # destination to transfer to\n\
  \                   (or\n\
  \                      (option %delegate key_hash) # change the delegate to \
   this address\n\
  \                      (pair %change_keys          # change the keys \
   controlling the multisig\n\
  \                         (nat %threshold)         # new threshold\n\
  \                         (list %keys key)))))     # new list of keys\n\
  \             (list %sigs (option signature)));    # signatures\n\n\
   storage (pair (nat %stored_counter) (pair (nat %threshold) (list %keys \
   key))) ;\n\n\
   code\n\
  \  {\n\
  \    UNPAIR ; SWAP ; DUP ; DIP { SWAP } ;\n\
  \    DIP\n\
  \      {\n\
  \        UNPAIR ;\n\
  \        # pair the payload with the current contract address, to ensure \
   signatures\n\
  \        # can't be replayed accross different contracts if a key is reused.\n\
  \        DUP ; SELF ; ADDRESS ; PAIR ;\n\
  \        PACK ; # form the binary payload that we expect to be signed\n\
  \        DIP { UNPAIR @counter ; DIP { SWAP } } ; SWAP\n\
  \      } ;\n\n\
  \    # Check that the counters match\n\
  \    UNPAIR @stored_counter; DIP { SWAP };\n\
  \    ASSERT_CMPEQ ;\n\n\
  \    # Compute the number of valid signatures\n\
  \    DIP { SWAP } ; UNPAIR @threshold @keys;\n\
  \    DIP\n\
  \      {\n\
  \        # Running count of valid signatures\n\
  \        PUSH @valid nat 0; SWAP ;\n\
  \        ITER\n\
  \          {\n\
  \            DIP { SWAP } ; SWAP ;\n\
  \            IF_CONS\n\
  \              {\n\
  \                IF_SOME\n\
  \                  { SWAP ;\n\
  \                    DIP\n\
  \                      {\n\
  \                        SWAP ; DIIP { DUUP } ;\n\
  \                        # Checks signatures, fails if invalid\n\
  \                        { DUUUP; DIP {CHECK_SIGNATURE}; SWAP; IF {DROP} \
   {FAILWITH} };\n\
  \                        PUSH nat 1 ; ADD @valid } }\n\
  \                  { SWAP ; DROP }\n\
  \              }\n\
  \              {\n\
  \                # There were fewer signatures in the list\n\
  \                # than keys. Not all signatures must be present, but\n\
  \                # they should be marked as absent using the option type.\n\
  \                FAIL\n\
  \              } ;\n\
  \            SWAP\n\
  \          }\n\
  \      } ;\n\
  \    # Assert that the threshold is less than or equal to the\n\
  \    # number of valid signatures.\n\
  \    ASSERT_CMPLE ;\n\
  \    DROP ; DROP ;\n\n\
  \    # Increment counter and place in storage\n\
  \    DIP { UNPAIR ; PUSH nat 1 ; ADD @new_counter ; PAIR} ;\n\n\
  \    # We have now handled the signature verification part,\n\
  \    # produce the operation requested by the signers.\n\
  \    NIL operation ; SWAP ;\n\
  \    IF_LEFT\n\
  \      { # Transfer tokens\n\
  \        UNPAIR ; UNIT ; TRANSFER_TOKENS ; CONS }\n\
  \      { IF_LEFT {\n\
  \                  # Change delegate\n\
  \                  SET_DELEGATE ; CONS }\n\
  \                {\n\
  \                  # Change set of signatures\n\
  \                  DIP { SWAP ; CAR } ; SWAP ; PAIR ; SWAP }} ;\n\
  \    PAIR }\n"

open Tezos_error_monad.Error_monad
open Tezos_client_alpha

(* Client_proto_context.originate expects the contract script as a Script.expr *)
let multisig_script : Script_repr.expr =
  let result =
    Tezos_micheline.Micheline_parser.no_parsing_error
    @@ Michelson_v1_parser.parse_toplevel
         ?check:(Some true)
         multisig_script_string
    >>? fun parsing_result -> ok parsing_result.Michelson_v1_parser.expanded
  in
  match result with
  | Ok script ->
      script
  | Error _err ->
      Stdlib.failwith "Error while parsing script"

let original_script_oracle =
  "{ parameter\n\
  \    (pair (pair :payload\n\
  \             (nat %counter)\n\
  \             (or :action\n\
  \                (pair :transfer (mutez %amount) (contract %dest unit))\n\
  \                (or (option %delegate key_hash)\n\
  \                    (pair %change_keys (nat %threshold) (list %keys key)))))\n\
  \          (list %sigs (option signature))) ;\n\
  \  storage (pair (nat %stored_counter) (pair (nat %threshold) (list %keys \
   key))) ;\n\
  \  code { UNPAIR ;\n\
  \         SWAP ;\n\
  \         DUP ;\n\
  \         DIP { SWAP } ;\n\
  \         DIP { UNPAIR ;\n\
  \               DUP ;\n\
  \               SELF ;\n\
  \               ADDRESS ;\n\
  \               PAIR ;\n\
  \               PACK ;\n\
  \               DIP { UNPAIR @counter ; DIP { SWAP } } ;\n\
  \               SWAP } ;\n\
  \         UNPAIR @stored_counter ;\n\
  \         DIP { SWAP } ;\n\
  \         { { COMPARE ; EQ } ; IF {} { { UNIT ; FAILWITH } } } ;\n\
  \         DIP { SWAP } ;\n\
  \         UNPAIR @threshold @keys ;\n\
  \         DIP { PUSH @valid nat 0 ;\n\
  \               SWAP ;\n\
  \               ITER { DIP { SWAP } ;\n\
  \                      SWAP ;\n\
  \                      IF_CONS\n\
  \                        { { IF_NONE\n\
  \                              { SWAP ; DROP }\n\
  \                              { SWAP ;\n\
  \                                DIP { SWAP ;\n\
  \                                      DIP 2 { DUP 2 } ;\n\
  \                                      { DUP 3 ;\n\
  \                                        DIP { CHECK_SIGNATURE } ;\n\
  \                                        SWAP ;\n\
  \                                        IF { DROP } { FAILWITH } } ;\n\
  \                                      PUSH nat 1 ;\n\
  \                                      ADD @valid } } } }\n\
  \                        { { UNIT ; FAILWITH } } ;\n\
  \                      SWAP } } ;\n\
  \         { { COMPARE ; LE } ; IF {} { { UNIT ; FAILWITH } } } ;\n\
  \         DROP ;\n\
  \         DROP ;\n\
  \         DIP { UNPAIR ; PUSH nat 1 ; ADD @new_counter ; PAIR } ;\n\
  \         NIL operation ;\n\
  \         SWAP ;\n\
  \         IF_LEFT\n\
  \           { UNPAIR ; UNIT ; TRANSFER_TOKENS ; CONS }\n\
  \           { IF_LEFT\n\
  \               { SET_DELEGATE ; CONS }\n\
  \               { DIP { SWAP ; CAR } ; SWAP ; PAIR ; SWAP } } ;\n\
  \         PAIR } }"

let original_script =
  let script =
    Micheline_printer.printable
      Michelson_v1_primitives.string_of_prim
      multisig_script
  in
  Format.asprintf "%a" Micheline_printer.print_expr_unwrapped script

let () = assert (original_script_oracle = original_script)

let pattern_oracle = "Seq(_ :: _ :: _ :: [> [ADDRESS]([]) <] :: _)"

let pattern = Format.asprintf "%a" Michelson_pattern.pp pattern

let () = assert (pattern_oracle = pattern)

(* let rewritten_original = update_contract_script multisig_script *)
let rewritten_new = rewrite_contract multisig_script

let rewritten_script_oracle =
  "{ parameter\n\
  \    (pair (pair :payload\n\
  \             (nat %counter)\n\
  \             (or :action\n\
  \                (pair :transfer (mutez %amount) (contract %dest unit))\n\
  \                (or (option %delegate key_hash)\n\
  \                    (pair %change_keys (nat %threshold) (list %keys key)))))\n\
  \          (list %sigs (option signature))) ;\n\
  \  storage (pair (nat %stored_counter) (pair (nat %threshold) (list %keys \
   key))) ;\n\
  \  code { UNPAIR ;\n\
  \         SWAP ;\n\
  \         DUP ;\n\
  \         DIP { SWAP } ;\n\
  \         DIP { UNPAIR ;\n\
  \               DUP ;\n\
  \               SELF ;\n\
  \               { ADDRESS ; CHAIN_ID ; PAIR } ;\n\
  \               PAIR ;\n\
  \               PACK ;\n\
  \               DIP { UNPAIR @counter ; DIP { SWAP } } ;\n\
  \               SWAP } ;\n\
  \         UNPAIR @stored_counter ;\n\
  \         DIP { SWAP } ;\n\
  \         { { COMPARE ; EQ } ; IF {} { { UNIT ; FAILWITH } } } ;\n\
  \         DIP { SWAP } ;\n\
  \         UNPAIR @threshold @keys ;\n\
  \         DIP { PUSH @valid nat 0 ;\n\
  \               SWAP ;\n\
  \               ITER { DIP { SWAP } ;\n\
  \                      SWAP ;\n\
  \                      IF_CONS\n\
  \                        { { IF_NONE\n\
  \                              { SWAP ; DROP }\n\
  \                              { SWAP ;\n\
  \                                DIP { SWAP ;\n\
  \                                      DIP 2 { DUP 2 } ;\n\
  \                                      { DUP 3 ;\n\
  \                                        DIP { CHECK_SIGNATURE } ;\n\
  \                                        SWAP ;\n\
  \                                        IF { DROP } { FAILWITH } } ;\n\
  \                                      PUSH nat 1 ;\n\
  \                                      ADD @valid } } } }\n\
  \                        { { UNIT ; FAILWITH } } ;\n\
  \                      SWAP } } ;\n\
  \         { { COMPARE ; LE } ; IF {} { { UNIT ; FAILWITH } } } ;\n\
  \         DROP ;\n\
  \         DROP ;\n\
  \         DIP { UNPAIR ; PUSH nat 1 ; ADD @new_counter ; PAIR } ;\n\
  \         NIL operation ;\n\
  \         SWAP ;\n\
  \         IF_LEFT\n\
  \           { UNPAIR ; UNIT ; TRANSFER_TOKENS ; CONS }\n\
  \           { IF_LEFT\n\
  \               { SET_DELEGATE ; CONS }\n\
  \               { DIP { SWAP ; CAR } ; SWAP ; PAIR ; SWAP } } ;\n\
  \         PAIR } }"

let rewritten_script =
  let script =
    Micheline_printer.printable
      Michelson_v1_primitives.string_of_prim
      rewritten_new
  in
  Format.asprintf "%a" Micheline_printer.print_expr_unwrapped script

(** Test that the rewritten script is as expected. *)
let () = assert (rewritten_script_oracle = rewritten_script)
