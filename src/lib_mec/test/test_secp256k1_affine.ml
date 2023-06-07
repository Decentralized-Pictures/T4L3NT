(*****************************************************************************)
(*                                                                           *)
(* Copyright (c) 2021 Danny Willems <be.danny.willems@gmail.com>             *)
(* Copyright (c) 2023 Nomadic Labs, <contact@nomadic-labs.com>               *)
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
    Component:    lib_mec
    Invocation:   dune exec src/lib_mec/test/main.exe \
                  -- --file test_secp256k1_affine.ml
    Subject:      Test lib mec
*)

module Secp256k1ValueGeneration =
  Mec.Curve.Utils.PBT.MakeValueGeneration (Mec.Curve.Secp256k1.Affine)
module Secp256k1Equality =
  Mec.Curve.Utils.PBT.MakeEquality (Mec.Curve.Secp256k1.Affine)
module Secp256k1ECProperties =
  Mec.Curve.Utils.PBT.MakeECProperties (Mec.Curve.Secp256k1.Affine)
module CompressedRepresentation =
  Mec.Curve.Utils.PBT.MakeCompressedSerialisationAffine
    (Mec.Curve.Secp256k1.Affine)

let test_vectors () =
  (* http://point-at-infinity.org/ecc/nisttv *)
  let vectors =
    [
      ( "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798",
        "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8" );
      ( "C6047F9441ED7D6D3045406E95C07CD85C778E4B8CEF3CA7ABAC09B95C709EE5",
        "1AE168FEA63DC339A3C58419466CEAEEF7F632653266D0E1236431A950CFE52A" );
      ( "F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9",
        "388F7B0F632DE8140FE337E62A37F3566500A99934C2231B6CB9FD7584B8E672" );
      ( "E493DBF1C10D80F3581E4904930B1404CC6C13900EE0758474FA94ABE8C4CD13",
        "51ED993EA0D455B75642E2098EA51448D967AE33BFBDFE40CFE97BDC47739922" );
      ( "2F8BDE4D1A07209355B4A7250A5C5128E88B84BDDC619AB7CBA8D569B240EFE4",
        "D8AC222636E5E3D6D4DBA9DDA6C9C426F788271BAB0D6840DCA87D3AA6AC62D6" );
      ( "FFF97BD5755EEEA420453A14355235D382F6472F8568A18B2F057A1460297556",
        "AE12777AACFBB620F3BE96017F45C560DE80F0F6518FE4A03C870C36B075F297" );
      ( "5CBDF0646E5DB4EAA398F365F2EA7A0E3D419B7E0330E39CE92BDDEDCAC4F9BC",
        "6AEBCA40BA255960A3178D6D861A54DBA813D0B813FDE7B5A5082628087264DA" );
      ( "2F01E5E15CCA351DAFF3843FB70F3C2F0A1BDD05E5AF888A67784EF3E10A2A01",
        "5C4DA8A741539949293D082A132D13B4C2E213D6BA5B7617B5DA2CB76CBDE904" );
      ( "ACD484E2F0C7F65309AD178A9F559ABDE09796974C57E714C35F110DFC27CCBE",
        "CC338921B0A7D9FD64380971763B61E9ADD888A4375F8E0F05CC262AC64F9C37" );
      ( "A0434D9E47F3C86235477C7B1AE6AE5D3442D49B1943C2B752A68E2A47E247C7",
        "893ABA425419BC27A3B6C7E693A24C696F794C2ED877A1593CBEE53B037368D7" );
      ( "774AE7F858A9411E5EF4246B70C65AAC5649980BE5C17891BBEC17895DA008CB",
        "D984A032EB6B5E190243DD56D7B7B365372DB1E2DFF9D6A8301D74C9C953C61B" );
      ( "A6B594B38FB3E77C6EDF78161FADE2041F4E09FD8497DB776E546C41567FEB3C",
        "71444009192228730CD8237A490FEBA2AFE3D27D7CC1136BC97E439D13330D55" );
      ( "2B4EA0A797A443D293EF5CFF444F4979F06ACFEBD7E86D277475656138385B6C",
        "7A17643FC86BA26C4CBCF7C4A5E379ECE5FE09F3AFD9689C4A8F37AA1A3F60B5" );
    ]
  in
  let bytes =
    List.map
      (fun (x, y) ->
        Bytes.concat
          Bytes.empty
          (List.map
             (fun x ->
               Mec.Curve.Secp256k1.Affine.Base.to_bytes
                 (Mec.Curve.Secp256k1.Affine.Base.of_z (Z.of_string_base 16 x)))
             [x; y]))
      vectors
  in
  List.iter
    (fun bytes -> assert (Mec.Curve.Secp256k1.Affine.check_bytes bytes))
    bytes

let () =
  let open Alcotest in
  run
    ~__FILE__
    "secp256k1 affine coordinates"
    [
      ("Vectors", [Alcotest.test_case "test vectors" `Quick test_vectors]);
      Secp256k1ValueGeneration.get_tests ();
      Secp256k1Equality.get_tests ();
      Secp256k1ECProperties.get_tests ();
      CompressedRepresentation.get_tests ();
    ]
