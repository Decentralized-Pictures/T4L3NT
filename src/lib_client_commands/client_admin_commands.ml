(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
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

let block_param ~name ~desc t =
  Clic.param
    ~name
    ~desc
    (Clic.parameter (fun _ str -> Lwt.return (Block_hash.of_b58check str)))
    t

let commands () =
  let open Clic in
  let group =
    {
      name = "admin";
      title = "Commands to perform privileged operations on the node";
    }
  in
  [ command
      ~group
      ~desc:"Make the node forget its decision of rejecting blocks."
      no_options
      ( prefixes ["unmark"; "invalid"]
      @@ seq_of_param
           (block_param
              ~name:"block"
              ~desc:"blocks to remove from invalid list") )
      (fun () blocks (cctxt : #Client_context.full) ->
        iter_s
          (fun block ->
            Shell_services.Invalid_blocks.delete cctxt block
            >>=? fun () ->
            cctxt#message
              "Block %a no longer marked invalid."
              Block_hash.pp
              block
            >>= fun () -> return_unit)
          blocks);
    command
      ~group
      ~desc:"Make the node forget every decision of rejecting blocks."
      no_options
      (prefixes ["unmark"; "all"; "invalid"; "blocks"] @@ stop)
      (fun () (cctxt : #Client_context.full) ->
        Shell_services.Invalid_blocks.list cctxt ()
        >>=? fun invalid_blocks ->
        iter_s
          (fun {Chain_services.hash; _} ->
            Shell_services.Invalid_blocks.delete cctxt hash
            >>=? fun () ->
            cctxt#message
              "Block %a no longer marked invalid."
              Block_hash.pp_short
              hash
            >>= fun () -> return_unit)
          invalid_blocks);
    command
      ~group
      ~desc:
        "Retrieve the current checkpoint and display it in a format \
         compatible with node argument `--checkpoint`."
      no_options
      (fixed ["show"; "current"; "checkpoint"])
      (fun () (cctxt : #Client_context.full) ->
        Shell_services.Chain.checkpoint cctxt ~chain:cctxt#chain ()
        >>=? fun (block_header, save_point, caboose, history_mode) ->
        cctxt#message
          "@[<v 0>Checkpoint: %s@,\
           Checkpoint level: %ld@,\
           History mode: %a@,\
           Save point level: %ld@,\
           Caboose level: %ld@]"
          (Block_header.to_b58check block_header)
          block_header.shell.level
          History_mode.pp
          history_mode
          save_point
          caboose
        >>= fun () -> return ()) ]
