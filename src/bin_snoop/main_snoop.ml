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

(* FIXME: https://gitlab.com/tezos/tezos/-/issues/4025
   Remove backwards compatible Tezos symlinks. *)
let () =
  (* warn_if_argv0_name_not_octez *)
  let executable_name = Filename.basename Sys.argv.(0) in
  let prefix = "tezos-" in
  if TzString.has_prefix executable_name ~prefix then
    let expected_name =
      let len_prefix = String.length prefix in
      "octez-"
      ^ String.sub
          executable_name
          len_prefix
          (String.length executable_name - len_prefix)
    in
    Format.eprintf
      "@[<v 2>@{<warning>@{<title>Warning@}@}@,\
       The executable with name @{<kwd>%s@} has been renamed to @{<kwd>%s@}. \
       The name @{<kwd>%s@} is now@,\
       deprecated, and it will be removed in a future release. Please update@,\
       your scripts to use the new name.@]@\n\
       @."
      executable_name
      expected_name
      executable_name
  else ()

module Hashtbl = Stdlib.Hashtbl

(* ------------------------------------------------------------------------- *)
(* Listing available models, solvers, benchmarks *)

let list_all_models formatter =
  List.iter
    (fun name -> Format.fprintf formatter "%s@." name)
    (Registration.all_model_names ())

let list_solvers formatter =
  Format.fprintf formatter "ridge --ridge-alpha=<float>@." ;
  Format.fprintf formatter "lasso --lasso-alpha=<float> --lasso-positive@." ;
  Format.fprintf formatter "nnls@."

let list_benchmarks formatter list =
  List.iter
    (fun (module Bench : Benchmark.S) ->
      Format.fprintf formatter "%a: %s\n" Namespace.pp Bench.name Bench.info)
    list

let list_all_benchmarks formatter =
  list_benchmarks formatter (Registration.all_benchmarks ())

(* -------------------------------------------------------------------------- *)
(* Built-in commands implementations *)

let benchmark_cmd (bench_pattern : string)
    (bench_opts : Cmdline.benchmark_options) =
  let bench =
    try Registration.find_benchmark_exn bench_pattern
    with Registration.Benchmark_not_found _ ->
      Format.eprintf "Available benchmarks:@." ;
      list_all_benchmarks Format.err_formatter ;
      exit 1
  in
  Format.eprintf
    "Benchmarking with the following options:@.%s@."
    (Commands.Benchmark_cmd.benchmark_options_to_string bench_opts) ;
  let bench = Benchmark.ex_unpack bench in
  match bench with
  | Tezos_benchmark.Benchmark.Ex bench ->
      let workload_data = Measure.perform_benchmark bench_opts.options bench in
      Option.iter
        (fun filename -> Measure.to_csv ~filename ~bench ~workload_data)
        bench_opts.csv_export ;
      Measure.save
        ~filename:bench_opts.save_file
        ~options:bench_opts.options
        ~bench
        ~workload_data

let is_constant_input (type a t) (bench : (a, t) Benchmark.poly) workload_data =
  let module Bench = (val bench) in
  List.map
    (fun Measure.{workload; _} -> Bench.workload_to_vector workload)
    workload_data
  |> List.all_equal Sparse_vec.String.equal

let rec infer_cmd model_name workload_data solver infer_opts =
  Pyinit.pyinit () ;
  let file_stats = Unix.stat workload_data in
  match file_stats.st_kind with
  | S_DIR ->
      (* User specified a directory. Automatically process all workload data in that directory. *)
      infer_cmd_full_auto model_name workload_data solver infer_opts
  | S_REG ->
      (* User specified a workload data file. Only process that file. *)
      infer_cmd_one_shot model_name workload_data solver infer_opts
  | _ ->
      Format.eprintf
        "Error: %s is neither a regular file nor a directory.@."
        workload_data ;
      exit 1

and infer_cmd_one_shot model_name workload_data solver
    (infer_opts : Cmdline.infer_parameters_options) =
  let measure = Measure.load ~filename:workload_data in
  match measure with
  | Measure.Measurement
      ((module Bench), {bench_opts = _; workload_data; date = _}) ->
      let model =
        match List.assoc_opt ~equal:String.equal model_name Bench.models with
        | Some m -> m
        | None ->
            Format.eprintf "Requested model: \"%s\" not found@." model_name ;
            Format.eprintf
              "Available for this workload: @[%a@] @."
              (Format.pp_print_list
                 ~pp_sep:(fun fmtr () -> Format.fprintf fmtr ", ")
                 Format.pp_print_string)
              (List.map fst Bench.models) ;
            exit 1
      in
      let overrides_map =
        match infer_opts.override_files with
        | None -> Free_variable.Map.empty
        | Some filenames -> Override.load ~filenames
      in
      let overrides name = Free_variable.Map.find name overrides_map in
      let problem =
        Inference.make_problem ~data:workload_data ~model ~overrides
      in
      if infer_opts.print_problem then (
        Format.eprintf "Dumping problem to stdout as requested by user@." ;
        Csv.export_stdout (Inference.problem_to_csv problem)) ;
      (match problem with
      | Inference.Degenerate {predicted; measured} ->
          let err = Inference.compute_error_statistics ~predicted ~measured in
          Format.printf
            "Error statistics:@.%a@."
            Inference.pp_error_statistics
            err
      | _ -> ()) ;
      let solver = solver_of_string solver infer_opts in
      let is_constant_input = is_constant_input (module Bench) workload_data in
      let solution =
        Inference.solve_problem ~is_constant_input problem solver
      in
      let () =
        let perform_report () =
          let report =
            Report.add_section
              ~measure
              ~model_name
              ~problem
              ~solution
              ~overrides_map
              ~short:false
              ~display_options:infer_opts.display
              (Report.create_empty ~name:"Report")
          in
          Report.to_latex report
        in
        match infer_opts.report with
        | Cmdline.NoReport -> ()
        | Cmdline.ReportToStdout ->
            let s = perform_report () in
            Format.printf "%s" s
        | Cmdline.ReportToFile output_file ->
            let s = perform_report () in
            Lwt_main.run
              (let open Lwt_syntax in
              let* _nwritten = Lwt_utils_unix.create_file output_file s in
              Lwt.return_unit) ;
            Format.eprintf "Produced report on %s@." output_file
      in
      process_output measure model_name problem solution infer_opts

and infer_cmd_full_auto model_name workload_data solver
    (infer_opts : Cmdline.infer_parameters_options) =
  let workload_files = get_all_workload_data_files workload_data in
  let overrides_map =
    match infer_opts.override_files with
    | None -> Free_variable.Map.empty
    | Some filenames -> Override.load ~filenames
  in
  let display_options =
    match infer_opts.report with
    | Cmdline.ReportToFile s ->
        {infer_opts.display with Display.save_directory = Filename.dirname s}
    | _ -> infer_opts.display
  in
  let solver = solver_of_string solver infer_opts in
  let graph, measurements = Dep_graph.load_files model_name workload_files in
  if Dep_graph.G.is_empty graph then (
    Format.eprintf "Empty dependency graph.@." ;
    exit 1) ;
  Format.eprintf "Performing topological run@." ;
  let report =
    match infer_opts.report with
    | Cmdline.NoReport -> None
    | _ -> Some (Report.create_empty ~name:"Report")
  in
  let scores_list = [] in
  Option.iter
    (fun filename ->
      let oc = open_out filename in
      Dep_graph.D.output_graph oc graph ;
      close_out oc)
    infer_opts.dot_file ;
  let map, scores_list, report =
    Dep_graph.T.fold
      (fun workload_file (overrides_map, scores_list, report) ->
        Format.eprintf "Processing: %s@." workload_file ;
        let measure = Hashtbl.find measurements workload_file in
        let overrides var = Free_variable.Map.find var overrides_map in
        let (Measure.Measurement ((module Bench), m)) = measure in
        let model =
          match Dep_graph.find_model_or_generic model_name Bench.models with
          | None ->
              Format.eprintf
                "No valid model (%s or generic) found in file %s. Availble \
                 models:.@."
                model_name
                workload_file ;
              list_all_models Format.err_formatter ;
              exit 1
          | Some model -> model
        in
        let problem =
          Inference.make_problem ~data:m.Measure.workload_data ~model ~overrides
        in
        let is_constant_input =
          is_constant_input (module Bench) m.Measure.workload_data
        in
        let solution =
          Inference.solve_problem ~is_constant_input problem solver
        in
        let report =
          Option.map
            (Report.add_section
               ~measure
               ~model_name
               ~problem
               ~solution
               ~overrides_map
               ~display_options
               ~short:true)
            report
        in
        let overrides_map =
          List.fold_left
            (fun map (variable, solution) ->
              Format.eprintf
                "Adding solution %a := %f@."
                Free_variable.pp
                variable
                solution ;
              Free_variable.Map.add variable solution map)
            overrides_map
            solution.mapping
        in
        let scores_label = (model_name, Bench.name) in
        let scores_list = (scores_label, solution.scores) :: scores_list in
        perform_plot measure model_name problem solution infer_opts ;
        perform_csv_export scores_label solution infer_opts ;
        (overrides_map, scores_list, report))
      graph
      (overrides_map, scores_list, report)
  in
  perform_save_solution model_name map scores_list infer_opts ;
  match (infer_opts.report, report) with
  | Cmdline.NoReport, _ -> ()
  | Cmdline.ReportToStdout, Some report ->
      let s = Report.to_latex report in
      Format.printf "%s" s
  | Cmdline.ReportToFile output_file, Some report ->
      let s = Report.to_latex report in
      Lwt_main.run
        (let open Lwt_syntax in
        let* _nwritten = Lwt_utils_unix.create_file output_file s in
        Lwt.return_unit) ;
      Format.eprintf "Produced report on %s@." output_file
  | _ -> assert false

and solver_of_string (solver : string)
    (infer_opts : Cmdline.infer_parameters_options) =
  match solver with
  | "ridge" -> Inference.Ridge {alpha = infer_opts.ridge_alpha}
  | "lasso" ->
      Inference.Lasso
        {alpha = infer_opts.lasso_alpha; positive = infer_opts.lasso_positive}
  | "nnls" -> Inference.NNLS
  | _ ->
      Format.eprintf "Unknown solver name.@." ;
      list_solvers Format.err_formatter ;
      exit 1

and process_output measure model_name problem solution infer_opts =
  let (Measure.Measurement ((module Bench), _)) = measure in
  let scores_label = (model_name, Bench.name) in
  perform_csv_export scores_label solution infer_opts ;
  let map = Free_variable.Map.of_seq (List.to_seq solution.mapping) in
  perform_save_solution
    model_name
    map
    [(scores_label, solution.scores)]
    infer_opts ;
  perform_plot measure model_name problem solution infer_opts

and perform_csv_export scores_label solution
    (infer_opts : Cmdline.infer_parameters_options) =
  match infer_opts.csv_export with
  | None -> ()
  | Some filename -> (
      let solution_csv_opt = Inference.solution_to_csv solution in
      match solution_csv_opt with
      | None -> ()
      | Some solution_csv ->
          let Inference.{scores; _} = solution in
          Csv.append_columns
            ~filename
            Inference.(scores_to_csv_column scores_label scores) ;
          Csv.append_columns ~filename solution_csv)

and perform_save_solution inference_model_name
    (solution : float Free_variable.Map.t)
    (scores_list : ((string * Namespace.t) * Inference.scores) list)
    (infer_opts : Cmdline.infer_parameters_options) =
  match infer_opts.save_solution with
  | None -> ()
  | Some filename ->
      Codegen.(
        save_solution
          {inference_model_name; map = solution; scores_list}
          filename) ;
      Format.eprintf "Saved solution to %s@." filename

and perform_plot measure model_name problem solution
    (infer_opts : Cmdline.infer_parameters_options) =
  if infer_opts.plot then
    ignore
    @@ Display.perform_plot
         ~measure
         ~model_name
         ~problem
         ~solution
         ~plot_target:Display.Show
         ~options:infer_opts.Cmdline.display
  else ()

and get_all_workload_data_files directory =
  let is_workload_data file =
    let regexp = Str.regexp ".*\\.workload" in
    Str.string_match regexp file 0
  in
  let lift file = directory ^ "/" ^ file in
  let handle = Unix.opendir directory in
  let rec loop acc =
    match Unix.readdir handle with
    | file ->
        if is_workload_data file then loop (lift file :: acc) else loop acc
    | exception End_of_file ->
        Unix.closedir handle ;
        acc
  in
  loop []

let codegen_cmd solution model_name codegen_options =
  let sol = Codegen.load_solution solution in
  match Registration.find_model model_name with
  | None ->
      Format.eprintf "Model %s not found, exiting@." model_name ;
      exit 1
  | Some model ->
      let transform =
        match codegen_options with
        | Cmdline.No_transform ->
            ((module Costlang.Identity) : Costlang.transform)
        | Cmdline.Fixed_point_transform options ->
            let module P = struct
              let options = options
            end in
            let module Transform = Fixed_point_transform.Apply (P) in
            ((module Transform) : Costlang.transform)
      in
      let name = Printf.sprintf "model_%s" model_name in
      let code =
        match Codegen.codegen model sol transform name with
        | exception e ->
            Format.eprintf
              "Error in code generation for model %s, exiting@."
              model_name ;
            Format.eprintf "Exception caught: %s@." (Printexc.to_string e) ;
            exit 1
        | None ->
            Format.eprintf "Code generation failed. Bad model? Exiting.@." ;
            exit 1
        | Some s -> s
      in
      Format.printf "%a@." Codegen.pp_model code

let generate_code_for_models sol models codegen_options =
  let transform =
    match codegen_options with
    | Cmdline.No_transform -> ((module Costlang.Identity) : Costlang.transform)
    | Cmdline.Fixed_point_transform options ->
        let module P = struct
          let options = options
        end in
        let module Transform = Fixed_point_transform.Apply (P) in
        ((module Transform) : Costlang.transform)
  in
  Codegen.codegen_module models sol transform

let codegen_all_cmd solution regexp codegen_options =
  let () = Format.eprintf "regexp: %s@." regexp in
  let regexp = Str.regexp regexp in
  let ok (name, _) = Str.string_match regexp name 0 in
  let sol = Codegen.load_solution solution in
  let models = List.filter ok (Registration.all_registered_models ()) in
  let result = generate_code_for_models sol models codegen_options in
  Codegen.pp_module Format.std_formatter result

let fvs_of_codegen_model model =
  let (Model.For_codegen model) = model in
  match model with
  | Model.Packaged {model; _} ->
      let module Model = (val model) in
      let module FV = Model.Def (Costlang.Free_variables) in
      FV.model
  | Model.Preapplied _ -> Free_variable.Set.empty

let codegen_infer_cmd solution codegen_options =
  let solution = Codegen.load_solution solution in

  Format.eprintf "Inference model: %s@." solution.inference_model_name ;

  let all_benchmarks =
    Registration.Name_table.to_seq Registration.bench_table
  in

  let ( let* ) = Option.bind in
  let or_else m f = match m with Some x -> Some x | None -> f () in

  let found_codegen_models =
    let get_codegen_from_bench (bench_name, (module Bench : Benchmark.S)) =
      (* The inference model matches. *)
      let* _model =
        List.assoc_opt ~equal:( = ) solution.inference_model_name Bench.models
      in
      (* We assume a benchmark has up to one codegen model, *)
      (* which has the same name as the benchmark and may be qualified with "__alpha" *)
      let codegen_name = Namespace.basename bench_name in
      let codegen_name_alpha = codegen_name ^ "__alpha" in
      let find_codegen name =
        let* model =
          Registration.String_table.find_opt Registration.codegen_table name
        in
        Some (name, model)
      in
      or_else (find_codegen codegen_name) (fun () ->
          find_codegen codegen_name_alpha)
    in
    Seq.filter_map get_codegen_from_bench all_benchmarks
  in

  (* Model's free variables must be included in the solution's keys *)
  let codegen_models =
    let model_fvs_included_in_sol model =
      let fvs = fvs_of_codegen_model model in
      Free_variable.Set.for_all
        (fun fv -> Free_variable.Map.mem fv solution.map)
        fvs
    in
    Seq.filter
      (fun (model_name, model) ->
        let ok = model_fvs_included_in_sol model in
        if not ok then Format.eprintf "Skipping model %s@." model_name ;
        ok)
      found_codegen_models
  in

  let generated_code =
    generate_code_for_models
      solution
      (List.of_seq codegen_models)
      codegen_options
  in
  Codegen.pp_module Format.std_formatter generated_code

(* -------------------------------------------------------------------------- *)
(* Entrypoint *)

(* Activate logging system. *)
let () =
  Lwt_main.run
  @@ Tezos_base_unix.Internal_event_unix.(
       init
         ~lwt_log_sink:Lwt_log_sink_unix.default_cfg
         ~configuration:Configuration.default)
       ()

let () =
  if Commands.list_solvers then list_solvers Format.std_formatter ;
  if Commands.list_models then list_all_models Format.std_formatter

let () =
  match !Cmdline.commandline_outcome_ref with
  | None -> ()
  | Some outcome -> (
      match outcome with
      | Cmdline.No_command -> exit 0
      | Cmdline.Benchmark {bench_name; bench_opts} ->
          benchmark_cmd bench_name bench_opts
      | Cmdline.Infer {model_name; workload_data; solver; infer_opts} ->
          infer_cmd model_name workload_data solver infer_opts
      | Cmdline.Codegen {solution; model_name; codegen_options} ->
          codegen_cmd solution model_name codegen_options
      | Cmdline.Codegen_all {solution; matching; codegen_options} ->
          codegen_all_cmd solution matching codegen_options
      | Cmdline.Codegen_inferred {solution; codegen_options} ->
          codegen_infer_cmd solution codegen_options)
