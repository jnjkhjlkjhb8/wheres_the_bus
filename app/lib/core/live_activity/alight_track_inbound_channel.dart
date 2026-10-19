import 'package:flutter/services.dart';

abstract final class AlightTrackInboundChannel {
  static const _channel = MethodChannel('me.rabbitsayhello.wheresthebus/live_activity');

  static final _cancelListeners = <void Function()>[];
  static final _tokenListeners = <void Function(String token)>[];

  static void bind(void Function() onCancel) {
    _cancelListeners.add(onCancel);
    _install();
  }

  /// Binds a push-token listener. A stream of tokens rather than one: the
  /// system reissues them at its own discretion, and a card refreshed against a
  /// superseded token silently stops updating.
  static void bindPushToken(void Function(String token) onToken) {
    _tokenListeners.add(onToken);
    _install();
  }

  static void _install() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onCancelTrack':
          _dispatchCancel();
        case 'onPushToken':
          _dispatchPushToken(call.arguments as String?);
      }
      return null;
    });
  }

  static void _dispatchCancel() {
    for (final listener in List.of(_cancelListeners)) {
      listener();
    }
  }

  static void _dispatchPushToken(String? token) {
    if (token != null && token.isNotEmpty) {
      for (final listener in List.of(_tokenListeners)) {
        listener(token);
      }
    }
  }

  /// Test seam: drops every binding so one test's listener cannot fire in the
  /// next.
  static void reset() {
    _cancelListeners.clear();
    _tokenListeners.clear();
  }
}
