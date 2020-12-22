(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
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

type error_category = [`Branch | `Temporary | `Permanent]

(** CORE : errors *)

type error = ..

val error_encoding : error Data_encoding.t

val pp : Format.formatter -> error -> unit

(** EXT : error registration/query *)

val register_error_kind :
  error_category ->
  id:string ->
  title:string ->
  description:string ->
  ?pp:(Format.formatter -> 'err -> unit) ->
  'err Data_encoding.t ->
  (error -> 'err option) ->
  ('err -> error) ->
  unit

val classify_error : error -> error_category

val json_of_error : error -> Data_encoding.json

val error_of_json : Data_encoding.json -> error

type error_info = {
  category : error_category;
  id : string;
  title : string;
  description : string;
  schema : Data_encoding.json_schema;
}

val pp_info : Format.formatter -> error_info -> unit

(** Retrieves information of registered errors *)
val get_registered_errors : unit -> error_info list

(** MONAD : trace, monad, etc. *)

(* This is concrete for backwards compatibility purpose. However:
   - it MUST NEVER be empty
   - it is not intended for general use (prefer {!error}, {!fail} and such). *)
type 'err trace = 'err list

type 'a tzresult = ('a, error trace) result

val trace_encoding : error trace Data_encoding.t

val result_encoding : 'a Data_encoding.t -> 'a tzresult Data_encoding.t

val ok : 'a -> ('a, 'trace) result

val ok_unit : (unit, 'trace) result

val ok_none : ('a option, 'trace) result

val ok_some : 'a -> ('a option, 'trace) result

val ok_nil : ('a list, 'trace) result

val ok_true : (bool, 'trace) result

val ok_false : (bool, 'trace) result

val return : 'a -> ('a, 'trace) result Lwt.t

val return_unit : (unit, 'trace) result Lwt.t

val return_none : ('a option, 'trace) result Lwt.t

val return_some : 'a -> ('a option, 'trace) result Lwt.t

val return_nil : ('a list, 'trace) result Lwt.t

val return_true : (bool, 'trace) result Lwt.t

val return_false : (bool, 'trace) result Lwt.t

val error : 'err -> ('a, 'err trace) result

val fail : 'err -> ('a, 'err trace) result Lwt.t

val ( >>= ) : 'a Lwt.t -> ('a -> 'b Lwt.t) -> 'b Lwt.t

val ( >|= ) : 'a Lwt.t -> ('a -> 'b) -> 'b Lwt.t

val ( >>? ) :
  ('a, 'trace) result -> ('a -> ('b, 'trace) result) -> ('b, 'trace) result

val ( >|? ) : ('a, 'trace) result -> ('a -> 'b) -> ('b, 'trace) result

val ( >>=? ) :
  ('a, 'trace) result Lwt.t ->
  ('a -> ('b, 'trace) result Lwt.t) ->
  ('b, 'trace) result Lwt.t

val ( >|=? ) :
  ('a, 'trace) result Lwt.t -> ('a -> 'b) -> ('b, 'trace) result Lwt.t

val ( >>?= ) :
  ('a, 'trace) result ->
  ('a -> ('b, 'trace) result Lwt.t) ->
  ('b, 'trace) result Lwt.t

val ( >|?= ) :
  ('a, 'trace) result -> ('a -> 'b Lwt.t) -> ('b, 'trace) result Lwt.t

val record_trace : 'err -> ('a, 'err trace) result -> ('a, 'err trace) result

val trace :
  'err -> ('b, 'err trace) result Lwt.t -> ('b, 'err trace) result Lwt.t

val record_trace_eval :
  (unit -> ('err, 'err trace) result) ->
  ('a, 'err trace) result ->
  ('a, 'err trace) result

val trace_eval :
  (unit -> ('err, 'err trace) result Lwt.t) ->
  ('b, 'err trace) result Lwt.t ->
  ('b, 'err trace) result Lwt.t

val error_unless : bool -> 'err -> (unit, 'err trace) result

val error_when : bool -> 'err -> (unit, 'err trace) result

val fail_unless : bool -> 'err -> (unit, 'err trace) result Lwt.t

val fail_when : bool -> 'err -> (unit, 'err trace) result Lwt.t

val unless :
  bool -> (unit -> (unit, 'trace) result Lwt.t) -> (unit, 'trace) result Lwt.t

val when_ :
  bool -> (unit -> (unit, 'trace) result Lwt.t) -> (unit, 'trace) result Lwt.t

val dont_wait :
  (exn -> unit) ->
  ('trace -> unit) ->
  (unit -> (unit, 'trace) result Lwt.t) ->
  unit

(* LIST TRAVERSORS *)

val iter : ('a -> (unit, 'trace) result) -> 'a list -> (unit, 'trace) result

val iter_s :
  ('a -> (unit, 'trace) result Lwt.t) -> 'a list -> (unit, 'trace) result Lwt.t

val map : ('a -> ('b, 'trace) result) -> 'a list -> ('b list, 'trace) result

val mapi :
  (int -> 'a -> ('b, 'trace) result) -> 'a list -> ('b list, 'trace) result

val map_s :
  ('a -> ('b, 'trace) result Lwt.t) ->
  'a list ->
  ('b list, 'trace) result Lwt.t

val rev_map_s :
  ('a -> ('b, 'trace) result Lwt.t) ->
  'a list ->
  ('b list, 'trace) result Lwt.t

val mapi_s :
  (int -> 'a -> ('b, 'trace) result Lwt.t) ->
  'a list ->
  ('b list, 'trace) result Lwt.t

val map2 :
  ('a -> 'b -> ('c, 'trace) result) ->
  'a list ->
  'b list ->
  ('c list, 'trace) result

val mapi2 :
  (int -> 'a -> 'b -> ('c, 'trace) result) ->
  'a list ->
  'b list ->
  ('c list, 'trace) result

val map2_s :
  ('a -> 'b -> ('c, 'trace) result Lwt.t) ->
  'a list ->
  'b list ->
  ('c list, 'trace) result Lwt.t

val mapi2_s :
  (int -> 'a -> 'b -> ('c, 'trace) result Lwt.t) ->
  'a list ->
  'b list ->
  ('c list, 'trace) result Lwt.t

val filter_map_s :
  ('a -> ('b option, 'trace) result Lwt.t) ->
  'a list ->
  ('b list, 'trace) result Lwt.t

val filter :
  ('a -> (bool, 'trace) result) -> 'a list -> ('a list, 'trace) result

val filter_s :
  ('a -> (bool, 'trace) result Lwt.t) ->
  'a list ->
  ('a list, 'trace) result Lwt.t

val fold_left_s :
  ('a -> 'b -> ('a, 'trace) result Lwt.t) ->
  'a ->
  'b list ->
  ('a, 'trace) result Lwt.t

val fold_right_s :
  ('a -> 'b -> ('b, 'trace) result Lwt.t) ->
  'a list ->
  'b ->
  ('b, 'trace) result Lwt.t

(* Synchronisation *)

val join_e : (unit, 'err trace) result list -> (unit, 'err trace) result

val all_e : ('a, 'err trace) result list -> ('a list, 'err trace) result

val both_e :
  ('a, 'err trace) result ->
  ('b, 'err trace) result ->
  ('a * 'b, 'err trace) result

(**/**)

(* boilerplate for interaction with the shell *)

type shell_error

type 'a shell_tzresult = ('a, shell_error list) result
