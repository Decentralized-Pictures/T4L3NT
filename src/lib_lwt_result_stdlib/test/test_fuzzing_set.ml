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

open Test_fuzzing_tests

module IntSet : Lwtreslib.Set.S with type elt = int = struct
  include Lwtreslib.Set.Make (Int)
end

module SetWithBase = struct
  let name = "Set"

  type 'a elt = IntSet.elt

  type _alias_elt = IntSet.elt

  type 'a t = IntSet.t

  type _alias_t = IntSet.t

  module IntSet :
    Lwtreslib.Set.S with type elt := _alias_elt and type t := _alias_t = struct
    include IntSet
  end

  include IntSet

  let of_list : int list -> _alias_t = of_list

  let to_list : _alias_t -> int list = elements
end

module Iterp = TestIterMonotoneAgainstStdlibList (SetWithBase)
module Fold = TestFoldMonotonicAgainstStdlibList (SetWithBase)
