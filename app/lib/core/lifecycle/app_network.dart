import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class AppNetwork {
  AppNetwork._();

  static final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  static StreamSubscription<List<ConnectivityResult>>? _sub;

  /// Starts observing connectivity. Idempotent; called once from `App`.
  static void start({Connectivity? connectivity}) {
    if (_sub != null) return;
    final source = connectivity ?? Connectivity();
    _sub = source.onConnectivityChanged.listen(
      _apply,
      // A platform that cannot report connectivity must not pin the app to
      // "offline" — leave the optimistic default and let the RPCs decide.
      onError: (Object _) => online.value = true,
    );
    unawaited(
      source.checkConnectivity().then(_apply).catchError((Object _) {
        online.value = true;
      }),
    );
  }

  static void _apply(List<ConnectivityResult> results) {
    online.value = results.any((r) => r != ConnectivityResult.none);
  }

  @visibleForTesting
  static void reset() {
    unawaited(_sub?.cancel());
    _sub = null;
    online.value = true;
  }
}
