(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Nomadic Labs <contact@nomadic-labs.com>                *)
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

let find_slot_headers ctxt level = Storage.Dal.Slot.Headers.find ctxt level

let finalize_current_slot_headers ctxt =
  let current_level = Raw_context.current_level ctxt in
  let slot_headers = Raw_context.Dal.candidates ctxt in
  match slot_headers with
  | [] -> Lwt.return ctxt
  | _ :: _ -> Storage.Dal.Slot.Headers.add ctxt current_level.level slot_headers

let compute_available_slot_headers ctxt seen_slot_headers =
  let open Dal_slot_repr in
  let fold_available_slots (rev_slot_headers, available_slot_headers) slot =
    if Raw_context.Dal.is_slot_index_available ctxt slot.Header.id.index then
      ( slot :: rev_slot_headers,
        Dal_endorsement_repr.commit available_slot_headers slot.Header.id.index
      )
    else (rev_slot_headers, available_slot_headers)
  in
  List.fold_left
    fold_available_slots
    ([], Dal_endorsement_repr.empty)
    seen_slot_headers

let get_slot_headers_history ctxt =
  Storage.Dal.Slot.History.find ctxt >|=? function
  | None -> Dal_slot_repr.History.genesis
  | Some slots_history -> slots_history

let update_skip_list ctxt ~confirmed_slot_headers =
  get_slot_headers_history ctxt >>=? fun slots_history ->
  Lwt.return
  @@ Dal_slot_repr.History.add_confirmed_slot_headers_no_cache
       slots_history
       confirmed_slot_headers
  >>=? fun slots_history ->
  Storage.Dal.Slot.History.add ctxt slots_history >|= ok

let finalize_pending_slot_headers ctxt =
  let {Level_repr.level = raw_level; _} = Raw_context.current_level ctxt in
  let Constants_parametric_repr.{dal; _} = Raw_context.constants ctxt in
  match Raw_level_repr.(sub raw_level dal.endorsement_lag) with
  | None -> return (ctxt, Dal_endorsement_repr.empty)
  | Some level_endorsed -> (
      Storage.Dal.Slot.Headers.find ctxt level_endorsed >>=? function
      | None -> return (ctxt, Dal_endorsement_repr.empty)
      | Some seen_slots ->
          let rev_confirmed_slot_headers, available_slot_headers =
            compute_available_slot_headers ctxt seen_slots
          in
          let confirmed_slot_headers = List.rev rev_confirmed_slot_headers in
          update_skip_list ctxt ~confirmed_slot_headers >>=? fun ctxt ->
          Storage.Dal.Slot.Headers.remove ctxt level_endorsed >>= fun ctxt ->
          return (ctxt, available_slot_headers))
