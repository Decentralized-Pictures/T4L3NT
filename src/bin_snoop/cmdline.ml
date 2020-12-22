(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

(* -------------------------------------------------------------------------- *)
(* Typedefs *)

(* Benchmark command related types *)

type determinizer_option = Percentile of int | Mean

type storage_kind =
  | Memory
  | Disk of {
      source : Signature.public_key_hash;
      base_dir : string;
      header_json : string;
    }

type benchmark_options = {
  options : Measure.options;
  save_file : string;
  storage : storage_kind;
}

type codegen_options =
  | No_transform
  | Fixed_point_transform of Fixed_point_transform.options

(* Infer command related types *)

type report = NoReport | ReportToStdout | ReportToFile of string

type infer_parameters_options = {
  print_problem : bool;
  (* Dump the regression problem *)
  csv_export : string option;
  (* Export solution to csv *)
  plot : bool;
  (* Plot solution *)
  ridge_alpha : float;
  (* Regularisation parameter for ridge regression *)
  lasso_alpha : float;
  (* Regularisation parameter for lasso regression *)
  lasso_positive : bool;
  (* Constrain lasso solution to be positive *)
  override_files : string list option;
  (* Source of CSV files for overriding free variables *)
  report : report;
  (* LaTeX report parameters *)
  save_solution : string option; (* Serialise solution to given file *)
}

(* Outcome of command-line parsing. *)

type command =
  | Benchmark of {bench_name : string; bench_opts : benchmark_options}
  | Infer of {
      model_name : string;
      workload_data : string;
      solver : string;
      infer_opts : infer_parameters_options;
    }
  | Cull_outliers of {
      workload_data : string;
      nsigmas : float;
      save_file : string;
    }
  | Codegen of {
      solution : string;
      model_name : string;
      codegen_options : codegen_options;
    }
  | No_command

(* -------------------------------------------------------------------------- *)
(* Encodings *)

let storage_kind_encoding : storage_kind Data_encoding.t =
  let open Data_encoding in
  union
    [ case
        ~title:"memory"
        (Tag 0)
        unit
        (function Memory -> Some () | Disk _ -> None)
        (fun () -> Memory);
      case
        ~title:"disk"
        (Tag 1)
        (tup3 Signature.Public_key_hash.encoding string string)
        (function
          | Memory ->
              None
          | Disk {source; base_dir; header_json} ->
              Some (source, base_dir, header_json))
        (fun (source, base_dir, header_json) ->
          Disk {source; base_dir; header_json}) ]

let benchmark_options_encoding =
  (* : benchmark_options Data_encoding.encoding in *)
  let open Data_encoding in
  def "benchmark_options_encoding"
  @@ conv
       (fun {options; save_file; storage} -> (options, save_file, storage))
       (fun (options, save_file, storage) -> {options; save_file; storage})
       (obj3
          (req "options" Measure.options_encoding)
          (req "save_file" string)
          (req "storage" storage_kind_encoding))

(* -------------------------------------------------------------------------- *)
(* Global state set by command line parsing. Custom benchmark commands need
   not set this variable. *)

let commandline_outcome_ref : command option ref = ref None
