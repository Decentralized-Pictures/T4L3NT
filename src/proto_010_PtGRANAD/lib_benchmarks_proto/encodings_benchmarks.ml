(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2021 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

open Protocol

module Micheline_common = struct
  let make_printable node =
    Micheline_printer.printable
      Michelson_v1_primitives.string_of_prim
      (Micheline.strip_locations node)

  type phase = Trace_production | In_protocol | Global

  type error =
    | Bad_micheline of {
        benchmark_name : string;
        micheline : Alpha_context.Script.node;
        phase : phase;
      }

  exception Micheline_benchmark of error

  let pp_phase fmtr (phase : phase) =
    match phase with
    | Trace_production -> Format.fprintf fmtr "trace production"
    | In_protocol -> Format.fprintf fmtr "in protocol"
    | Global -> Format.fprintf fmtr "global"

  let pp_error fmtr = function
    | Bad_micheline {benchmark_name; micheline; phase} ->
        Format.open_vbox 1 ;
        Format.fprintf fmtr "Bad micheline:@," ;
        Format.fprintf fmtr "benchmark = %s@," benchmark_name ;
        Format.fprintf
          fmtr
          "expression = @[<v 1>%a@]@,"
          Micheline_printer.print_expr
          (make_printable micheline) ;
        Format.fprintf fmtr "phase = %a@," pp_phase phase ;
        Format.close_box ()

  let bad_micheline benchmark_name micheline phase =
    raise
      (Micheline_benchmark (Bad_micheline {benchmark_name; micheline; phase}))

  type workload = {size : Size.micheline_size; bytes : int}

  let workload_encoding =
    let open Data_encoding in
    def "encoding_micheline_trace"
    @@ conv
         (fun {size; bytes} -> (size, bytes))
         (fun (size, bytes) -> {size; bytes})
         (obj2
            (req "micheline_size" Size.micheline_size_encoding)
            (req "micheline_bytes" Size.encoding))

  let workload_to_vector (workload : workload) =
    let keys =
      [
        ("encoding_micheline_traversal", Size.to_float workload.size.traversal);
        ("encoding_micheline_int_bytes", Size.to_float workload.size.int_bytes);
        ( "encoding_micheline_string_bytes",
          Size.to_float workload.size.string_bytes );
        ("encoding_micheline_bytes", Size.to_float workload.bytes);
      ]
    in
    Sparse_vec.String.of_list keys

  let tags = [Tags.encoding]

  let model_size name =
    Model.make
      ~conv:(fun {size = {Size.traversal; int_bytes; string_bytes}; _} ->
        (traversal, (int_bytes, (string_bytes, ()))))
      ~model:
        (Model.trilinear
           ~coeff1:
             (Free_variable.of_string
                (Format.asprintf "%s_micheline_traversal" name))
           ~coeff2:
             (Free_variable.of_string
                (Format.asprintf "%s_micheline_int_bytes" name))
           ~coeff3:
             (Free_variable.of_string
                (Format.asprintf "%s_micheline_string_bytes" name)))

  let model_bytes name =
    Model.make
      ~conv:(fun {bytes; _} -> (bytes, ()))
      ~model:
        (Model.linear
           ~coeff:
             (Free_variable.of_string
                (Format.asprintf "%s_micheline_bytes" name)))

  let models name =
    [("micheline", model_size name); ("micheline_bytes", model_bytes name)]
end

module Encoding_micheline : Benchmark.S = struct
  include Translator_benchmarks.Config
  include Micheline_common

  let name = "ENCODING_MICHELINE"

  let info = "Benchmarking strip_location + encoding of Micheline to bytes"

  let micheline_serialization_trace (micheline_node : Alpha_context.Script.node)
      =
    match
      Data_encoding.Binary.to_bytes
        Protocol.Script_repr.expr_encoding
        (Micheline.strip_locations micheline_node)
    with
    | Error err ->
        Format.eprintf
          "micheline_serialization_trace: %a@."
          Data_encoding.Binary.pp_write_error
          err ;
        None
    | Ok bytes ->
        let micheline_size = Size.of_micheline micheline_node in
        Some {size = micheline_size; bytes = Size.bytes bytes}

  let encoding_micheline_benchmark (node : Protocol.Script_repr.expr) =
    let node = Micheline.root node in
    let workload =
      match micheline_serialization_trace node with
      | None -> Micheline_common.bad_micheline name node Trace_production
      | Some trace -> trace
    in
    let closure () =
      try
        ignore
          (Data_encoding.Binary.to_bytes_exn
             Protocol.Script_repr.expr_encoding
             (Micheline.strip_locations node))
      with _ -> Micheline_common.bad_micheline name node In_protocol
    in
    Generator.Plain {workload; closure}

  let make_bench rng_state cfg () =
    match
      Michelson_generation.make_data_sampler rng_state cfg.generator_config
    with
    | Data {term; typ = _} -> encoding_micheline_benchmark term
    | _ -> assert false

  let create_benchmarks ~rng_state ~bench_num config =
    match config.michelson_terms_file with
    | Some file ->
        Format.eprintf "Loading terms from %s@." file ;
        let terms = Michelson_generation.load_file file in
        List.map
          (function
            | Michelson_generation.Data {term; typ = _}
            | Michelson_generation.Code {term; bef = _} ->
                fun () -> encoding_micheline_benchmark term)
          terms
    | None -> List.repeat bench_num (make_bench rng_state config)

  let models = models name
end

let () = Registration_helpers.register (module Encoding_micheline)

module Decoding_micheline : Benchmark.S = struct
  include Translator_benchmarks.Config
  include Micheline_common

  let name = "DECODING_MICHELINE"

  let info = "Decoding of bytes to Micheline"

  let micheline_deserialization_trace (micheline_bytes : Bytes.t) =
    match
      Data_encoding.Binary.of_bytes
        Protocol.Script_repr.expr_encoding
        micheline_bytes
    with
    | Error err ->
        Format.eprintf
          "micheline_deserialization_trace: %a@."
          Data_encoding.Binary.pp_read_error
          err ;
        None
    | Ok micheline_node ->
        let micheline_size =
          Size.of_micheline (Micheline.root micheline_node)
        in
        Some {size = micheline_size; bytes = Size.bytes micheline_bytes}

  let decoding_micheline_benchmark (node : Protocol.Script_repr.expr) =
    let encoded =
      Data_encoding.Binary.to_bytes_exn Protocol.Script_repr.expr_encoding node
    in
    let node = Micheline.root node in
    let workload =
      match micheline_deserialization_trace encoded with
      | None -> bad_micheline name node Trace_production
      | Some trace -> trace
    in
    let closure () =
      try
        ignore
          (Data_encoding.Binary.of_bytes_exn
             Protocol.Script_repr.expr_encoding
             encoded)
      with _ -> bad_micheline name node In_protocol
    in
    Generator.Plain {workload; closure}

  let make_bench rng_state cfg () =
    match
      Michelson_generation.make_data_sampler rng_state cfg.generator_config
    with
    | Data {term; typ = _} -> decoding_micheline_benchmark term
    | _ -> assert false

  let create_benchmarks ~rng_state ~bench_num config =
    match config.michelson_terms_file with
    | Some file ->
        Format.eprintf "Loading terms from %s@." file ;
        let terms = Michelson_generation.load_file file in
        List.map
          (function
            | Michelson_generation.Data {term; typ = _}
            | Michelson_generation.Code {term; bef = _} ->
                fun () -> decoding_micheline_benchmark term)
          terms
    | None -> List.repeat bench_num (make_bench rng_state config)

  let models = models name
end

let () = Registration_helpers.register (module Decoding_micheline)

(* TODO: benchmark timestamps with big values (>64 bits) *)
module Timestamp = struct
  let () =
    Registration_helpers.register
    @@
    let open Tezos_shell_benchmarks.Encoding_benchmarks_helpers in
    fixed_size_shared
      ~name:"TIMESTAMP_READABLE_ENCODING"
      ~generator:(fun rng_state ->
        let seconds_in_year = 30_000_000 in
        let offset = Random.State.int rng_state seconds_in_year in
        Alpha_context.Script_timestamp.of_zint (Z.of_int (1597764116 + offset)))
      ~make_bench:(fun generator () ->
        let tstamp_string = generator () in
        let closure () =
          ignore (Alpha_context.Script_timestamp.to_string tstamp_string)
        in
        Generator.Plain {workload = (); closure})

  let () =
    Registration_helpers.register
    @@
    let open Tezos_shell_benchmarks.Encoding_benchmarks_helpers in
    fixed_size_shared
      ~name:"TIMESTAMP_READABLE_DECODING"
      ~generator:(fun rng_state ->
        let seconds_in_year = 30_000_000 in
        let offset = Random.State.int rng_state seconds_in_year in
        let tstamp =
          Alpha_context.Script_timestamp.of_zint
            (Z.of_int (1597764116 + offset))
        in
        Alpha_context.Script_timestamp.to_string tstamp)
      ~make_bench:(fun generator () ->
        let tstamp_string = generator () in
        let closure () =
          ignore (Alpha_context.Script_timestamp.of_string tstamp_string)
        in
        Generator.Plain {workload = (); closure})
end

module BLS = struct
  open Tezos_shell_benchmarks.Encoding_benchmarks_helpers

  let () =
    Registration_helpers.register
    @@ make_encode_fixed_size_to_bytes
         ~name:"ENCODING_BLS_FR"
         ~to_bytes:Bls12_381.Fr.to_bytes
         ~generator:(fun rng_state -> Bls12_381.Fr.random ~state:rng_state ())

  let () =
    Registration_helpers.register
    @@ make_encode_fixed_size_to_bytes
         ~name:"ENCODING_BLS_G1"
         ~to_bytes:Bls12_381.G1.to_bytes
         ~generator:(fun rng_state -> Bls12_381.G1.random ~state:rng_state ())

  let () =
    Registration_helpers.register
    @@ make_encode_fixed_size_to_bytes
         ~name:"ENCODING_BLS_G2"
         ~to_bytes:Bls12_381.G2.to_bytes
         ~generator:(fun rng_state -> Bls12_381.G2.random ~state:rng_state ())

  let () =
    Registration_helpers.register
    @@ make_decode_fixed_size_from_bytes
         ~name:"DECODING_BLS_FR"
         ~to_bytes:Bls12_381.Fr.to_bytes
         ~from_bytes:Bls12_381.Fr.of_bytes_exn
         ~generator:(fun rng_state -> Bls12_381.Fr.random ~state:rng_state ())

  let () =
    Registration_helpers.register
    @@ make_decode_fixed_size_from_bytes
         ~name:"DECODING_BLS_G1"
         ~to_bytes:Bls12_381.G1.to_bytes
         ~from_bytes:Bls12_381.G1.of_bytes_exn
         ~generator:(fun rng_state -> Bls12_381.G1.random ~state:rng_state ())

  let () =
    Registration_helpers.register
    @@ make_decode_fixed_size_from_bytes
         ~name:"DECODING_BLS_G2"
         ~to_bytes:Bls12_381.G2.to_bytes
         ~from_bytes:Bls12_381.G2.of_bytes_exn
         ~generator:(fun rng_state -> Bls12_381.G2.random ~state:rng_state ())

  let () =
    Registration_helpers.register
    @@ fixed_size_shared
         ~name:"BLS_FR_FROM_Z"
         ~generator:(fun rng_state -> Bls12_381.Fr.random ~state:rng_state ())
         ~make_bench:(fun generator () ->
           let generated = generator () in
           let z = Bls12_381.Fr.to_z generated in
           let closure () = ignore (Bls12_381.Fr.of_z z) in
           Generator.Plain {workload = (); closure})

  let () =
    Registration_helpers.register
    @@ fixed_size_shared
         ~name:"BLS_FR_TO_Z"
         ~generator:(fun rng_state -> Bls12_381.Fr.random ~state:rng_state ())
         ~make_bench:(fun generator () ->
           let generated = generator () in
           let closure () = ignore (Bls12_381.Fr.to_z generated) in
           Generator.Plain {workload = (); closure})
end
