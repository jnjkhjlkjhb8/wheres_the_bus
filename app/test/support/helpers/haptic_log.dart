import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every `HapticFeedback` type the code under test fires, in order
/// (e.g. `HapticFeedbackType.lightImpact`). The channel is released again when
/// the test ends.
List<String?> captureHaptics() {
  final log = <String?>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') {
      log.add(call.arguments as String?);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return log;
}
