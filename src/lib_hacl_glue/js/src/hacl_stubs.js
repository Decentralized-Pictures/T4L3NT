/* global _HACL */


//Provides: buf2hex
function buf2hex(buffer) { // eslint-disable-line no-unused-vars
  return Array.prototype.map.call(new Uint8Array(buffer), function(x) {
    return ('00' + x.toString(16)).slice(-2);
  }).join('');
}

/* exported buf2hex */

//Provides: hex2buf
function hex2buf(hexString) { // eslint-disable-line no-unused-vars
  if (hexString === "") {
    return new Uint8Array(0);
  } else {
    return new Uint8Array(hexString.match(/.{2}/g).map(function(byte) {
      return parseInt(byte, 16);
    }));
  }
}

//Provides: MlBytes2buf
//Requires: caml_bytes_unsafe_get
function MlBytes2buf(MlBytes) {
  var len = MlBytes.l;
  var buf = new Uint8Array(len);
  var i=0;
  for (i=0; i<len; i++) {
    var uint8 = caml_bytes_unsafe_get(MlBytes, i);
    buf[i] = uint8;
  }
  return buf;
}

//Provides: buf2MlBytes
//Requires: caml_string_of_jsbytes
function buf2MlBytes(buf) { // eslint-disable-line no-unused-vars
  var s = '';
  buf.forEach(function(uint8) {
    var high = uint8 >> 4;
    s += high.toString(16);
    var low = uint8 & 15;
    s += low.toString(16);
  });
  return caml_string_of_jsbytes(s);
}

//Provides: blit_buf_onto_MlBytes
//Requires: caml_string_unsafe_set
function blit_buf_onto_MlBytes(buf, MlBytes) {
  buf.forEach(function(uint8, index) {
    caml_string_unsafe_set(MlBytes, index, uint8)
  });
  return 0;
}

//Provides: _1_Lib_RandomBuffer_System_randombytes
//Requires: blit_buf_onto_MlBytes
function _1_Lib_RandomBuffer_System_randombytes(buf) { // eslint-disable-line no-unused-vars
  return ((typeof self !== 'undefined' && (self.crypto || self.msCrypto))
    ? function() { // Browsers
      var crypto = (self.crypto || self.msCrypto), QUOTA = 65536;
      return function(n) {
        var result = new Uint8Array(n);
        for (var i = 0; i < n; i += QUOTA) {
          crypto.getRandomValues(result.subarray(i, i + Math.min(n - i, QUOTA)));
        }
        blit_buf_onto_MlBytes(result, buf);
        return true;
      };
    }
    : function() { // Node
      var result = require("crypto").randomBytes(60);
      blit_buf_onto_MlBytes(result, buf);
      return true;
    })(buf)
}

//Provides: Hacl_Hash_Core_SHA2_init_256
function Hacl_Hash_Core_SHA2_init_256(state) { // eslint-disable-line no-unused-vars
  throw ' not implemented Hacl_Hash_Core_SHA2_init_256';
}

//Provides: Hacl_Hash_Core_SHA2_update_256
function Hacl_Hash_Core_SHA2_update_256(state, bytes) { // eslint-disable-line no-unused-vars
  throw ' not implemented Hacl_Hash_Core_SHA2_update_256';
}

//Provides: Hacl_Hash_Core_SHA2_finish_256
function Hacl_Hash_Core_SHA2_finish_256(state, hash) { // eslint-disable-line no-unused-vars
  throw ' not implemented Hacl_Hash_Core_SHA2_finish_256';
}

//Provides: Hacl_Hash_Core_SHA2_init_512
function Hacl_Hash_Core_SHA2_init_512(state) { // eslint-disable-line no-unused-vars
  throw ' not implemented Hacl_Hash_Core_SHA2_init_512';
}

//Provides: Hacl_Hash_Core_SHA2_update_512
function Hacl_Hash_Core_SHA2_update_512(state, bytes) { // eslint-disable-line no-unused-vars
  throw ' not implemented Hacl_Hash_Core_SHA2_update_512';
}

//Provides: Hacl_Hash_Core_SHA2_finish_512
function Hacl_Hash_Core_SHA2_finish_512(state, hash) { // eslint-disable-line no-unused-vars
  throw ' not implemented Hacl_Hash_Core_SHA2_finish_512';
}

//Provides: Hacl_Blake2b_32_blake2b
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_Blake2b_32_blake2b(key, msg, digest_len, digest) { // eslint-disable-line no-unused-vars
  var bkey = MlBytes2buf(key);
  var bmsg = MlBytes2buf(msg);
  var bret = _HACL.Blake2.blake2b(digest_len, bmsg, bkey);
  blit_buf_onto_MlBytes(bret[0], digest);
  return 0;
}

//Provides: Hacl_Hash_SHA2_hash_256
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_Hash_SHA2_hash_256(msg, digest) { // eslint-disable-line no-unused-vars
  var bmsg = MlBytes2buf(msg);
  var bret = _HACL.SHA2.hash_256(bmsg);
  blit_buf_onto_MlBytes(bret[0], digest);
  return 0;
}

//Provides: Hacl_Hash_SHA2_hash_512
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_Hash_SHA2_hash_512(msg, digest) { // eslint-disable-line no-unused-vars
  var bmsg = MlBytes2buf(msg);
  var bret = _HACL.SHA2.hash_512(bmsg);
  blit_buf_onto_MlBytes(bret[0], digest);
  return 0;
}

//Provides: Hacl_SHA3_sha3_256
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_SHA3_sha3_256(msg, digest) { // eslint-disable-line no-unused-vars
  var bmsg = MlBytes2buf(msg);
  var bret = _HACL.SHA3.hash_256(bmsg);
  blit_buf_onto_MlBytes(bret[0], digest);
  return 0;
}

//Provides: Hacl_SHA3_sha3_512
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_SHA3_sha3_512(msg, digest) { // eslint-disable-line no-unused-vars
  var bmsg = MlBytes2buf(msg);
  var bret = _HACL.SHA3.hash_512(bmsg);
  blit_buf_onto_MlBytes(bret[0], digest);
  return 0;
}

//Provides: Hacl_Impl_SHA3_keccak
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_Impl_SHA3_keccak(rate, capacity, suffix, msg, digest) { // eslint-disable-line no-unused-vars
  var bmsg = MlBytes2buf(msg);
  // The length of the output buffer needs to be passed in explicitly because
  // since the buffer itself is not passed there is no way to retrive its
  // size in api.js
  var bret = _HACL.SHA3.keccak(rate, capacity, bmsg, suffix, digest.l);
  blit_buf_onto_MlBytes(bret[0], digest);
  return 0;
}

//Provides: Hacl_HMAC_compute_sha2_256
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_HMAC_compute_sha2_256 (output, key, msg) { // eslint-disable-line no-unused-vars
  var bkey = MlBytes2buf(key);
  var bmsg = MlBytes2buf(msg);
  var bret = _HACL.HMAC.sha256(bkey, bmsg);
  blit_buf_onto_MlBytes(bret[0], output);
  return 0;
}

//Provides: Hacl_HMAC_compute_sha2_512
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_HMAC_compute_sha2_512 (output, key, msg) { // eslint-disable-line no-unused-vars
  var bkey = MlBytes2buf(key);
  var bmsg = MlBytes2buf(msg);
  var bret = _HACL.HMAC.sha512(bkey, bmsg);
  blit_buf_onto_MlBytes(bret[0], output);
  return 0;
}

//Provides: Hacl_Curve25519_51_scalarmult
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_Curve25519_51_scalarmult(pk, sk, basepoint) { // eslint-disable-line no-unused-vars
  var bsk = MlBytes2buf(sk);
  var bret = _HACL.Curve25519_51.secret_to_public(bsk);
  blit_buf_onto_MlBytes(bret[0], pk);
  return 0;
}

//Provides: Hacl_NaCl_crypto_secretbox_easy
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_NaCl_crypto_secretbox_easy(c, m, n, k) { // eslint-disable-line no-unused-vars
  var bm = MlBytes2buf(m);
  var bn = MlBytes2buf(n);
  var bk = MlBytes2buf(k);
  var bret = _HACL.NaCl.secretbox_easy(bm, bn, bk);
  blit_buf_onto_MlBytes(bret[1], c);
  return (bret[0] === 0);
}

//Provides: Hacl_NaCl_crypto_secretbox_open_easy
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_NaCl_crypto_secretbox_open_easy(m, c, n, k) { // eslint-disable-line no-unused-vars
  var bc = MlBytes2buf(c);
  var bn = MlBytes2buf(n);
  var bk = MlBytes2buf(k);
  var bret = _HACL.NaCl.secretbox_open_easy(bc, bn, bk);
  blit_buf_onto_MlBytes(bret[1], m);
  return (bret[0] === 0);
}

//Provides: Hacl_NaCl_crypto_box_beforenm
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_NaCl_crypto_box_beforenm(k, pk, sk) { // eslint-disable-line no-unused-vars
  var bpk = MlBytes2buf(pk);
  var bsk = MlBytes2buf(sk);
  var bret = _HACL.NaCl.box_beforenm(bpk, bsk);
  blit_buf_onto_MlBytes(bret[1], k);
  return (bret[0] === 0);
}

//Provides: Hacl_NaCl_crypto_box_easy_afternm
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_NaCl_crypto_box_easy_afternm(c, m, n, k) { // eslint-disable-line no-unused-vars
  var bm = MlBytes2buf(m);
  var bn = MlBytes2buf(n);
  var bk = MlBytes2buf(k);
  var bret = _HACL.NaCl.box_easy_afternm(bm, bn, bk);
  blit_buf_onto_MlBytes(bret[1], c);
  return (bret[0] === 0);
}

//Provides: Hacl_NaCl_crypto_box_open_easy_afternm
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_NaCl_crypto_box_open_easy_afternm(m, c, n, k) { // eslint-disable-line no-unused-vars
  var bc = MlBytes2buf(c);
  var bn = MlBytes2buf(n);
  var bk = MlBytes2buf(k);
  var bret = _HACL.NaCl.box_open_easy_afternm(bc, bn, bk);
  blit_buf_onto_MlBytes(bret[1], m);
  return (bret[0] === 0);
}

//Provides: Hacl_NaCl_crypto_box_detached_afternm
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_NaCl_crypto_box_detached_afternm(c, tag, m, n, k) { // eslint-disable-line no-unused-vars
  var bm = MlBytes2buf(m);
  var bn = MlBytes2buf(n);
  var bk = MlBytes2buf(k);
  var bret = _HACL.NaCl.box_detached_afternm(bm, bn, bk);
  blit_buf_onto_MlBytes(bret[1], c);
  blit_buf_onto_MlBytes(bret[2], tag);
  return (bret[0] === 0);
}

//Provides: Hacl_NaCl_crypto_box_open_detached_afternm
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_NaCl_crypto_box_open_detached_afternm(m, c, tag, n, k) { // eslint-disable-line no-unused-vars
  var btag = MlBytes2buf(tag);
  var bc = MlBytes2buf(c);
  var bn = MlBytes2buf(n);
  var bk = MlBytes2buf(k);
  var bret = _HACL.NaCl.box_open_detached_afternm(bc, btag, bn, bk);
  blit_buf_onto_MlBytes(bret[1], m);
  return (bret[0] === 0);
}

//Provides: Hacl_Ed25519_secret_to_public
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_Ed25519_secret_to_public(out, secret) { // eslint-disable-line no-unused-vars
  var bsecret = MlBytes2buf(secret);
  var bret = _HACL.Ed25519.secret_to_public(bsecret);
  blit_buf_onto_MlBytes(bret[0], out);
  return 0;
}

//Provides: Hacl_Ed25519_sign
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_Ed25519_sign(signature, sk, msg) { // eslint-disable-line no-unused-vars
  var bsk = MlBytes2buf(sk);
  var bmsg = MlBytes2buf(msg);
  var bret = _HACL.Ed25519.sign(bsk, bmsg);
  blit_buf_onto_MlBytes(bret[0], signature);
  return 0;
}

//Provides: Hacl_Ed25519_verify
//Requires: MlBytes2buf
function Hacl_Ed25519_verify(pk, msg, signature) { // eslint-disable-line no-unused-vars
  var bpk = MlBytes2buf(pk);
  var bmsg = MlBytes2buf(msg);
  var bsignature = MlBytes2buf(signature);
  var r = _HACL.Ed25519.verify(bpk, bmsg, bsignature);
  return r[0];
}

//Provides: Hacl_P256_ecdsa_sign_p256_without_hash
function Hacl_P256_ecdsa_sign_p256_without_hash () { // eslint-disable-line no-unused-vars
  //Not implemented, failing
  assert.fail();
}

//Provides: Hacl_P256_ecdsa_verif_without_hash
//Requires: MlBytes2buf
function Hacl_P256_ecdsa_verif_without_hash (pk, msg, sig_r, sig_s) { // eslint-disable-line no-unused-vars
  var bpk = MlBytes2buf(pk);
  var bmsg = MlBytes2buf(msg);
  var bsig_r = MlBytes2buf(sig_r);
  var bsig_s = MlBytes2buf(sig_s);
  var bret = _HACL.P256.ecdsa_verif_without_hash(bmsg, bpk, bsig_r, bsig_s);
  return bret[0];
}

//Provides: Hacl_P256_is_more_than_zero_less_than_order
//Requires: MlBytes2buf
function Hacl_P256_is_more_than_zero_less_than_order (sk) { // eslint-disable-line no-unused-vars
  var bsk = MlBytes2buf(sk);
  var bret = _HACL.P256.is_more_than_zero_less_than_order(bsk);
  return bret[0];
}

//Provides: Hacl_P256_verify_q
//Requires: MlBytes2buf
function Hacl_P256_verify_q (pk) { // eslint-disable-line no-unused-vars
  var bpk = MlBytes2buf(pk);
  var bret = _HACL.P256.verify_q(bpk);
  return bret[0];
}

//Provides: Hacl_P256_ecp256dh_i
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_P256_ecp256dh_i (pk, sk) { // eslint-disable-line no-unused-vars
  var bsk = MlBytes2buf(sk);
  var bret = _HACL.P256.dh_initiator(bsk);
  blit_buf_onto_MlBytes(bret[1], pk);
  return bret[0];
}

//Provides: Hacl_P256_compression_compressed_form
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_P256_compression_compressed_form (pk, out) { // eslint-disable-line no-unused-vars
  var bpk = MlBytes2buf(pk);
  var bret = _HACL.P256.compression_compressed_form(bpk);
  blit_buf_onto_MlBytes(bret[0], out);
  return 0;
}

//Provides: Hacl_P256_compression_not_compressed_form
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_P256_compression_not_compressed_form (pk, out) { // eslint-disable-line no-unused-vars
  var bpk = MlBytes2buf(pk);
  var bret = _HACL.P256.compression_not_compressed_form(bpk);
  blit_buf_onto_MlBytes(bret[0], out);
  return 0;
}

//Provides: Hacl_P256_decompression_compressed_form
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_P256_decompression_compressed_form (pk, out) { // eslint-disable-line no-unused-vars
  var bpk = MlBytes2buf(pk);
  var bret = _HACL.P256.decompression_compressed_form(bpk);
  blit_buf_onto_MlBytes(bret[1], out);
  return bret[0];
}

//Provides: Hacl_P256_decompression_not_compressed_form
//Requires: MlBytes2buf, blit_buf_onto_MlBytes
function Hacl_P256_decompression_not_compressed_form (pk, out) { // eslint-disable-line no-unused-vars
  var bpk = MlBytes2buf(pk);
  var bret = _HACL.P256.decompression_not_compressed_form(bpk);
  blit_buf_onto_MlBytes(bret[1], out);
  return bret[0];
}
