module Pairing_stubs = Rustc_bls12_381_bindings.Pairing (Rustc_bls12_381_stubs)

(* The pairing goes in a finite field, not a group. We strengthen the signature *)
module Make
    (G1 : Elliptic_curve_sig.T)
    (G2 : Elliptic_curve_sig.T)
    (GT : Ff.BASE) =
struct
  exception FailToComputeFinalExponentiation of GT.t

  let miller_loop_simple (g1 : G1.t) (g2 : G2.t) : GT.t =
    let buffer = Bytes.make GT.size_in_bytes '\000' in
    Pairing_stubs.miller_loop_simple
      (Ctypes.ocaml_bytes_start buffer)
      (Ctypes.ocaml_bytes_start (G1.to_bytes g1))
      (Ctypes.ocaml_bytes_start (G2.to_bytes g2)) ;
    GT.of_bytes_exn buffer

  let pairing (g1 : G1.t) (g2 : G2.t) : GT.t =
    let buffer = Bytes.make GT.size_in_bytes '\000' in
    Pairing_stubs.pairing
      (Ctypes.ocaml_bytes_start buffer)
      (Ctypes.ocaml_bytes_start (G1.to_bytes g1))
      (Ctypes.ocaml_bytes_start (G2.to_bytes g2)) ;
    GT.of_bytes_exn buffer

  let final_exponentiation_exn (e : GT.t) : GT.t =
    let buffer = Bytes.make GT.size_in_bytes '\000' in
    if GT.is_zero e then raise (FailToComputeFinalExponentiation e)
    else (
      Pairing_stubs.final_exponentiation
        (Ctypes.ocaml_bytes_start buffer)
        (Ctypes.ocaml_bytes_start (GT.to_bytes e)) ;
      GT.of_bytes_exn buffer )

  let final_exponentiation_opt (e : GT.t) : GT.t option =
    if GT.is_zero e then None
    else
      let buffer = Bytes.make GT.size_in_bytes '\000' in
      Pairing_stubs.final_exponentiation
        (Ctypes.ocaml_bytes_start buffer)
        (Ctypes.ocaml_bytes_start (GT.to_bytes e)) ;
      GT.of_bytes_opt buffer

  let miller_loop (xs : (G1.t * G2.t) list) : GT.t =
    let rec f acc xs =
      let buffer = Bytes.make GT.size_in_bytes '\000' in
      match xs with
      | [] -> acc
      | [(g1, g2)] -> GT.mul (miller_loop_simple g1 g2) acc
      | [(g1_1, g2_1); (g1_2, g2_2)] ->
          Pairing_stubs.miller_loop_2
            (Ctypes.ocaml_bytes_start buffer)
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_1))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_2))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_1))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_2)) ;
          GT.mul (GT.of_bytes_exn buffer) acc
      | [(g1_1, g2_1); (g1_2, g2_2); (g1_3, g2_3)] ->
          Pairing_stubs.miller_loop_3
            (Ctypes.ocaml_bytes_start buffer)
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_1))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_2))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_3))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_1))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_2))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_3)) ;
          GT.mul (GT.of_bytes_exn buffer) acc
      | [(g1_1, g2_1); (g1_2, g2_2); (g1_3, g2_3); (g1_4, g2_4)] ->
          Pairing_stubs.miller_loop_4
            (Ctypes.ocaml_bytes_start buffer)
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_1))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_2))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_3))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_4))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_1))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_2))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_3))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_4)) ;
          GT.mul (GT.of_bytes_exn buffer) acc
      | [(g1_1, g2_1); (g1_2, g2_2); (g1_3, g2_3); (g1_4, g2_4); (g1_5, g2_5)]
        ->
          Pairing_stubs.miller_loop_5
            (Ctypes.ocaml_bytes_start buffer)
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_1))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_2))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_3))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_4))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_5))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_1))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_2))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_3))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_4))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_5)) ;
          GT.mul (GT.of_bytes_exn buffer) acc
      | (g1_1, g2_1)
        :: (g1_2, g2_2)
           :: (g1_3, g2_3) :: (g1_4, g2_4) :: (g1_5, g2_5) :: (g1_6, g2_6) :: xs
        ->
          Pairing_stubs.miller_loop_6
            (Ctypes.ocaml_bytes_start buffer)
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_1))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_2))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_3))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_4))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_5))
            (Ctypes.ocaml_bytes_start (G1.to_bytes g1_6))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_1))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_2))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_3))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_4))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_5))
            (Ctypes.ocaml_bytes_start (G2.to_bytes g2_6)) ;
          let acc = GT.mul (GT.of_bytes_exn buffer) acc in
          f acc xs
    in
    if List.length xs = 0 then failwith "Empty list of points given"
    else f GT.one xs
end

module Bls12_381 = Make (G1.Uncompressed) (G2.Uncompressed) (Fq12)
include Bls12_381
