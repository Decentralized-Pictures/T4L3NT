(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2022 Trili Tech <contact@trili.tech>                        *)
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

type error +=
  | Dal_feature_disabled
  | Dal_slot_index_above_hard_limit
  | Dal_attestation_unexpected_size of {expected : int; got : int}
  | Dal_publish_slot_header_future_level of {
      provided : Raw_level_repr.t;
      expected : Raw_level_repr.t;
    }
  | Dal_publish_slot_header_past_level of {
      provided : Raw_level_repr.t;
      expected : Raw_level_repr.t;
    }
  | Dal_publish_slot_header_invalid_index of {
      given : Dal_slot_repr.Index.t;
      maximum : Dal_slot_repr.Index.t;
    }
  | Dal_publish_slot_header_candidate_with_low_fees of {
      proposed_fees : Tez_repr.t;
    }
  | Dal_attestation_size_limit_exceeded of {maximum_size : int; got : int}
  | Dal_publish_slot_header_duplicate of {slot_header : Dal_slot_repr.Header.t}
  | Dal_publish_slot_header_invalid_proof of {
      slot_header : Dal_slot_repr.Header.operation;
    }
  | Dal_data_availibility_attestor_not_in_committee of {
      attestor : Signature.Public_key_hash.t;
      level : Level_repr.t;
    }
  | Dal_operation_for_old_level of {
      current : Raw_level_repr.t;
      given : Raw_level_repr.t;
    }
  | Dal_operation_for_future_level of {
      current : Raw_level_repr.t;
      given : Raw_level_repr.t;
    }

let () =
  let open Data_encoding in
  let description =
    "Data-availability layer will be enabled in a future proposal."
  in
  register_error_kind
    `Permanent
    ~id:"operation.dal_disabled"
    ~title:"DAL is disabled"
    ~description
    ~pp:(fun ppf () -> Format.fprintf ppf "%s" description)
    Data_encoding.unit
    (function Dal_feature_disabled -> Some () | _ -> None)
    (fun () -> Dal_feature_disabled) ;

  let description =
    "The attestation for data availability has a different size"
  in
  register_error_kind
    `Permanent
    ~id:"dal_attestation_unexpected_size"
    ~title:"DAL attestation unexpected size"
    ~description
    ~pp:(fun ppf (expected, got) ->
      Format.fprintf ppf "%s: Expected %d. Got %d." description expected got)
    (obj2 (req "expected_size" int31) (req "got" int31))
    (function
      | Dal_attestation_unexpected_size {expected; got} -> Some (expected, got)
      | _ -> None)
    (fun (expected, got) -> Dal_attestation_unexpected_size {expected; got}) ;
  let description = "Slot index above hard limit" in
  register_error_kind
    `Permanent
    ~id:"dal_slot_index_negative_orabove_hard_limit"
    ~title:"DAL slot index negative or above hard limit"
    ~description
    ~pp:(fun ppf () ->
      Format.fprintf
        ppf
        "%s: Maximum allowed %a."
        description
        Dal_slot_repr.Index.pp
        Dal_slot_repr.Index.max_value)
    Data_encoding.unit
    (function Dal_slot_index_above_hard_limit -> Some () | _ -> None)
    (fun () -> Dal_slot_index_above_hard_limit) ;
  let description = "Unexpected level in the future in slot header" in
  register_error_kind
    `Temporary
    ~id:"dal_publish_slot_header_future_level"
    ~title:"DAL slot header future level"
    ~description
    ~pp:(fun ppf (provided, expected) ->
      Format.fprintf
        ppf
        "%s: Provided %a. Expected %a."
        description
        Raw_level_repr.pp
        provided
        Raw_level_repr.pp
        expected)
    (obj2
       (req "provided" Raw_level_repr.encoding)
       (req "got" Raw_level_repr.encoding))
    (function
      | Dal_publish_slot_header_future_level {provided; expected} ->
          Some (provided, expected)
      | _ -> None)
    (fun (provided, expected) ->
      Dal_publish_slot_header_future_level {provided; expected}) ;
  let description = "Unexpected level in the past in slot header" in
  register_error_kind
    `Branch
    ~id:"dal_publish_slot_header_past_level"
    ~title:"DAL slot header past level"
    ~description
    ~pp:(fun ppf (provided, expected) ->
      Format.fprintf
        ppf
        "%s: Provided %a. Expected %a."
        description
        Raw_level_repr.pp
        provided
        Raw_level_repr.pp
        expected)
    (obj2
       (req "provided" Raw_level_repr.encoding)
       (req "got" Raw_level_repr.encoding))
    (function
      | Dal_publish_slot_header_past_level {provided; expected} ->
          Some (provided, expected)
      | _ -> None)
    (fun (provided, expected) ->
      Dal_publish_slot_header_past_level {provided; expected}) ;
  let description = "Bad index for slot header" in
  register_error_kind
    `Permanent
    ~id:"dal_publish_slot_header_invalid_index"
    ~title:"DAL slot header invalid index"
    ~description
    ~pp:(fun ppf (given, maximum) ->
      Format.fprintf
        ppf
        "%s: Given %a. Maximum %a."
        description
        Dal_slot_repr.Index.pp
        given
        Dal_slot_repr.Index.pp
        maximum)
    (obj2
       (req "given" Dal_slot_repr.Index.encoding)
       (req "got" Dal_slot_repr.Index.encoding))
    (function
      | Dal_publish_slot_header_invalid_index {given; maximum} ->
          Some (given, maximum)
      | _ -> None)
    (fun (given, maximum) ->
      Dal_publish_slot_header_invalid_index {given; maximum}) ;
  (* DAL/FIXME https://gitlab.com/tezos/tezos/-/issues/3114
     Better error message *)
  let description = "Slot header with too low fees" in
  register_error_kind
    `Permanent
    ~id:"dal_publish_slot_header_with_low_fees"
    ~title:"DAL slot header with low fees"
    ~description
    ~pp:(fun ppf proposed ->
      Format.fprintf
        ppf
        "%s: Proposed fees %a."
        description
        Tez_repr.pp
        proposed)
    (obj1 (req "proposed" Tez_repr.encoding))
    (function
      | Dal_publish_slot_header_candidate_with_low_fees {proposed_fees} ->
          Some proposed_fees
      | _ -> None)
    (fun proposed_fees ->
      Dal_publish_slot_header_candidate_with_low_fees {proposed_fees}) ;
  let description = "The attestation for data availability is a too big" in
  register_error_kind
    `Permanent
    ~id:"dal_attestation_size_limit_exceeded"
    ~title:"DAL attestation exceeded the limit"
    ~description
    ~pp:(fun ppf (maximum_size, got) ->
      Format.fprintf
        ppf
        "%s: Maximum is %d. Got %d."
        description
        maximum_size
        got)
    (obj2 (req "maximum_size" int31) (req "got" int31))
    (function
      | Dal_attestation_size_limit_exceeded {maximum_size; got} ->
          Some (maximum_size, got)
      | _ -> None)
    (fun (maximum_size, got) ->
      Dal_attestation_size_limit_exceeded {maximum_size; got}) ;
  (* DAL/FIXME https://gitlab.com/tezos/tezos/-/issues/3114
     Better error message. *)
  let description = "A slot header for this slot was already proposed" in
  register_error_kind
    `Permanent
    ~id:"dal_publish_slot_heade_duplicate"
    ~title:"DAL publish slot header duplicate"
    ~description
    ~pp:(fun ppf _proposed -> Format.fprintf ppf "%s" description)
    (obj1 (req "proposed" Dal_slot_repr.Header.encoding))
    (function
      | Dal_publish_slot_header_duplicate {slot_header} -> Some slot_header
      | _ -> None)
    (fun slot_header -> Dal_publish_slot_header_duplicate {slot_header}) ;
  let description = "The slot header's commitment proof does not check" in
  register_error_kind
    `Permanent
    ~id:"dal_publish_slot_header_invalid_proof"
    ~title:"DAL publish slot header invalid proof"
    ~description
    ~pp:(fun ppf _proposed -> Format.fprintf ppf "%s" description)
    Dal_slot_repr.Header.operation_encoding
    (function
      | Dal_publish_slot_header_invalid_proof {slot_header} -> Some slot_header
      | _ -> None)
    (fun slot_header -> Dal_publish_slot_header_invalid_proof {slot_header}) ;
  register_error_kind
    `Outdated
    ~id:"Dal_operation_for_old_level"
    ~title:"Dal operation for an old level"
    ~description:"The Dal operation targets an old level"
    ~pp:(fun ppf (current_lvl, given_lvl) ->
      Format.fprintf
        ppf
        "Dal operation targets an old level %a. Current level is %a."
        Raw_level_repr.pp
        given_lvl
        Raw_level_repr.pp
        current_lvl)
    Data_encoding.(
      obj2
        (req "current_level" Raw_level_repr.encoding)
        (req "given_level" Raw_level_repr.encoding))
    (function
      | Dal_operation_for_old_level {current; given} -> Some (current, given)
      | _ -> None)
    (fun (current, given) -> Dal_operation_for_old_level {current; given}) ;
  register_error_kind
    `Temporary
    ~id:"Dal_operation_for_future_level"
    ~title:"Dal operation for a future level"
    ~description:"The Dal operation target a future level"
    ~pp:(fun ppf (current_lvl, given_lvl) ->
      Format.fprintf
        ppf
        "Dal operation targets a future level %a. Current level is %a."
        Raw_level_repr.pp
        given_lvl
        Raw_level_repr.pp
        current_lvl)
    Data_encoding.(
      obj2
        (req "current_level" Raw_level_repr.encoding)
        (req "given_level" Raw_level_repr.encoding))
    (function
      | Dal_operation_for_future_level {current; given} -> Some (current, given)
      | _ -> None)
    (fun (current, given) -> Dal_operation_for_future_level {current; given}) ;
  register_error_kind
    `Permanent
    ~id:"Dal_data_availibility_attestor_not_in_committee"
    ~title:"The attestor is not part of the DAL committee for this level"
    ~description:"The attestor is not part of the DAL committee for this level"
    ~pp:(fun ppf (attestor, level) ->
      Format.fprintf
        ppf
        "The attestor %a is not part of the DAL committee for the level %a"
        Signature.Public_key_hash.pp
        attestor
        Level_repr.pp
        level)
    Data_encoding.(
      obj2
        (req "attestor" Signature.Public_key_hash.encoding)
        (req "level" Level_repr.encoding))
    (function
      | Dal_data_availibility_attestor_not_in_committee {attestor; level} ->
          Some (attestor, level)
      | _ -> None)
    (fun (attestor, level) ->
      Dal_data_availibility_attestor_not_in_committee {attestor; level})
