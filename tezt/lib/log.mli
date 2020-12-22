(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2020 Nomadic Labs <contact@nomadic-labs.com>                *)
(* Copyright (c) 2020 Metastate AG <hello@metastate.dev>                     *)
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

(** Tezt logs. *)

(** Quote or escape a string using shell syntax. *)
val quote_shell : string -> string

(** Quote or escape a command with arguments using shell syntax. *)
val quote_shell_command : string -> string list -> string

(** {2 Colors} *)

module Color : sig
  type t

  (** Apply a color to a string, and then reset colors. *)
  val apply : t -> string -> string

  (** Combine two colors.

      Example: [Color.(bold ++ FG.red ++ BG.white)] *)
  val ( ++ ) : t -> t -> t

  val reset : t

  val bold : t

  (** Foreground colors. *)
  module FG : sig
    val black : t

    val red : t

    val green : t

    val yellow : t

    val blue : t

    val magenta : t

    val cyan : t

    val white : t
  end

  (** Background colors. *)
  module BG : sig
    val black : t

    val red : t

    val green : t

    val yellow : t

    val blue : t

    val magenta : t

    val cyan : t

    val white : t
  end
end

(** {2 Logging} *)

(** Log a message if the log level requested on the command-line allows it.

    See the documentation of [Cli] for a description of each log level
    and when to use them.

    In tests, you should mostly use function {!info}. *)
val log :
  level:Cli.log_level ->
  ?color:Color.t ->
  ?prefix:string ->
  ('a, unit, string, unit) format4 ->
  'a

(** Same as [log ~level:Debug]. *)
val debug :
  ?color:Color.t -> ?prefix:string -> ('a, unit, string, unit) format4 -> 'a

(** Same as [log ~level:Info]. *)
val info :
  ?color:Color.t -> ?prefix:string -> ('a, unit, string, unit) format4 -> 'a

(** Same as [log ~level:Report]. *)
val report :
  ?color:Color.t -> ?prefix:string -> ('a, unit, string, unit) format4 -> 'a

(** Same as [log ~level:Warn ~color:red ~prefix:"warn"]. *)
val warn : ('a, unit, string, unit) format4 -> 'a

(** Same as [log ~level:Error ~color:red ~prefix:"error"]. *)
val error : ('a, unit, string, unit) format4 -> 'a

type test_result = Successful | Failed | Aborted

(** Log the result of a test.

    [iteration] is the index of the iteration count to display in [--loop] mode.

    The [string] argument is the name of the test. *)
val test_result : iteration:int -> test_result -> string -> unit

(** Log a command which will be run.

    Log it with level [Debug], and print it unconditionally with no timestamp
    if [Cli.options.commands] is [true]. *)
val command : ?color:Color.t -> ?prefix:string -> string -> string list -> unit
