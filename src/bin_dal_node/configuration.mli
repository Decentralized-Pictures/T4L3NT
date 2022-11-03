(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

type t = {
  use_unsafe_srs : bool;
      (** Run dal-node in test mode with an unsafe SRS (Trusted setup) *)
  data_dir : string;  (** The path to the DAL node data directory *)
  rpc_addr : string;  (** The address the DAL node listens to *)
  rpc_port : int;  (** The port the DAL node listens to *)
}

(** [filename config] gets the path to config file *)
val filename : t -> string

(** [data_dir_path config subpath] builds a subpath relatively to the
    [config] *)
val data_dir_path : t -> string -> string

val default_data_dir : string

val default_rpc_addr : string

val default_rpc_port : int

(** [save config] writes config file in [config.data_dir] *)
val save : t -> unit tzresult Lwt.t

val load : data_dir:string -> (t, Error_monad.tztrace) result Lwt.t
