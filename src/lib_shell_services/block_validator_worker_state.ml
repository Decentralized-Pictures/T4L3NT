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

module Request = struct
  type view = {
    chain_id : Chain_id.t;
    block : Block_hash.t;
    peer : P2p_peer.Id.t option;
  }

  let encoding =
    let open Data_encoding in
    conv
      (fun {chain_id; block; peer} -> (block, chain_id, peer))
      (fun (block, chain_id, peer) -> {chain_id; block; peer})
      (obj3
         (req "block" Block_hash.encoding)
         (req "chain_id" Chain_id.encoding)
         (opt "peer" P2p_peer.Id.encoding))

  let pp ppf {chain_id; block; peer} =
    Format.fprintf
      ppf
      "Validation of %a (chain: %a)"
      Block_hash.pp
      block
      Chain_id.pp_short
      chain_id ;
    match peer with
    | None ->
        ()
    | Some peer ->
        Format.fprintf ppf "from peer %a" P2p_peer.Id.pp_short peer
end

module Event = struct
  type t =
    | Validation_success of Request.view * Worker_types.request_status
    | Validation_failure of
        Request.view * Worker_types.request_status * error list
    | Could_not_find_context of Block_hash.t
    | Previously_validated of Block_hash.t
    | Validating_block of Block_hash.t

  type view = t

  let view t = t

  let level req =
    match req with
    | Validation_success _ | Validation_failure _ ->
        Internal_event.Notice
    | Could_not_find_context _ | Previously_validated _ | Validating_block _ ->
        Internal_event.Debug

  let encoding =
    let open Data_encoding in
    union
      [ case
          (Tag 0)
          ~title:"validation_success"
          (obj2
             (req "successful_validation" Request.encoding)
             (req "status" Worker_types.request_status_encoding))
          (function Validation_success (r, s) -> Some (r, s) | _ -> None)
          (fun (r, s) -> Validation_success (r, s));
        case
          (Tag 1)
          ~title:"validation_failure"
          (obj3
             (req "failed_validation" Request.encoding)
             (req "status" Worker_types.request_status_encoding)
             (dft "errors" RPC_error.encoding []))
          (function
            | Validation_failure (r, s, err) -> Some (r, s, err) | _ -> None)
          (fun (r, s, err) -> Validation_failure (r, s, err));
        case
          (Tag 2)
          ~title:"could_not_find_context"
          (obj1 (req "block" Block_hash.encoding))
          (function Could_not_find_context block -> Some block | _ -> None)
          (fun block -> Could_not_find_context block);
        case
          (Tag 3)
          ~title:"previously_validated"
          (obj1 (req "block" Block_hash.encoding))
          (function Previously_validated block -> Some block | _ -> None)
          (fun block -> Previously_validated block);
        case
          (Tag 4)
          ~title:"validating_block"
          (obj1 (req "block" Block_hash.encoding))
          (function Validating_block block -> Some block | _ -> None)
          (fun block -> Validating_block block) ]

  let pp ppf = function
    | Validation_success (req, {pushed; treated; completed}) ->
        Format.fprintf
          ppf
          "@[<v 0>block %a successfully validated@,%a@]"
          Block_hash.pp
          req.block
          Worker_types.pp_status
          {pushed; treated; completed}
    | Validation_failure (req, {pushed; treated; completed}, errs) ->
        Format.fprintf
          ppf
          "@[<v 0>validation of block %a failed@,%a, %a@]"
          Block_hash.pp
          req.block
          Worker_types.pp_status
          {pushed; treated; completed}
          (Format.pp_print_list Error_monad.pp)
          errs
    | Could_not_find_context block ->
        Format.fprintf
          ppf
          "could not find context for block %a"
          Block_hash.pp
          block
    | Previously_validated block ->
        Format.fprintf
          ppf
          "previously validated block %a (after pipe)"
          Block_hash.pp
          block
    | Validating_block block ->
        Format.fprintf ppf "validating block %a" Block_hash.pp block
end

module Worker_state = struct
  type view = unit

  let encoding = Data_encoding.empty

  let pp _ppf _view = ()
end
