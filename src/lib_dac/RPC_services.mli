(** POST dac/store_preimage to post a payload using a given [pagination_scheme].
  It returns the base58 encoded root page hash 
  and the raw bytes. *)
val post_store_preimage :
  ( [`POST],
    unit,
    unit,
    unit,
    Bytes.t * Pagination_scheme.t,
    Dac_plugin.raw_hash * Bytes.t )
  Tezos_rpc.Service.service

(** GET dac/verify_signature endpoint requests the DAL node to verify
  the signature of the external message [external_message]. The DAC committee
  of the DAL node must be the same that was used to produce the
  [external_message]. *)
val get_verify_signature :
  ([`GET], unit, unit, string option, unit, bool) Tezos_rpc.Service.service

(** GET dac/preimage requests the preimage of hash, consisting of a
    single page, from cctxt. When the request succeeds, the raw page will be
    returned as a sequence of bytes. *)
val get_preimage :
  ( [`GET],
    unit,
    unit * Dac_plugin.raw_hash,
    unit,
    unit,
    Bytes.t )
  Tezos_rpc.Service.service

(** PUT dac/member_signature endpoint stores the [signature] 
  generated from signing [hex_root_hash] by [dac_member_pkh]. *)
val put_dac_member_signature :
  ([`PUT], unit, unit, unit, Signature_repr.t, unit) Tezos_rpc.Service.service

(** GET dac/certificate endpoint returns the DAC certificate for the
  provided [root_page_hash]. *)
val get_certificate :
  ( [`GET],
    unit,
    unit * Dac_plugin.raw_hash,
    unit,
    unit,
    Certificate_repr.t option )
  Tezos_rpc.Service.service

(**  GET dac/missing_page/[page_hash] Observer fetches the missing page 
  from a Coordinator node. The missing page is then saved to a 
  page store before returning the page as a response. *)
val get_missing_page :
  ( [`GET],
    unit,
    unit * Dac_plugin.raw_hash,
    unit,
    unit,
    Bytes.t )
  Tezos_rpc.Service.service

module Coordinator : sig
  (** POST dac/preimage sends a [payload] to the DAC
    [Coordinator]. It returns a hex encoded root page hash, 
    produced by [Merkle_tree_V0] pagination scheme.
    On the backend side it also pushes root page hash of the preimage to all
    the subscribed DAC Members and Observers. *)
  val post_preimage :
    ( [`POST],
      unit,
      unit,
      unit,
      Bytes.t,
      Dac_plugin.raw_hash )
    Tezos_rpc.Service.service
end
