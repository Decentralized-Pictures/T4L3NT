(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018 Nomadic Labs, <contact@nomadic-labs.com>               *)
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

type Base58.data += Encrypted_ed25519 of Bytes.t

type Base58.data += Encrypted_secp256k1 of Bytes.t

type Base58.data += Encrypted_p256 of Bytes.t

open Client_keys

let scheme = "encrypted"

module Raw = struct
  (* https://tools.ietf.org/html/rfc2898#section-4.1 *)
  let salt_len = 8

  (* Fixed zero nonce *)
  let nonce = Crypto_box.zero_nonce

  (* Secret keys for Ed25519, secp256k1, P256 have the same size. *)
  let encrypted_size = Crypto_box.tag_length + Hacl.Ed25519.sk_size

  let pbkdf ~salt ~password =
    Pbkdf.SHA512.pbkdf2 ~count:32768 ~dk_len:32l ~salt ~password

  let encrypt ~password sk =
    let salt = Hacl.Rand.gen salt_len in
    let key = Crypto_box.Secretbox.unsafe_of_bytes (pbkdf ~salt ~password) in
    let msg =
      match (sk : Signature.secret_key) with
      | Ed25519 sk ->
          Data_encoding.Binary.to_bytes_exn Ed25519.Secret_key.encoding sk
      | Secp256k1 sk ->
          Data_encoding.Binary.to_bytes_exn Secp256k1.Secret_key.encoding sk
      | P256 sk ->
          Data_encoding.Binary.to_bytes_exn P256.Secret_key.encoding sk
    in
    Bytes.cat salt (Crypto_box.Secretbox.secretbox key msg nonce)

  let decrypt algo ~password ~encrypted_sk =
    let salt = Bytes.sub encrypted_sk 0 salt_len in
    let encrypted_sk = Bytes.sub encrypted_sk salt_len encrypted_size in
    let key = Crypto_box.Secretbox.unsafe_of_bytes (pbkdf ~salt ~password) in
    match
      (Crypto_box.Secretbox.secretbox_open key encrypted_sk nonce, algo)
    with
    | (None, _) ->
        return_none
    | (Some bytes, Signature.Ed25519) -> (
      match
        Data_encoding.Binary.of_bytes_opt Ed25519.Secret_key.encoding bytes
      with
      | Some sk ->
          return_some (Ed25519 sk : Signature.Secret_key.t)
      | None ->
          failwith
            "Corrupted wallet, deciphered key is not a valid Ed25519 secret key"
      )
    | (Some bytes, Signature.Secp256k1) -> (
      match
        Data_encoding.Binary.of_bytes_opt Secp256k1.Secret_key.encoding bytes
      with
      | Some sk ->
          return_some (Secp256k1 sk : Signature.Secret_key.t)
      | None ->
          failwith
            "Corrupted wallet, deciphered key is not a valid Secp256k1 secret \
             key" )
    | (Some bytes, Signature.P256) -> (
      match
        Data_encoding.Binary.of_bytes_opt P256.Secret_key.encoding bytes
      with
      | Some sk ->
          return_some (P256 sk : Signature.Secret_key.t)
      | None ->
          failwith
            "Corrupted wallet, deciphered key is not a valid P256 secret key" )
end

module Encodings = struct
  let ed25519 =
    let length = Hacl.Ed25519.sk_size + Crypto_box.tag_length + Raw.salt_len in
    Base58.register_encoding
      ~prefix:Base58.Prefix.ed25519_encrypted_seed
      ~length
      ~to_raw:(fun sk -> Bytes.to_string sk)
      ~of_raw:(fun buf ->
        if String.length buf <> length then None
        else Some (Bytes.of_string buf))
      ~wrap:(fun sk -> Encrypted_ed25519 sk)

  let secp256k1 =
    let open Libsecp256k1.External in
    let length = Key.secret_bytes + Crypto_box.tag_length + Raw.salt_len in
    Base58.register_encoding
      ~prefix:Base58.Prefix.secp256k1_encrypted_secret_key
      ~length
      ~to_raw:(fun sk -> Bytes.to_string sk)
      ~of_raw:(fun buf ->
        if String.length buf <> length then None
        else Some (Bytes.of_string buf))
      ~wrap:(fun sk -> Encrypted_secp256k1 sk)

  let p256 =
    let length = Hacl.P256.sk_size + Crypto_box.tag_length + Raw.salt_len in
    Base58.register_encoding
      ~prefix:Base58.Prefix.p256_encrypted_secret_key
      ~length
      ~to_raw:(fun sk -> Bytes.to_string sk)
      ~of_raw:(fun buf ->
        if String.length buf <> length then None
        else Some (Bytes.of_string buf))
      ~wrap:(fun sk -> Encrypted_p256 sk)

  let () =
    Base58.check_encoded_prefix ed25519 "edesk" 88 ;
    Base58.check_encoded_prefix secp256k1 "spesk" 88 ;
    Base58.check_encoded_prefix p256 "p2esk" 88
end

(* we cache the password in this list to avoid
   asking the user all the time *)
let passwords = ref []

let rec interactive_decrypt_loop (cctxt : #Client_context.prompter) ?name
    ~encrypted_sk algo =
  ( match name with
  | None ->
      cctxt#prompt_password "Enter password for encrypted key: "
  | Some name ->
      cctxt#prompt_password "Enter password for encrypted key \"%s\": " name )
  >>=? fun password ->
  Raw.decrypt algo ~password ~encrypted_sk
  >>=? function
  | Some sk ->
      passwords := password :: !passwords ;
      return sk
  | None ->
      interactive_decrypt_loop cctxt ?name ~encrypted_sk algo

(* add all passwords obtained by [ctxt#load_passwords] to the list of known passwords *)
let password_file_load ctxt =
  match ctxt#load_passwords with
  | Some stream ->
      Lwt_stream.iter
        (fun p -> passwords := Bytes.of_string p :: !passwords)
        stream
      >>= fun () -> return_unit
  | None ->
      return_unit

let rec noninteractive_decrypt_loop algo ~encrypted_sk = function
  | [] ->
      return_none
  | password :: passwords -> (
      Raw.decrypt algo ~password ~encrypted_sk
      >>=? function
      | None ->
          noninteractive_decrypt_loop algo ~encrypted_sk passwords
      | Some sk ->
          return_some sk )

let decrypt_payload cctxt ?name encrypted_sk =
  ( match Base58.decode encrypted_sk with
  | Some (Encrypted_ed25519 encrypted_sk) ->
      return (Signature.Ed25519, encrypted_sk)
  | Some (Encrypted_secp256k1 encrypted_sk) ->
      return (Signature.Secp256k1, encrypted_sk)
  | Some (Encrypted_p256 encrypted_sk) ->
      return (Signature.P256, encrypted_sk)
  | _ ->
      failwith "Not a Base58Check-encoded encrypted key" )
  >>=? fun (algo, encrypted_sk) ->
  noninteractive_decrypt_loop algo ~encrypted_sk !passwords
  >>=? function
  | Some sk ->
      return sk
  | None ->
      interactive_decrypt_loop cctxt ?name ~encrypted_sk algo

let decrypt (cctxt : #Client_context.prompter) ?name sk_uri =
  let payload = Uri.path (sk_uri : sk_uri :> Uri.t) in
  decrypt_payload cctxt ?name payload

let decrypt_all (cctxt : #Client_context.io_wallet) =
  Secret_key.load cctxt
  >>=? fun sks ->
  password_file_load cctxt
  >>=? fun () ->
  iter_s
    (fun (name, sk_uri) ->
      if Uri.scheme (sk_uri : sk_uri :> Uri.t) <> Some scheme then return_unit
      else decrypt cctxt ~name sk_uri >>=? fun _ -> return_unit)
    sks

let decrypt_list (cctxt : #Client_context.io_wallet) keys =
  Secret_key.load cctxt
  >>=? fun sks ->
  password_file_load cctxt
  >>=? fun () ->
  iter_s
    (fun (name, sk_uri) ->
      if
        Uri.scheme (sk_uri : sk_uri :> Uri.t) = Some scheme
        && (keys = [] || List.mem name keys)
      then decrypt cctxt ~name sk_uri >>=? fun _ -> return_unit
      else return_unit)
    sks

let rec read_password (cctxt : #Client_context.io) =
  cctxt#prompt_password "Enter password to encrypt your key: "
  >>=? fun password ->
  cctxt#prompt_password "Confirm password: "
  >>=? fun confirm ->
  if not (Bytes.equal password confirm) then
    cctxt#message "Passwords do not match." >>= fun () -> read_password cctxt
  else return password

let encrypt cctxt sk =
  read_password cctxt
  >>=? fun password ->
  let payload = Raw.encrypt ~password sk in
  let encoding =
    match sk with
    | Ed25519 _ ->
        Encodings.ed25519
    | Secp256k1 _ ->
        Encodings.secp256k1
    | P256 _ ->
        Encodings.p256
  in
  let path = Base58.simple_encode encoding payload in
  Client_keys.make_sk_uri (Uri.make ~scheme ~path ())

module Sapling_raw = struct
  let salt_len = 8

  (* 193 *)
  let encrypted_size = Crypto_box.tag_length + salt_len + 169

  let nonce = Crypto_box.zero_nonce

  let pbkdf ~salt ~password =
    Pbkdf.SHA512.pbkdf2 ~count:32768 ~dk_len:32l ~salt ~password

  let encrypt ~password msg =
    let msg = Tezos_sapling.Core.Wallet.Spending_key.to_bytes msg in
    let salt = Hacl.Rand.gen salt_len in
    let key = Crypto_box.Secretbox.unsafe_of_bytes (pbkdf ~salt ~password) in
    Bytes.(to_string (cat salt (Crypto_box.Secretbox.secretbox key msg nonce)))

  let decrypt ~password payload =
    let ebytes = Bytes.of_string payload in
    let salt = Bytes.sub ebytes 0 salt_len in
    let encrypted_sk = Bytes.sub ebytes salt_len (encrypted_size - salt_len) in
    let key = Crypto_box.Secretbox.unsafe_of_bytes (pbkdf ~salt ~password) in
    Option.(
      Crypto_box.Secretbox.secretbox_open key encrypted_sk nonce
      >>= Tezos_sapling.Core.Wallet.Spending_key.of_bytes)

  type Base58.data += Data of Tezos_sapling.Core.Wallet.Spending_key.t

  let encrypted_b58_encoding password =
    Base58.register_encoding
      ~prefix:Base58.Prefix.sapling_spending_key
      ~length:encrypted_size
      ~to_raw:(encrypt ~password)
      ~of_raw:(decrypt ~password)
      ~wrap:(fun x -> Data x)
end

let encrypt_sapling_key cctxt sk =
  read_password cctxt
  >>=? fun password ->
  let path =
    Base58.simple_encode (Sapling_raw.encrypted_b58_encoding password) sk
  in
  return (Client_keys.make_sapling_uri (Uri.make ~scheme ~path ()))

let decrypt_sapling_key (cctxt : #Client_context.io) (sk_uri : sapling_uri) =
  let uri = (sk_uri :> Uri.t) in
  let payload = Uri.path uri in
  if Uri.scheme uri = Some scheme then
    cctxt#prompt_password "Enter password to decrypt your key: "
    >>=? fun password ->
    match
      Base58.simple_decode
        (Sapling_raw.encrypted_b58_encoding password)
        payload
    with
    | None ->
        failwith
          "Password incorrect or corrupted wallet, could not decipher \
           encrypted Sapling spending key."
    | Some sapling_key ->
        return sapling_key
  else
    match
      Base58.simple_decode
        Tezos_sapling.Core.Wallet.Spending_key.b58check_encoding
        payload
    with
    | None ->
        failwith
          "Corrupted wallet, could not read unencrypted Sapling spending key."
    | Some sapling_key ->
        return sapling_key

module Make (C : sig
  val cctxt : Client_context.prompter
end) =
struct
  let scheme = "encrypted"

  let title = "Built-in signer using encrypted keys."

  let description =
    "Valid secret key URIs are of the form\n\
    \ - encrypted:<encrypted_key>\n\
     where <encrypted_key> is the encrypted (password protected using Nacl's \
     cryptobox and pbkdf) secret key, formatted in unprefixed Base58.\n\
     Valid public key URIs are of the form\n\
    \ - encrypted:<public_key>\n\
     where <public_key> is the public key in Base58."

  let public_key = Unencrypted.public_key

  let public_key_hash = Unencrypted.public_key_hash

  let import_secret_key = Unencrypted.import_secret_key

  let neuterize sk_uri =
    decrypt C.cctxt sk_uri
    >>=? fun sk -> Unencrypted.make_pk (Signature.Secret_key.to_public_key sk)

  let sign ?watermark sk_uri buf =
    decrypt C.cctxt sk_uri
    >>=? fun sk -> return (Signature.sign ?watermark sk buf)

  let deterministic_nonce sk_uri buf =
    decrypt C.cctxt sk_uri
    >>=? fun sk -> return (Signature.deterministic_nonce sk buf)

  let deterministic_nonce_hash sk_uri buf =
    decrypt C.cctxt sk_uri
    >>=? fun sk -> return (Signature.deterministic_nonce_hash sk buf)

  let supports_deterministic_nonces _ = return_true
end
