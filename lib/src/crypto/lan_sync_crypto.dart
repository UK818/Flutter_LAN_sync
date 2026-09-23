import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Handles all cryptographic operations for the LAN sync system.
///
/// Key exchange:  X25519 ECDH
/// Shared secret: HKDF-SHA256 → 256-bit AES-GCM key (per device-pair)
/// Encryption:    AES-256-GCM (12-byte nonce, 16-byte tag)
/// Storage:       Private key persisted in flutter_secure_storage
class LanSyncCrypto {
  LanSyncCrypto._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const String _privateKeyStorageKey = 'lan_sync_x25519_private_key';
  static const String _hkdfInfo = 'flutter_lan_sync_v1';
  static final List<int> _hkdfSalt =
      utf8.encode('flutter-lan-sync-hkdf-salt-v1');

  static final _x25519 = X25519();
  static final _aesGcm = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static Future<SimpleKeyPair> getOrCreateKeyPair() async {
    final stored = await _storage.read(key: _privateKeyStorageKey);
    if (stored != null) {
      try {
        final bytes = base64Url.decode(stored);
        return await _x25519.newKeyPairFromSeed(bytes);
      } catch (_) {}
    }
    final kp = await _x25519.newKeyPair();
    final seed = await kp.extractPrivateKeyBytes();
    await _storage.write(
      key: _privateKeyStorageKey,
      value: base64Url.encode(seed),
    );
    return kp;
  }

  static Future<String> getPublicKeyBase64() async {
    final kp = await getOrCreateKeyPair();
    final pub = await kp.extractPublicKey();
    return base64Url.encode(pub.bytes);
  }

  static Future<SecretKey> deriveSharedKey(String peerPublicKeyBase64) async {
    final kp = await getOrCreateKeyPair();
    final peerBytes = base64Url.decode(peerPublicKeyBase64);
    final peerPub = SimplePublicKey(peerBytes, type: KeyPairType.x25519);
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey: peerPub,
    );
    return _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: _hkdfSalt,
      info: utf8.encode(_hkdfInfo),
    );
  }

  /// Wire layout: `[ nonce (12 B) | ciphertext | GCM tag (16 B) ]`
  static Future<Uint8List> encrypt(Uint8List plaintext, SecretKey key) async {
    final box = await _aesGcm.encrypt(plaintext, secretKey: key);
    final out = BytesBuilder(copy: false);
    out.add(box.nonce);
    out.add(box.cipherText);
    out.add(box.mac.bytes);
    return out.toBytes();
  }

  static Future<Uint8List> decrypt(Uint8List payload, SecretKey key) async {
    const nonceLen = 12;
    const tagLen = 16;
    if (payload.length < nonceLen + tagLen) {
      throw const FormatException('LAN sync payload too short');
    }
    final nonce = payload.sublist(0, nonceLen);
    final macStart = payload.length - tagLen;
    final cipherText = payload.sublist(nonceLen, macStart);
    final mac = payload.sublist(macStart);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    final plain = await _aesGcm.decrypt(box, secretKey: key);
    return Uint8List.fromList(plain);
  }

  static Future<String> encryptJson(
      Map<String, dynamic> payload, SecretKey key) async {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final cipher = await encrypt(plain, key);
    return base64Url.encode(cipher);
  }

  static Future<Map<String, dynamic>> decryptJson(
      String ciphertextBase64, SecretKey key) async {
    final cipher = base64Url.decode(ciphertextBase64);
    final plain = await decrypt(cipher, key);
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }
}
