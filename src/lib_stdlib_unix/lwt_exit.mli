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

(** {1 [Lwt_exit]}

    [Lwt_exit] provides helpers to handle:

    - OS signals,
    - cleaning-up before exiting, and
    - exiting.

    Specifically, this module allows users to (1) register clean-up callbacks
    and (2) trigger a soft exit. When a soft exit is triggered, the clean-up
    callbacks are called. The process exits once all the clean-up callbacks
    calls have resolved. *)

(** {2 State} *)

(** A global promise that resolves when clean-up starts. Note that there is no
    way to "just" start clean-up. Specifically, it is only possible to start the
    clean-up as a side-effect of triggering an exit.

    It is safe to use [clean_up_starts], even in the "main" promise. See example
    below in {!Misc recommendations}-{!Cleanly interrupting a main loop}. It is
    safe because [Lwt_exit] always witnesses the resolution of this promise
    before users of the library.
*)
val clean_up_starts : int Lwt.t

(** A global promise that resolves when clean-up ends. *)
val clean_up_ends : int Lwt.t

(** {2 Clean-up callbacks} *)

(** Attaching and detaching callbacks. *)

type clean_up_callback_id

(** [register_clean_up_callback f] registers [f] to be called as part of the
    clean-up. Typically this is used to flush outputs, rollback/commit pending
    changes, gracefully close connections with peers, etc.

    The call to [f] receives an argument [n] that indicates the status the
    process will exit with at the end of clean-up: [0] is for success, [127] for
    interruption by signals, [126] for uncaught exceptions, other values are
    available for the application's own exit codes.

    The argument [after], if passed, delays the call to this clean-up callback
    until the clean-up callbacks identified by [after] have resolved. Apart
    from this synchronization mechanism, all clean-up callbacks execute eagerly
    and concurrently. Note that more complex synchronization is discouraged but
    possible via standard Lwt techniques.

    Note that if one of the callbacks identified in [after] is unregistered
    (through {!unregister_clean_up_callback}) then it is simply ignored for the
    purpose of synchronization. Thus, it is important to indicate all the
    "dependencies" of a clean-up callback and not rely on transitive
    "dependencies".

    Once clean-up has started, this function has no effect.

    The promise returned by this callback may be canceled if it takes too long
    to complete. (See {!max_clean_up_time} below.) *)
val register_clean_up_callback :
  ?after:clean_up_callback_id list ->
  loc:string ->
  (int -> unit Lwt.t) ->
  clean_up_callback_id

(** [unregister_clean_up_callback cid] removes the callback with id [cid] from
    the set of functions to call for cleaning up.

    Once clean-up has started, this function has no effect. *)
val unregister_clean_up_callback : clean_up_callback_id -> unit

(** Example use:

   [let p = open_resource r in
    let clean_p = register_clean_up_callback (fun _ -> close_resource p) in
    let rec feed () =
       read () >>= fun v ->
       push_to_resource p >>= fun () ->
       feed ()
    in
    feed () >>= fun () ->
    close_resource p >>= fun () ->
    unregister_clean_up_callback clean_p;
    Lwt.return ()]
*)

(** {2 Exiting} *)

(** [exit_and_raise n] triggers a soft exit (including clean-up) and raises
    {!Stdlib.Exit}. This is intended for use deep inside the program, at a place
    that wants to trigger an exit after observing, say, a fatal error. *)
val exit_and_raise : int -> 'a

(** [exit_and_wait n] triggers a soft exit (including clean-up) and stays
    pending until it is finished. This is intended to be used directly within
    {!Lwt_main.run} for a clean exit. *)
val exit_and_wait : int -> int Lwt.t

(** {2 Signal management} *)

(** A soft signal handler is one that triggers clean-up.

    After the clean-up has started, and after a safety period has elapsed,
    sending the same soft-handled signal a second time terminates the
    process immediately. The safety period is set by the parameter
    [double_signal_safety] of the {!wrap_and_exit}, {!wrap_and_error}, and
    {!wrap_and_forward} functions (below).

    A hard signal handler is one that terminates the process immediately.

    IMPORTANT: a hard exit can leave open files in inconsistent states. *)

type signal_setup

(** [make_signal_setup ~soft ~hard] is a signal setup with [soft] as soft
    signals and [hard] as hard signals.

    @raise {!Stdlib.Invalid_argument} if a signal is not one declared in {!Sys}
    (see all [Sys.sig*] values). *)
val make_signal_setup : soft:int list -> hard:int list -> signal_setup

(** [default_signal_setup] is
    [make_signal_setup ~soft:[Sys.sigint; Sys.sigterm] ~hard:[]].

    Note that pressing Ctrl-C sends [SIGINT] to the process whilst shutting it
    down through systemd sends [SIGTERM]. This is the reasoning behind the
    default: both of those signals should be handled softly in most cases. *)
val default_signal_setup : signal_setup

(** [signal_name signal] is the name of [signal].
    E.g., [signal_name Sys.sigterm] is ["TERM"]. *)
val signal_name : int -> string

(** {2 Main promise wrappers} *)

(** [wrap_and_exit p] is a promise [q] that behaves as follows:

    NORMAL OPERATION:

    If [p] is fulfilled with value [v] (and [exit_and_raise] was not called)
    then
    - [q] also is fulfilled with [v]. The process does not exit.

    If [exit_and_raise code] is called before [p] is resolved, then
    - the clean-up starts,
    - [p] is canceled,
    - the process terminates as soon as clean-up ends with exit code [code].

    If [p] is rejected (and [exit_and_raise] was not called), it is equivalent
    to calling [exit_and_raise 126]. I.e.,
    - the clean-up starts,
    - the process terminates as soon as clean-up ends with exit code [126].

    EXIT CODE:

    The exit code of the process is masked with [lor 128] (i.e., setting the 8th
    bit) if the clean-up did not complete successfully (i.e., if any of the
    clean-up callbacks were rejected).

    E.g., if you call [exit_and_raise 1] and one of the clean-up callback fails
    (is rejected with an exception), then the exit code is [1 lor 128 = 129].

    Note that even if one clean-up callback fails, the other clean-up callbacks
    are left to execute.

    SIGNALS:

    In addition, [wrap_and_exit p] sets up the signal handlers described above
    (see {!signal_setup}).

    Any hard-signal that is received triggers an immediate process termination
    with exit code [127 lor 128 = 255].

    Any soft-signal that is received triggers a call to [exit_and_raise 127]
    (the consequences of which are described above).

    Note that if the same soft-signal is sent a second-time, the process
    terminates immediately with code [127 lor 128 = 255].

    To summarize, the exit code can be thought of as a 8-bit integer with the
    following properties:
    - the highest bit is set if the clean-up was unsuccessful/incomplete
    - the second highest bit is set if the process exited because of a signal
    - the third highest bit is set if the process exited because of an uncaught
      exception
    - all other bits can be used by the application as wanted.

    Note that if the second (signal) or third (exception) highest bits are set,
    then only the highest (incomplete clean-up) may also be set.

    EXCEPTIONS:

    @raise {!Invalid_argument} if called after clean-up has already started. See
    {!Misc recommendations}({!One-shot}) below for details about the
    consequences of this.

    OPTIONAL PARAMETERS:

    The optional argument [max_clean_up_time] limits the time the clean-up phase
    is allowed to run for. If any of the clean-up callbacks is still pending
    when [max_clean_up_time] has elapsed, the process exits immediately. If the
    clean-up is interrupted by this then the exit code is masked with [128] as
    described above.

    By default [max_clean_up_time] is not set and no limits is set for the
    completion of the clean-up callbacks.

    The optional argument [double_signal_safety] (defaults to one (1) second)
    is the grace period after sending one of the softly-handled signal before
    sending the same signal is handled as hard.

    This is meant to protect against double-pressing Ctrl-C in an interactive
    terminal session. If you press Ctrl-c once, a soft exit is triggered, if you
    press it again (accidentally) within the grace period it is ignored, if you
    press it again after the grace period has elapsed it is treated as a hard
    exit.

    The optional argument [signal_setup] (defaults to [default_signal_setup])
    sets up soft and hard handlers at the beginning and clears them when [q]
    resolves.

    EXAMPLE:

    Intended use:
    [Stdlib.exit @@ Lwt_main.run begin
      Lwt_exit.wrap_and_exit (init ()) >>= fun v ->
      let ccbid_v = register_clean_up_callback ~loc:__LOC__ (fun _ -> clean v) in
      Lwt_exit.wrap_and_exit (main v) >>= fun r ->
      let () = unregister_clean_up_callback ccbid_v in
      let ccbid_r = register_clean_up_callback ~loc:__LOC__ (fun _ -> free r) in
      Lwt_exit.wrap_and_exit (shutdown v) >>= fun () ->
      exit_and_wait 0 (* clean exit afterwards *)
    end]
*)
val wrap_and_exit :
  ?signal_setup:signal_setup ->
  ?double_signal_safety:Ptime.Span.t ->
  ?max_clean_up_time:Ptime.Span.t ->
  'a Lwt.t ->
  'a Lwt.t

(** [wrap_and_error p] is similar to {!wrap_and_exit} [p] but it resolves to
    [Error status] instead of exiting with [status]. When it resolves with
    [Error _] (i.e., if a soft-exit has been triggered), clean-up has already
    ended.

    Intended use:
    [Stdlib.exit @@ Lwt_main.run begin
      Lwt_exit.wrap_and_error (init ()) >>= function
      | Error exit_status ->
        Format.eprintf "Initialisation failed\n%!";
        Lwt.return exit_status
      | Ok v ->
        Lwt_exit.wrap_and_error (main v) >>= function
        | Error exit_status ->
          Format.eprintf "Processing failed\n%!";
          Lwt.return exit_status
        | Ok v ->
          Lwt_exit.wrap_and_error (shutdown ()) >>= function
          | Error exit_status ->
            Format.eprintf "Shutdown failed\n%!";
            Lwt.return exit_status
          | Ok () ->
            exit_and_wait 0 >>= fun _ ->
            Lwt.return 0
    end]
*)
val wrap_and_error :
  ?signal_setup:signal_setup ->
  ?double_signal_safety:Ptime.Span.t ->
  ?max_clean_up_time:Ptime.Span.t ->
  'a Lwt.t ->
  ('a, int) result Lwt.t

(** [wrap_and_forward p] is similar to {!wrap_and_error} [p] except that it
    collapses [Ok _] and [Error _].

    Note that, in general, you can expect the status [0] to come from a
    successfully resolved [p]. However, It could also be because of a soft-exit
    with status [0]. As a result, you cannot be certain, based on the status
    alone, whether clean-up callbacks have been called.

    Intended use:
    [Stdlib.exit @@ Lwt_main.run begin
      Lwt_exit.wrap_and_forward (main ()) >>= function
      | 0 ->
        Format.printf "I'm done, bye!\n%!";
        Lwt.return 0
      | 1 -> (* signaling *)
        Format.printf "Shutdown complete\n";
        Lwt.return 1
      | 2 -> (* uncaught exception *)
        Format.printf "An error occurred.\n";
        Format.printf "Please check %s\n" log_file;
        Format.printf "And consider reporting the issue\n%!";
        Lwt.return 2
      | _ -> assert false
    end]
*)
val wrap_and_forward :
  ?signal_setup:signal_setup ->
  ?double_signal_safety:Ptime.Span.t ->
  ?max_clean_up_time:Ptime.Span.t ->
  int Lwt.t ->
  int Lwt.t

(** {2 Misc recommendations}

  {3 One-shot}

  [Lwt_exit] is one-shot: once the clean-up has started, further uses of
  [wrap_and_*] will raise {!Invalid_argument}.

  Note, for example, how in the {!wrap_and_error} example, [wrap_and_error] is
  called multiple time, but on [Ok] branches where clean-up has {e not}
  happened. This is ok.

  On the other hand, using [wrap_and_error] in an [Error] branch would be
  unsound because clean-up has happened in these branches.

  {3 Registering callbacks}

  To the extent that it is possible, you should register your clean-up callbacks
  as soon as a resource that needs clean-up is allocated.

  [let r = <resource initialization> in
   let c = register_clean_up_callback ~loc:__LOC__ (fun s -> <clean-up code>) in
   <resource use>;
   let () = unregister_clean_up_callback c in
   <normal clean-up code>;
   <continue>
  ]

  When possible, you can even register the callback before-hand.

  [let rr = ref None in
   let c = register_clean_up_callback
             ~loc:__LOC__
             (fun s -> Option.iter (fun r -> <clean-up code>) !rr)
   in
   let rr := Some <resource initialization> in
   <resource use>;
   let () = unregister_clean_up_callback c in
   rr := None;
   <normal clean-up code>;
   <continue>
  ]

  {3 Registering, unregistering, and loops}

  In a tight-loop, in the event loop of an actor, etc. avoid registering and
  unregistering clean-up callbacks repeatedly. Instead, you should create an
  intermediate layer dedicated to clean-up. E.g.,

  [let module Resources = Set.Make(<resource OrderedType module>) in
   let rs = ref Resources.empty in
   let c = register_clean_up_callback
             ~loc:__LOC__
             (fun s -> Resources.iter
                         (fun r -> <resource clean-up>; Lwt.return ())
                         !rs)
   in
   let rec loop () =
      receive () >>= function
      | End -> Lwt.return ()
      | Input input ->
         let _process =
            let r = <resource initialization> in
            rs := Resources.add r !rs;
            <resource use (use input)> >>= fun () ->
            rs := Resources.remove r !rs;
            <normal clean-up>;
            Lwt.return ()
         in
         loop ()
   in
   loop ()
  ]

  Note that this is a general example and your specific use would differ.

  More importantly, note that in this specific case we do not unregister the
  clean-up callback because there is no point at which we know that the resource
  set is empty. It's ok because the clean-up will be a very fast no-op. Coming
  up with a solution that allows unregistering of the clean-up callback is left
  as an exercise to the reader.

  {3 Cleanly interrupting a main loop}

  In a program that does not normally exit, you might want to interrupt the main
  loop (to avoid further processing) as soon as clean-up has started (either
  because a signal was received or because a fatal exception deep within the
  program was handled by calling {!exit_and_raise}).

  This is easily achieved by passing the main-loop to [wrap_and_*]. As
  mentioned in the documentation of {!wrap_and_exit}, the promise passed as
  argument is cancelled as soon as the clean-up starts.

  However, there may be other loops that are not syntactically available to the
  main wrapper. In this case, the simple pattern below is safe and the loop,
  provided it is cancelable, will stop when the clean-up starts.

  [let rec loop () =
     get_task () >>= fun task ->
     process task >>= fun () ->
     loop ()
   in
   Lwt.pick [loop (); Lwt_exit.clean_up_starts]]

  Arguably, for such a simple case, you can replace the pattern above by a
  simple clean-up callback that cancels the loop. However, for more complex
  arrangements, the [pick]-with-[clean_up_starts] pattern above can be useful.

*)
