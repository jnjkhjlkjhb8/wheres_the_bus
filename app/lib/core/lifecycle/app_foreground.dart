import 'package:flutter/widgets.dart';

class AppForeground {
  AppForeground._();

  static final ValueNotifier<bool> value = ValueNotifier<bool>(true);

  static AppLifecycleListener? _listener;

  /// Starts observing the lifecycle. Idempotent; called once from `App`.
  static void start() {
    _listener ??= AppLifecycleListener(
      onStateChange: (state) => value.value = switch (state) {
        AppLifecycleState.resumed || AppLifecycleState.inactive => true,
        AppLifecycleState.hidden ||
        AppLifecycleState.paused ||
        AppLifecycleState.detached => false,
      },
    );
  }

  @visibleForTesting
  static void reset() {
    _listener?.dispose();
    _listener = null;
    value.value = true;
  }
}
