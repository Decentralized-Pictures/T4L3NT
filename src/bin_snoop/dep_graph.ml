(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018 Nomadic Labs. <contact@nomadic-labs.com>               *)
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

(* Models associated to benchmarks have free variables. Some of these
   variables are to be inferred from the empirical data, but some others
   must be provided by other models and correspond to _dependencies_
   of a model upon the result of another one.

   The goal of this module is to take as input a set of models seen as
   sets of free variables and infer back a partial dependency ordering
   among them. In particular, a topological sort of this partial ordering
   yields a scheduling for the inference process that respects cross-model
   dependencies.

   Such a problem does not always have a solution, or can have several
   solutions (ie it is in general ill-posed). When there's more than
   one possible solution, we use a simple heuristic to pick one.
*)

module Fv_map = Free_variable.Map
module Fv_set = Free_variable.Set
module Fv_set_set = Set.Make (Free_variable.Set)

module Directed_graph = Graph.Imperative.Digraph.Concrete (struct
  type t = string

  let hash = Hashtbl.hash

  let equal = String.equal

  let compare = String.compare
end)

module Directed_graph_with_attributes = struct
  include Directed_graph

  let edge_attributes _ = []

  let default_edge_attributes _ = []

  let vertex_attributes s = [`Label (String.escaped s)]

  let default_vertex_attributes _ = []

  let graph_attributes _ = []

  let get_subgraph _ = None

  let vertex_name s = String.escaped s
end

module G = Directed_graph_with_attributes

(* Topological sort *)
module T = Graph.Topological.Make (G)

(* Graphviz output *)
module D = Graph.Graphviz.Dot (G)

module Solver = struct
  (* We proceed iteratively on a set of _nodes_.

     Nodes correspond to sets of free variables.

     A node is _solved_ when its variables can be partitioned in two subsets:
     - the set of _dependencies_
     - the set of _provided_ variables

     A node is _unsolved_ when this partition cannot be decided yet:
     - some free variables are kwown to be _dependencies_
     - some other are still undecided.

     A node is _redundant_ when it is solved and its set of _provided_ variables
     is empty. *)

  type 'a meta = {data : 'a; uid : int}

  type 'a unsolved = {
    dependencies : Fv_set.t;
    undecided_variables : Fv_set.t;
    meta : 'a meta;
  }

  type 'a solved = {
    dependencies : Fv_set.t;
    provides : Fv_set.t;
    meta : 'a meta;
  }

  type 'a node =
    | Solved of 'a solved
    | Redundant of 'a solved
    | Unsolved of 'a unsolved

  type 'meta state = {
    solved : 'meta solved list;
    unsolved : 'meta unsolved list;
  }

  let empty_state = {solved = []; unsolved = []}

  let force_solved {dependencies; undecided_variables; meta} =
    {dependencies; provides = undecided_variables; meta}

  let pp_list =
    Format.pp_print_list
      ~pp_sep:(fun fmtr () -> Format.fprintf fmtr ",")
      Free_variable.pp

  let pp_node fmtr (from, to_) =
    Format.fprintf
      fmtr
      "%a -> %a"
      pp_list
      (Fv_set.elements from)
      pp_list
      (Fv_set.elements to_)

  (* Sets free variable [v] to be 'solved' in node [n] *)
  let set_variable_as_solved (n : 'a unsolved) (v : Free_variable.t) =
    if not (Fv_set.mem v n.undecided_variables) then Unsolved n
    else
      let undecided = Fv_set.remove v n.undecided_variables in
      let deps = Fv_set.add v n.dependencies in
      let card = Fv_set.cardinal undecided in
      if card = 0 then
        Redundant {dependencies = deps; provides = Fv_set.empty; meta = n.meta}
      else if card = 1 then
        let () = Format.eprintf "Solved: %a@." pp_node (deps, undecided) in
        (* If there's only one variable left in [undecided], it must
           in fact be constrained by the model and becomes [provided]. *)
        Solved {dependencies = deps; provides = undecided; meta = n.meta}
      else
        Unsolved
          {dependencies = deps; undecided_variables = undecided; meta = n.meta}

  let rec propagate_solved state (n : 'a solved) solved_but_not_propagated =
    let (solved_but_not_propagated, unsolved) =
      List.fold_left
        (fun (solved_acc, unsolved_acc) unsolved ->
          Fv_set.fold
            (fun provided_var (solved_acc, unsolved_acc) ->
              let node = set_variable_as_solved unsolved provided_var in
              match node with
              | Redundant node | Solved node ->
                  (node :: solved_acc, unsolved_acc)
              | Unsolved node ->
                  (solved_acc, node :: unsolved_acc))
            n.provides
            (solved_acc, unsolved_acc))
        (solved_but_not_propagated, [])
        state.unsolved
    in
    let state = {solved = n :: state.solved; unsolved} in
    propagate_solved_loop state solved_but_not_propagated

  and propagate_solved_loop state solved_but_not_propagated =
    match solved_but_not_propagated with
    | [] ->
        state
    | solved :: solved_list ->
        propagate_solved state solved solved_list

  let solve {solved; unsolved} =
    assert (solved = []) ;
    let (roots, others) =
      List.partition
        (fun (node : 'a unsolved) ->
          Fv_set.is_empty node.dependencies
          && Fv_set.cardinal node.undecided_variables = 1)
        unsolved
    in
    (* Set the roots as solved. *)
    let roots =
      List.map
        (fun root ->
          {
            dependencies = Fv_set.empty;
            provides = root.undecided_variables;
            meta = root.meta;
          })
        roots
    in
    List.iter
      (fun {provides; _} ->
        Format.eprintf
          "Root: %a@."
          Free_variable.pp
          (Option.get (Fv_set.choose provides)))
      roots ;
    (* Propagate iteratively. *)
    let state = {solved = []; unsolved = others} in
    propagate_solved_loop state roots

  let solve ~force state =
    let least_constrained = solve state in
    match state.unsolved with
    | [] ->
        least_constrained
    | _ ->
        if force then (
          Format.eprintf
            "Dep_graph.Solver.solve: forcing remaining unconstrained \
             variables as solved.@." ;
          List.iter
            (fun {dependencies; undecided_variables; _} ->
              Format.eprintf
                "Forced: %a@."
                pp_node
                (dependencies, undecided_variables))
            least_constrained.unsolved ;
          let set_solved = List.map force_solved least_constrained.unsolved in
          {solved = least_constrained.solved @ set_solved; unsolved = []} )
        else
          Stdlib.failwith
            "Dep_graph.Solver.solve: state is not completely solved, \
             aborting.@."

  let unsolved_of_fvs =
    let c = ref 0 in
    fun fvs data ->
      let uid = !c in
      incr c ;
      {
        dependencies = Fv_set.empty;
        undecided_variables = fvs;
        meta = {data; uid};
      }

  let add_node state fvs data =
    let node = unsolved_of_fvs fvs data in
    {state with unsolved = node :: state.unsolved}
end

module Hashtbl = Stdlib.Hashtbl

let pp_print_set fmtr (set : Free_variable.Set.t) =
  let elts = Free_variable.Set.elements set in
  Format.fprintf fmtr "{ " ;
  Format.pp_print_list
    ~pp_sep:(fun fmtr () -> Format.fprintf fmtr ";")
    Free_variable.pp
    fmtr
    elts ;
  Format.fprintf fmtr " }"

let pp_print_set_set fmtr (set_set : Fv_set_set.t) =
  let elts = Fv_set_set.elements set_set in
  Format.fprintf fmtr "{ " ;
  Format.pp_print_list
    ~pp_sep:(fun fmtr () -> Format.fprintf fmtr ";")
    pp_print_set
    fmtr
    elts ;
  Format.fprintf fmtr " }"

let get_free_variables (type workload) (model : workload Model.t)
    (workload : workload) : Free_variable.Set.t =
  let applied = Model.apply model workload in
  let module M = (val applied) in
  let module R = M (Costlang.Free_variables) in
  R.applied

let add_names (state : string Solver.state) (filename : string)
    (names : Free_variable.Set.t) : string Solver.state =
  Format.eprintf "for %s, adding names %a@." filename pp_print_set names ;
  Solver.add_node state names filename

exception
  Variable_solved_by_several_datasets of {
    free_var : Free_variable.t;
    filename : string;
    other_file : string;
  }

exception Missing_file_for_free_variable of {free_var : Free_variable.t}

let () =
  Printexc.register_printer (function
      | Variable_solved_by_several_datasets {free_var; filename; other_file} ->
          let error =
            Format.asprintf
              "Variable %a has conflicting constraints from datasets %s and %s.\n\
               Try to remove one?\n"
              Free_variable.pp
              free_var
              filename
              other_file
          in
          Some error
      | Missing_file_for_free_variable {free_var} ->
          let error =
            Format.asprintf
              "Bug found: variable %a is not associated to any dataset. \
               Please report.\n"
              Free_variable.pp
              free_var
          in
          Some error
      | _ ->
          None)

let to_graph (solved : string Solver.solved list) =
  let len = List.length solved in
  let g = G.create ~size:len () in
  let solved_to_file =
    List.fold_left
      (fun map {Solver.provides; meta; _} ->
        Fv_set.fold
          (fun free_var map ->
            match Fv_map.find free_var map with
            | None ->
                Fv_map.add free_var meta.data map
            | Some other_file ->
                raise
                  (Variable_solved_by_several_datasets
                     {free_var; filename = meta.data; other_file}))
          provides
          map)
      Fv_map.empty
      solved
  in
  List.iter
    (fun {Solver.dependencies; meta; _} ->
      Fv_set.iter
        (fun dep ->
          match Fv_map.find dep solved_to_file with
          | None ->
              raise (Missing_file_for_free_variable {free_var = dep})
          | Some dep_file ->
              G.add_edge g meta.data dep_file)
        dependencies)
    solved ;
  g

let find_model_or_generic model_name model_list =
  match List.assoc_opt model_name model_list with
  | None ->
      List.assoc_opt "*" model_list
  | res ->
      res

let load_files (model_name : string) (files : string list) =
  (* Use a table to store loaded measurements *)
  let table = Hashtbl.create 51 in
  let state =
    List.fold_left
      (fun graph filename ->
        let measurement = Measure.load ~filename in
        match measurement with
        | Tezos_benchmark.Measure.Measurement ((module Bench), m) -> (
          match find_model_or_generic model_name Bench.models with
          | None ->
              graph
          | Some model ->
              let () =
                Format.eprintf "Loading %s in dependency graph@." filename
              in
              Hashtbl.add table filename measurement ;
              let names =
                List.fold_left
                  (fun acc {Measure.workload; _} ->
                    let names = get_free_variables model workload in
                    Free_variable.Set.union names acc)
                  Free_variable.Set.empty
                  m.Measure.workload_data
              in
              add_names graph filename names ))
      Solver.empty_state
      files
  in
  let state = Solver.solve ~force:true state in
  (to_graph state.solved, table)
