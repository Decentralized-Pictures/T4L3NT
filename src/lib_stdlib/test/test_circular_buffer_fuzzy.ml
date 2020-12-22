(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
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

(** Testing
    -------
    Component:    stdlib
    Invocation:   dune build @src/lib_stdlib/test/runtest_circular_buffer_fuzzy
    Subject:      Test the circular buffer with a reference implementation
 *)

(* This test implement a fuzzy testing where we check that the
   `circular_buffer` behaves similarly than a reference implementation
   of the same interface. *)

open Lwt.Infix

module type S = sig
  type t

  type data

  val create : ?maxlength:int -> ?fresh_buf_size:int -> unit -> t

  (* Write the output of [fill_using] in [data]. *)
  val write :
    maxlen:int ->
    fill_using:(Bytes.t -> int -> int -> int Lwt.t) ->
    t ->
    data Lwt.t

  (* Read the value of [data]. The read may be partial if the [data]
     is not fully read. We return the [data] part which was not
     read. *)
  val read : data -> ?len:int -> t -> into:Bytes.t -> offset:int -> data option

  val length : data -> int
end

module Reference : S = struct
  (* There is not buffer, hence the type [t] is not necessary. For
     each [data] we create a new buffer. *)
  type t = unit

  type data = Bytes.t

  let create ?maxlength:_ ?fresh_buf_size:_ () = ()

  let write ~maxlen ~fill_using () =
    let bytes = Bytes.create maxlen in
    fill_using bytes 0 maxlen
    >>= fun written_bytes -> Lwt.return (Bytes.sub bytes 0 written_bytes)

  let read data ?(len = Bytes.length data) () ~into ~offset =
    let data_length = Bytes.length data in
    if len > data_length then
      raise (Invalid_argument "Circular_buffer.read: len > (length data).") ;
    Bytes.blit data 0 into offset len ;
    if len = data_length then None
    else Some (Bytes.sub data len (data_length - len))

  let length = Bytes.length
end

(* Check that the circular buffer as the expected interface *)
module Circular_buffer : S = Circular_buffer

(* A scenario will be generate as a sequence of write/read such that
   at each moment, there is more writes than reads. Details are made
   precise in the [pp_op] function below. *)
type op = Write of int * int | Read of int

let pp_op fmt = function
  | Write (write_len, len) ->
      Format.fprintf
        fmt
        "Write %d bytes into a buffer of maxlen %d bytes."
        (min write_len len)
        len
  | Read read_len ->
      (* if [read_len] is too long, we may truncate to the correct size
        depending on the test (see below). *)
      Format.fprintf fmt "Read at most %d bytes." read_len

let pp = Format.pp_print_list ~pp_sep:Format.pp_print_newline pp_op

let write_op =
  let open Crowbar in
  map [uint8; uint8] (fun write_len len -> Write (write_len, len))

let op =
  let open Crowbar in
  map [bool; uint8; uint8] (fun b len write_len ->
      if b then Write (write_len, len) else Read len)

(* We bypass the [Crowbar.fix] operator to generate longer lists. We
   record the number of writes to ensure the invariant [nb_writes >
   nb_reads]. *)
let rec ops_gen (acc : (int * op list) Crowbar.gen) i =
  if i = 0 then acc
  else
    ops_gen
      (Crowbar.dynamic_bind acc (fun (nb_writes, ops) ->
           let gen = if nb_writes > 0 then op else write_op in
           Crowbar.map [gen] (fun op ->
               let delta = match op with Write _ -> 1 | Read _ -> -1 in
               (nb_writes + delta, op :: ops))))
      (i - 1)

(* Scenarios start with a write operation. *)
let ops_gen size =
  let gen = ops_gen (Crowbar.map [write_op] (fun v -> (1, [v]))) size in
  Crowbar.map [gen] (fun (_, ops) -> ops)

let values =
  let open Crowbar in
  (* 1000 is a good trade-off between:
     - testing long scenarii using a long sequence of operations
     - quick execution
   *)
  let size_gen = range ~min:0 1000 in
  dynamic_bind size_gen (fun size -> ops_gen size)

let values = Crowbar.with_printer pp values

(* To generate random bytes in a buffer. *)
let random_bytes =
  let state = Random.State.make_self_init () in
  fun size ->
    let buff = Bytes.create size in
    let rec fill_random size offset buff =
      let data = Random.State.int64 state Int64.max_int in
      if size < 8 then
        for i = 0 to size - 1 do
          Bytes.set_int8
            buff
            (offset + i)
            (Int64.to_int (Int64.shift_right data i))
        done
      else (
        Bytes.set_int64_ne buff offset data ;
        fill_random (size - 8) (offset + 8) buff )
    in
    fill_random size 0 buff ; buff

let pp_buf fmt buf =
  Format.fprintf fmt "Length: %d@." (Bytes.length buf) ;
  Bytes.iter (fun c -> Format.fprintf fmt "%02x" (Char.code c)) buf

type state =
  | E : {
      implementation : (module S with type t = 'a and type data = 'b);
      internal_state : 'a;
      data_to_be_read : 'b Queue.t;
      mutable partial_read : 'b option;
    }
      -> state

let () =
  (* The module Circular buffer should have the same semantics as the
     reference implementation given in the Reference module. We use
     crowbar to generate write and reads, then check that both
     implementations send the same result. *)
  let fill_using write_len fresh_bytes bytes offset maxlen =
    let len = min write_len maxlen in
    Bytes.blit fresh_bytes 0 bytes offset len ;
    Lwt.return len
  in
  let write_data write_len maxlen bytes_to_write (E state) =
    let (module M) = state.implementation in
    M.write
      ~maxlen
      ~fill_using:(fill_using write_len bytes_to_write)
      state.internal_state
    >>= fun data ->
    Queue.add data state.data_to_be_read ;
    Lwt.return_unit
  in
  let read_data ~without_invalid_argument read_len (E state) =
    let (module M) = state.implementation in
    let data_to_read =
      match state.partial_read with
      | None ->
          Queue.take state.data_to_be_read
      | Some p ->
          state.partial_read <- None ;
          p
    in
    let len =
      (* to avoid the invalid_argument we take the minimum between the
         size of the data to read and the one generated by the
         [Crowbar] generator. *)
      if without_invalid_argument then min (M.length data_to_read) read_len
      else read_len
    in
    let buf = Bytes.create len in
    try
      state.partial_read <-
        M.read data_to_read ~len state.internal_state ~into:buf ~offset:0 ;
      (false, buf)
    with Invalid_argument _ -> (true, Bytes.create 0)
  in
  let update_state ?(without_invalid_argument = false) left_state right_state
      value =
    match value with
    | Write (write_len, maxlen) ->
        let len = min write_len maxlen in
        let bytes_to_write = random_bytes len in
        write_data write_len maxlen bytes_to_write left_state
        >>= fun () ->
        write_data write_len maxlen bytes_to_write right_state
        >>= fun () -> Lwt.return_false
    | Read read_len -> (
      try
        let (left_has_raised, left_buf) =
          read_data ~without_invalid_argument read_len left_state
        in
        let (right_has_raised, right_buf) =
          read_data ~without_invalid_argument read_len right_state
        in
        if left_has_raised then
          if right_has_raised then Lwt.return true
          else Crowbar.fail "Different behaviors (invalid_argument)"
        else (
          Crowbar.check_eq ~pp:pp_buf left_buf right_buf ;
          Lwt.return false )
      with Queue.Empty -> Crowbar.guard false ; Lwt.return_false )
  in
  Crowbar.add_test
    ~name:
      "Stdlib.circular_bufer.equivalence-with-reference-implementation-without-invalid-argument"
    [values]
    (fun ops ->
      (* To ensure that the number of [write] is greater than the
         number of [read] we reverse the list. *)
      let ops = List.rev ops in
      let left_state =
        E
          {
            implementation = (module Circular_buffer);
            internal_state = Circular_buffer.create ~maxlength:(1 lsl 10) ();
            data_to_be_read = Queue.create ();
            partial_read = None;
          }
      in
      let right_state =
        E
          {
            implementation = (module Reference);
            internal_state = Reference.create ~maxlength:(1 lsl 10) ();
            data_to_be_read = Queue.create ();
            partial_read = None;
          }
      in
      Lwt_main.run
        (Lwt_list.iter_s
           (fun value ->
             update_state
               ~without_invalid_argument:true
               left_state
               right_state
               value
             >>= fun _ -> Lwt.return_unit)
           ops)) ;
  (* The test below do not try to avoid the `invalid_argument`
     exception. It checks that both implementations raise this
     exception at the same time. *)
  Crowbar.add_test
    ~name:"Stdlib.circular_bufer.equivalence-with-reference-implementation"
    [values]
    (fun ops ->
      let ops = List.rev ops in
      let left_state =
        E
          {
            implementation = (module Circular_buffer);
            internal_state = Circular_buffer.create ();
            data_to_be_read = Queue.create ();
            partial_read = None;
          }
      in
      let right_state =
        E
          {
            implementation = (module Reference);
            internal_state = Reference.create ();
            data_to_be_read = Queue.create ();
            partial_read = None;
          }
      in
      let _ =
        Lwt_main.run
          (Lwt_list.fold_left_s
             (fun raised value ->
               if raised then Lwt.return raised
               else
                 update_state left_state right_state value
                 >>= fun raised' -> Lwt.return (raised || raised'))
             false
             ops)
      in
      ())
