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
    late final String installId;
    late final String installSecret;
    if (installIdLoader == null && installSecretLoader == null) {
      final pair = await InstallIdentity.getOrCreatePair();
      installId = pair.$1;
      installSecret = pair.$2;
    } else {
      installId = await (installIdLoader ?? InstallIdentity.getOrCreate)();
      installSecret =
          await (installSecretLoader ?? InstallIdentity.getOrCreateSecret)();
    }
    if (installId.isEmpty || installSecret.isEmpty) {
      throw StateError('installation credential is unavailable');
    }
    // App Check attestation can fail (unregistered debug token, transient
    // backend 403); the header below is optional, so degrade to no token
    // instead of aborting device registration.
    String? token;
    try {
      token = await (tokenLoader ?? FirebaseAppCheck.instance.getToken)();
    } on Object catch (_) {
      token = null;
    }
    return CallOptions(
      metadata: {
        'x-install-id': installId,
        'x-install-secret': installSecret,
        if (token != null && token.isNotEmpty) 'x-firebase-appcheck': token,
      },
    );
  }
}
