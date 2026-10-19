import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';
import 'package:wheres_the_bus/core/firebase/install_identity.dart';

class FirebaseCallOptions {
  FirebaseCallOptions._();

  static Future<CallOptions> build({
    bool enabled = FirebaseGate.enabled,
    bool tls = FirebaseGate.grpcTLS,
    Future<String?> Function()? tokenLoader,
    Future<String> Function()? installIdLoader,
    Future<String> Function()? installSecretLoader,
  }) async {
    if (!enabled) return CallOptions();
    FirebaseGate.ensureSecureTransport(
      firebaseEnabled: enabled,
      tlsEnabled: tls,
    );
    final (installId, installSecret) = await _installationPair(
      installIdLoader,
      installSecretLoader,
    );
    if (installId.isEmpty || installSecret.isEmpty) {
      throw StateError('installation credential is unavailable');
    }
    final token = await _attestationToken(tokenLoader);
    return CallOptions(
      metadata: {
        'x-install-id': installId,
        'x-install-secret': installSecret,
        ..._attestationHeader(token),
      },
    );
  }

  static Map<String, String> _attestationHeader(String? token) =>
      token != null && token.isNotEmpty ? {'x-firebase-appcheck': token} : {};

  static Future<(String, String)> _installationPair(
    Future<String> Function()? idLoader,
    Future<String> Function()? secretLoader,
  ) async {
    if (idLoader == null && secretLoader == null) {
      return InstallIdentity.getOrCreatePair();
    }
    return _loadedPair(idLoader, secretLoader);
  }

  static Future<(String, String)> _loadedPair(
    Future<String> Function()? idLoader,
    Future<String> Function()? secretLoader,
  ) async {
    return (
      await (idLoader ?? InstallIdentity.getOrCreate)(),
      await (secretLoader ?? InstallIdentity.getOrCreateSecret)(),
    );
  }

  static Future<String?> _attestationToken(
    Future<String?> Function()? loader,
  ) async {
    // Missing App Check attestation must not abort device registration.
    try {
      return await (loader ?? FirebaseAppCheck.instance.getToken)();
    } on Object catch (_) {
      return null;
    }
  }
}
