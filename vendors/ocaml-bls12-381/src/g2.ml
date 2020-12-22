module G2_stubs = Rustc_bls12_381_bindings.G2 (Rustc_bls12_381_stubs)

module Uncompressed = struct
  exception Not_on_curve of Bytes.t

  type t = Bytes.t

  let size_in_bytes = 192

  module Scalar = Fr

  let empty () = Bytes.make size_in_bytes '\000'

  let check_bytes bs =
    if Bytes.length bs = size_in_bytes then
      G2_stubs.uncompressed_check_bytes (Ctypes.ocaml_bytes_start bs)
    else false

  let of_bytes_opt bs = if check_bytes bs then Some bs else None

  let of_bytes_exn (g : Bytes.t) : t =
    if check_bytes g then g else raise (Not_on_curve g)

  let of_z_opt ~x ~y =
    let (x_1, x_2) = x in
    let (y_1, y_2) = y in
    let x_1 = Bytes.of_string (Z.to_bits x_1) in
    let x_2 = Bytes.of_string (Z.to_bits x_2) in
    let y_1 = Bytes.of_string (Z.to_bits y_1) in
    let y_2 = Bytes.of_string (Z.to_bits y_2) in
    let buffer = empty () in
    let res =
      G2_stubs.build_from_components
        (Ctypes.ocaml_bytes_start buffer)
        (Ctypes.ocaml_bytes_start x_1)
        (Ctypes.ocaml_bytes_start x_2)
        (Ctypes.ocaml_bytes_start y_1)
        (Ctypes.ocaml_bytes_start y_2)
    in
    if res = true then Some buffer else None

  let to_bytes g = g

  let zero =
    let g = empty () in
    G2_stubs.zero (Ctypes.ocaml_bytes_start g) ;
    g

  let one =
    let g = empty () in
    G2_stubs.one (Ctypes.ocaml_bytes_start g) ;
    g

  let random ?state () =
    ignore state ;
    let g = empty () in
    G2_stubs.random (Ctypes.ocaml_bytes_start g) ;
    g

  let add g1 g2 =
    assert (Bytes.length g1 = size_in_bytes) ;
    assert (Bytes.length g2 = size_in_bytes) ;
    let g = empty () in
    G2_stubs.add
      (Ctypes.ocaml_bytes_start g)
      (Ctypes.ocaml_bytes_start g1)
      (Ctypes.ocaml_bytes_start g2) ;
    g

  let negate g =
    assert (Bytes.length g = size_in_bytes) ;
    let buffer = empty () in
    G2_stubs.negate
      (Ctypes.ocaml_bytes_start buffer)
      (Ctypes.ocaml_bytes_start g) ;
    buffer

  let eq g1 g2 =
    assert (Bytes.length g1 = size_in_bytes) ;
    assert (Bytes.length g2 = size_in_bytes) ;
    G2_stubs.eq (Ctypes.ocaml_bytes_start g1) (Ctypes.ocaml_bytes_start g2)

  let is_zero g =
    assert (Bytes.length g = size_in_bytes) ;
    G2_stubs.is_zero (Ctypes.ocaml_bytes_start g)

  let double g =
    assert (Bytes.length g = size_in_bytes) ;
    let buffer = empty () in
    G2_stubs.double
      (Ctypes.ocaml_bytes_start buffer)
      (Ctypes.ocaml_bytes_start g) ;
    buffer

  let mul (g : t) (a : Scalar.t) : t =
    assert (Bytes.length g = size_in_bytes) ;
    assert (Bytes.length (Scalar.to_bytes a) = Scalar.size_in_bytes) ;
    let buffer = empty () in
    G2_stubs.mul
      (Ctypes.ocaml_bytes_start buffer)
      (Ctypes.ocaml_bytes_start g)
      (Ctypes.ocaml_bytes_start (Scalar.to_bytes a)) ;
    buffer
end

module Compressed = struct
  exception Not_on_curve of Bytes.t

  type t = Bytes.t

  let size_in_bytes = 96

  module Scalar = Fr

  let empty () = Bytes.make size_in_bytes '\000'

  let check_bytes bs =
    if Bytes.length bs = size_in_bytes then
      G2_stubs.compressed_check_bytes (Ctypes.ocaml_bytes_start bs)
    else false

  let of_bytes_opt bs = if check_bytes bs then Some bs else None

  let of_bytes_exn g = if check_bytes g then g else raise (Not_on_curve g)

  let of_uncompressed uncompressed =
    let g = empty () in
    G2_stubs.compressed_of_uncompressed
      (Ctypes.ocaml_bytes_start g)
      (Ctypes.ocaml_bytes_start uncompressed) ;
    of_bytes_exn g

  let to_uncompressed compressed =
    let g = Uncompressed.empty () in
    G2_stubs.uncompressed_of_compressed
      (Ctypes.ocaml_bytes_start g)
      (Ctypes.ocaml_bytes_start compressed) ;
    Uncompressed.of_bytes_exn g

  let to_bytes g = g

  let zero =
    let g = empty () in
    G2_stubs.compressed_zero (Ctypes.ocaml_bytes_start g) ;
    g

  let one =
    let g = empty () in
    G2_stubs.compressed_one (Ctypes.ocaml_bytes_start g) ;
    g

  let random ?state () =
    ignore state ;
    let g = empty () in
    G2_stubs.compressed_random (Ctypes.ocaml_bytes_start g) ;
    g

  let add g1 g2 =
    assert (Bytes.length g1 = size_in_bytes) ;
    assert (Bytes.length g2 = size_in_bytes) ;
    let g = empty () in
    G2_stubs.compressed_add
      (Ctypes.ocaml_bytes_start g)
      (Ctypes.ocaml_bytes_start g1)
      (Ctypes.ocaml_bytes_start g2) ;
    g

  let negate g =
    assert (Bytes.length g = size_in_bytes) ;
    let buffer = empty () in
    G2_stubs.compressed_negate
      (Ctypes.ocaml_bytes_start buffer)
      (Ctypes.ocaml_bytes_start g) ;
    buffer

  let eq g1 g2 =
    assert (Bytes.length g1 = size_in_bytes) ;
    assert (Bytes.length g2 = size_in_bytes) ;
    G2_stubs.compressed_eq
      (Ctypes.ocaml_bytes_start g1)
      (Ctypes.ocaml_bytes_start g2)

  let is_zero g =
    assert (Bytes.length g = size_in_bytes) ;
    G2_stubs.compressed_is_zero (Ctypes.ocaml_bytes_start g)

  let double g =
    assert (Bytes.length g = size_in_bytes) ;
    let buffer = empty () in
    G2_stubs.compressed_double
      (Ctypes.ocaml_bytes_start buffer)
      (Ctypes.ocaml_bytes_start g) ;
    buffer

  let mul (g : t) (a : Scalar.t) : t =
    assert (Bytes.length g = size_in_bytes) ;
    assert (Bytes.length (Scalar.to_bytes a) = Scalar.size_in_bytes) ;
    let buffer = empty () in
    G2_stubs.compressed_mul
      (Ctypes.ocaml_bytes_start buffer)
      (Ctypes.ocaml_bytes_start g)
      (Ctypes.ocaml_bytes_start (Fr.to_bytes a)) ;
    buffer
end
