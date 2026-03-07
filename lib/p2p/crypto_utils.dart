// lib/p2p/crypto_utils.dart
//
// Mirrors Python crypto layer:
//   Ed25519 signing/verification  â†’ cryptography package Ed25519()
//   X25519 ECDH + HKDF-SHA256    â†’ derive_pairwise_key()
//   AES-256-GCM                   â†’ encrypt / decrypt with AAD
//   PBKDF2-SHA256 (â†’ Argon2id)   â†’ derive_master_key()
//   Canonical JSON                â†’ json.dumps(sort_keys=True, separators=(',',':'))

import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as stdcrypto;
import 'package:cryptography/cryptography.dart';

class CryptoUtils {
  static final _ed25519 = Ed25519();
  static final _x25519 = X25519();
  static final _aesGcm = AesGcm.with256bits(nonceLength: 12);
  static final _rng = Random.secure();

  // â”€â”€ Encoding helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static String b64e(List<int> data) => base64Encode(data);
  static Uint8List b64d(String data) => Uint8List.fromList(base64Decode(data));
  static String hexEncode(List<int> data) => hex.encode(data);
  static List<int> hexDecode(String s) => hex.decode(s);

  static Uint8List randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  static String sha256Hex(List<int> data) =>
      hex.encode(stdcrypto.sha256.convert(data).bytes);

  // â”€â”€ Canonical JSON (mirrors json.dumps(sort_keys=True, separators=(',',':')))
  static String canonicalJson(Map<String, dynamic> data) =>
      jsonEncode(_sorted(data));

  static dynamic _sorted(dynamic v) {
    if (v is Map) {
      final t = SplayTreeMap<String, dynamic>();
      for (final k in v.keys) {
        t[k.toString()] = _sorted(v[k]);
      }
      return t;
    }
    if (v is List) return v.map(_sorted).toList();
    return v;
  }

  // â”€â”€ Key generation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static Future<SimpleKeyPair> generateEdKeyPair() => _ed25519.newKeyPair();
  static Future<SimpleKeyPair> generateXKeyPair() => _x25519.newKeyPair();

  // â”€â”€ Key serialisation â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Ed25519 private seed bytes (32 B) â†’ base64.
  static Future<String> edPrivToB64(SimpleKeyPair kp) async {
    final data = await kp.extract();
    return b64e(data.bytes);
  }

  /// Restore Ed25519 key pair from private seed base64.
  static Future<SimpleKeyPair> edPrivFromB64(String b) async {
    return _ed25519.newKeyPairFromSeed(b64d(b));
  }

  /// Ed25519 public key as hex â†’ node ID.
  static Future<String> edPubHex(SimpleKeyPair kp) async {
    final pub = await kp.extractPublicKey();
    return hexEncode(pub.bytes);
  }

  /// X25519 private bytes (32 B) â†’ base64.
  static Future<String> xPrivToB64(SimpleKeyPair kp) async {
    final data = await kp.extract();
    return b64e(data.bytes);
  }

  /// Restore X25519 key pair from private bytes base64.
  static Future<SimpleKeyPair> xPrivFromB64(String b) async {
    return _x25519.newKeyPairFromSeed(b64d(b));
  }

  /// Restore X25519 key pair from private+public bytes (base64 each).
  /// Public key is validated against the private key to avoid mismatches.
  static Future<SimpleKeyPair> xKeyPairFromB64(
      String privB64, String pubB64) async {
    final kp = await _x25519.newKeyPairFromSeed(b64d(privB64));
    final derivedPub = await kp.extractPublicKey();
    final expectedPub = b64d(pubB64);
    if (!_bytesEqual(derivedPub.bytes, expectedPub)) {
      throw Exception('X25519 key mismatch: public key does not match private key');
    }
    return kp;
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// X25519 public key hex.
  static Future<String> xPubHex(SimpleKeyPair kp) async {
    final pub = await kp.extractPublicKey();
    return hexEncode(pub.bytes);
  }

  // â”€â”€ Signing / verification â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Sign canonical JSON of [payload] â†’ base64 signature.
  static Future<String> signDict(
      Map<String, dynamic> payload, SimpleKeyPair signKp) async {
    final bytes = Uint8List.fromList(utf8.encode(canonicalJson(payload)));
    final sig = await _ed25519.sign(bytes, keyPair: signKp);
    return b64e(sig.bytes);
  }

  /// Verify a base64 signature against [payload]'s canonical JSON
  /// using [pubHex] as Ed25519 public key (= sender_id).
  static Future<bool> verifyDictSig(
      Map<String, dynamic> payload, String sigB64, String pubHex) async {
    try {
      final pubBytes = Uint8List.fromList(hexDecode(pubHex));
      final pubKey = SimplePublicKey(pubBytes, type: KeyPairType.ed25519);
      final sig = Signature(b64d(sigB64), publicKey: pubKey);
      final bytes = Uint8List.fromList(utf8.encode(canonicalJson(payload)));
      return await _ed25519.verify(bytes, signature: sig);
    } catch (_) {
      return false;
    }
  }

  // â”€â”€ Pairwise key derivation (X25519 ECDH + HKDF-SHA256) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Mirrors derive_pairwise_key(my_x_priv, peer_x_pub_hex, info).
  static Future<SecretKey> derivePairwiseKey(
      SimpleKeyPair myXPriv, String peerXPubHex, List<int> info) async {
    final peerPub = SimplePublicKey(
        Uint8List.fromList(hexDecode(peerXPubHex)),
        type: KeyPairType.x25519);
    final shared =
        await _x25519.sharedSecretKey(keyPair: myXPriv, remotePublicKey: peerPub);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(secretKey: shared, info: info);
  }

  // â”€â”€ AES-256-GCM encrypt / decrypt â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Returns (nonce, ciphertext+mac).
  static Future<(Uint8List, Uint8List)> aesEncrypt(
      SecretKey key, List<int> plain, List<int> aad) async {
    final nonce = randomBytes(12);
    final box = await _aesGcm.encrypt(plain,
        secretKey: key, nonce: nonce, aad: aad);
    final ct =
        Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return (nonce, ct);
  }

  static Future<Uint8List> aesDecrypt(
      SecretKey key, List<int> nonce, List<int> ciphertext, List<int> aad) async {
    final mac = Mac(ciphertext.sublist(ciphertext.length - 16));
    final ct = ciphertext.sublist(0, ciphertext.length - 16);
    final box = SecretBox(ct, nonce: nonce, mac: mac);
    return Uint8List.fromList(
        await _aesGcm.decrypt(box, secretKey: key, aad: aad));
  }

  // â”€â”€ JSON blob encryption (for identity/history on disk) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static Future<Map<String, dynamic>> encryptJsonBlob(
      SecretKey key, Map<String, dynamic> data, List<int> aad) async {
    final (nonce, ct) =
        await aesEncrypt(key, utf8.encode(canonicalJson(data)), aad);
    return {'v': 1, 'nonce': b64e(nonce), 'ciphertext': b64e(ct)};
  }

  static Future<Map<String, dynamic>> decryptJsonBlob(
      SecretKey key, Map<String, dynamic> blob, List<int> aad) async {
    final nonce = b64d(blob['nonce'] as String);
    final ct = b64d(blob['ciphertext'] as String);
    final plain = await aesDecrypt(key, nonce, ct, aad);
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  // â”€â”€ Disk encryption (CAS media storage) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  /// Mirrors encrypt_bytes_for_disk() â†’ "MCAS1" + 12B nonce + ciphertext+mac
  static Future<Uint8List> encryptForDisk(
      SecretKey masterKey, List<int> plain) async {
    final (nonce, ct) =
        await aesEncrypt(masterKey, plain, utf8.encode('media_v1'));
    final header = utf8.encode('MCAS1');
    return Uint8List.fromList([...header, ...nonce, ...ct]);
  }

  static Future<Uint8List> decryptFromDisk(
      SecretKey masterKey, Uint8List payload) async {
    if (payload.length < 17 ||
        String.fromCharCodes(payload.sublist(0, 5)) != 'MCAS1') {
      throw Exception('ÐÐµÐºÐ¾Ñ€Ñ€ÐµÐºÑ‚Ð½Ñ‹Ð¹ Ñ„Ð¾Ñ€Ð¼Ð°Ñ‚ Ð·Ð°ÑˆÐ¸Ñ„Ñ€Ð¾Ð²Ð°Ð½Ð½Ð¾Ð³Ð¾ media-Ñ„Ð°Ð¹Ð»Ð°');
    }
    final nonce = payload.sublist(5, 17);
    final ct = payload.sublist(17);
    return aesDecrypt(masterKey, nonce, ct, utf8.encode('media_v1'));
  }

  // â”€â”€ Master key derivation (PBKDF2 â€” replace with Argon2id for production) â”€
  /// Mirrors derive_master_key(password, salt) with Argon2id parameters.
  /// TODO: replace with argon2_flutter for true Argon2id:
  ///   final result = await FlutterArgon2.hash(
  ///     password: password, salt: salt, iterations: 3,
  ///     memory: 65536, parallelism: 4, hashLength: 32,
  ///     type: Argon2Type.id);
  static Future<SecretKey> deriveMasterKey(
      String password, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
        macAlgorithm: Hmac.sha256(), iterations: 200000, bits: 256);
    return pbkdf2.deriveKey(
        secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  }
}


