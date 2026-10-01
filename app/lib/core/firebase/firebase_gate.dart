class FirebaseGate {
  FirebaseGate._();

  static const appEnv = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'dev',
  );
  static const requested = bool.fromEnvironment('FIREBASE_ENABLED');
  static const bool enabled = requested && appEnv != 'dev';
  static const grpcTLS = bool.fromEnvironment('GRPC_TLS');

  static const appCheckDebugToken = String.fromEnvironment(
    'APP_CHECK_DEBUG_TOKEN',
  );

  static void ensureSecureTransport({
    bool firebaseEnabled = enabled,
    bool tlsEnabled = grpcTLS,
  }) {
    if (firebaseEnabled && !tlsEnabled) {
      throw StateError('Firebase requires GRPC_TLS=true');
    }
  }
}
