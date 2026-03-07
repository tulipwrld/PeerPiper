// lib/p2p/identity.dart
//
// Mirrors Python load_or_create_identity() + persist_identity().
// Keys are stored in SharedPreferences as an AES-GCM encrypted JSON blob.

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'crypto_utils.dart';

const _kIdentityKey = 'p2p_identity_v2';
const _kSaltKey = 'p2p_master_salt';

class NodeIdentity {
  final SimpleKeyPair signKeyPair; // Ed25519 â€” node ID = pubkey hex
  final SimpleKeyPair xKeyPair; // X25519 â€” ECDH per-message
  final String myId; // Ed25519 pubkey hex (64 chars)
  final String myXPubHex; // X25519 pubkey hex

  const NodeIdentity({
    required this.signKeyPair,
    required this.xKeyPair,
    required this.myId,
    required this.myXPubHex,
  });
}

class IdentityService {
  static Future<List<int>> getOrCreateMasterSalt() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kSaltKey);
    if (stored != null) {
      return CryptoUtils.b64d(stored).toList();
    }
    final salt = CryptoUtils.randomBytes(16);
    await prefs.setString(_kSaltKey, CryptoUtils.b64e(salt));
    return salt.toList();
  }

  static Future<NodeIdentity> loadOrCreate(SecretKey masterKey) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kIdentityKey);

    if (stored != null) {
      try {
        final blob = jsonDecode(stored) as Map<String, dynamic>;
        final plain = await CryptoUtils.decryptJsonBlob(
            masterKey, blob, utf8.encode('identity_v1'));
        return await _fromMap(plain);
      } catch (_) {
        // corrupted or wrong password â€” generate fresh
      }
    }

    // Generate new identity
    final edKp = await CryptoUtils.generateEdKeyPair();
    final xKp = await CryptoUtils.generateXKeyPair();
    final myId = await CryptoUtils.edPubHex(edKp);
    final myXPub = await CryptoUtils.xPubHex(xKp);

    await _persist(masterKey, edKp, xKp);
    return NodeIdentity(
        signKeyPair: edKp,
        xKeyPair: xKp,
        myId: myId,
        myXPubHex: myXPub);
  }

  static Future<void> _persist(
      SecretKey masterKey, SimpleKeyPair edKp, SimpleKeyPair xKp) async {
    final edPrivB64 = await CryptoUtils.edPrivToB64(edKp);
    final xKpData = await xKp.extract();
    final xPrivB64 = CryptoUtils.b64e(xKpData.bytes);
    final xPubB64 = CryptoUtils.b64e(xKpData.publicKey.bytes);

    final blob = await CryptoUtils.encryptJsonBlob(
      masterKey,
      {
        'ed25519_private': edPrivB64,
        'x25519_private': xPrivB64,
        'x25519_public': xPubB64,
      },
      utf8.encode('identity_v1'),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIdentityKey, jsonEncode(blob));
  }

  static Future<NodeIdentity> _fromMap(Map<String, dynamic> m) async {
    final edKp =
        await CryptoUtils.edPrivFromB64(m['ed25519_private'] as String);

    final xPriv = m['x25519_private'] as String;
    final xPub = m['x25519_public'] as String?;
    late final SimpleKeyPair xKp;
    if (xPub != null && xPub.isNotEmpty) {
      xKp = await CryptoUtils.xKeyPairFromB64(xPriv, xPub);
    } else {
      xKp = await CryptoUtils.xPrivFromB64(xPriv);
    }

    final myId = await CryptoUtils.edPubHex(edKp);
    final myXPub = await CryptoUtils.xPubHex(xKp);
    return NodeIdentity(
        signKeyPair: edKp,
        xKeyPair: xKp,
        myId: myId,
        myXPubHex: myXPub);
  }
}


