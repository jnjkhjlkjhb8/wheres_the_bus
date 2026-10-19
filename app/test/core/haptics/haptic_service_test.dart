import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/haptics/haptic_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tap actions deliver their distinct platform feedback kinds', (
    tester,
  ) async {
    final probe = _OwnedHapticProbe(tester.binding.clock.now);
    try {
      await HapticService.instance.lightTap();
      await HapticService.instance.mediumTap();
      await HapticService.instance.heavyTap();
      await HapticService.instance.selectionClick();
      expect(probe.kinds, [
        'HapticFeedbackType.lightImpact',
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.heavyImpact',
        'HapticFeedbackType.selectionClick',
      ]);
    } finally {
      probe.dispose();
    }
  });

  testWidgets('the lead warning delivers two medium pulses 90ms apart', (
    tester,
  ) async {
    final probe = _OwnedHapticProbe(tester.binding.clock.now);
    final pulse = HapticService.instance.shortAlightPulse()..ignore();
    try {
      await tester.pump();
      expect(probe.kinds, ['HapticFeedbackType.mediumImpact']);
      await probe.pump(tester, const Duration(milliseconds: 89));
      expect(probe.kinds, ['HapticFeedbackType.mediumImpact']);
      await probe.pump(tester, const Duration(milliseconds: 1));
      await pulse;
      expect(probe.kinds, [
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.mediumImpact',
      ]);
      expect(
        probe.events.last.at.difference(probe.events.first.at),
        const Duration(milliseconds: 90),
      );
    } finally {
      try {
        await probe.pump(tester, const Duration(milliseconds: 90));
        await pulse;
      } finally {
        probe.dispose();
      }
    }
  });

  testWidgets('the alight warning maintains cadence and stops naturally', (
    tester,
  ) async {
    final probe = _OwnedHapticProbe(tester.binding.clock.now);
    try {
      HapticService.instance.longAlightPulse(now: tester.binding.clock.now);
      expect(probe.kinds, ['HapticFeedbackType.heavyImpact']);
      await probe.pump(tester, const Duration(milliseconds: 129));
      expect(probe.events, hasLength(1));
      await probe.pump(tester, const Duration(milliseconds: 1));
      expect(probe.events, hasLength(2));
      await probe.pump(tester, const Duration(milliseconds: 1470));
      expect(probe.events, hasLength(13));
      expect(probe.kinds, everyElement('HapticFeedbackType.heavyImpact'));
      for (var index = 1; index < probe.events.length; index++) {
        expect(
          probe.events[index].at.difference(probe.events[index - 1].at),
          const Duration(milliseconds: 130),
        );
      }
      expect(
        probe.events.last.at.difference(probe.events.first.at),
        const Duration(milliseconds: 1560),
      );
      await probe.pump(tester, const Duration(milliseconds: 90));
      expect(probe.events, hasLength(13));
      await probe.pump(tester, const Duration(seconds: 1));
      expect(probe.events, hasLength(13));
    } finally {
      probe.dispose();
    }
  });

  testWidgets('stopping cancels pending pulses and permits a fresh warning', (
    tester,
  ) async {
    final probe = _OwnedHapticProbe(tester.binding.clock.now);
    try {
      HapticService.instance.stopAlightPulse();
      HapticService.instance.longAlightPulse(now: tester.binding.clock.now);
      await probe.pump(tester, const Duration(milliseconds: 130));
      expect(probe.events, hasLength(2));
      HapticService.instance.stopAlightPulse();
      HapticService.instance.stopAlightPulse();
      await probe.pump(tester, const Duration(milliseconds: 650));
      expect(probe.events, hasLength(2));
      HapticService.instance.longAlightPulse(now: tester.binding.clock.now);
      expect(probe.events, hasLength(3));
      await probe.pump(tester, const Duration(milliseconds: 130));
      expect(probe.events, hasLength(4));
      HapticService.instance.stopAlightPulse();
      await probe.pump(tester, const Duration(seconds: 1));
      expect(probe.events, hasLength(4));
      expect(probe.kinds, everyElement('HapticFeedbackType.heavyImpact'));
    } finally {
      probe.dispose();
    }
  });

  testWidgets('restarting replaces the previous pulse schedule and deadline', (
    tester,
  ) async {
    final probe = _OwnedHapticProbe(tester.binding.clock.now);
    try {
      final start = tester.binding.clock.now();
      HapticService.instance.longAlightPulse(now: tester.binding.clock.now);
      await probe.pump(tester, const Duration(milliseconds: 65));
      HapticService.instance.longAlightPulse(now: tester.binding.clock.now);
      expect(probe.events, hasLength(2));
      await probe.pump(tester, const Duration(milliseconds: 65));
      expect(probe.events, hasLength(2));
      await probe.pump(tester, const Duration(milliseconds: 65));
      expect(probe.events, hasLength(3));
      expect(
        probe.events.map((event) => event.at.difference(start)),
        [
          Duration.zero,
          const Duration(milliseconds: 65),
          const Duration(milliseconds: 195),
        ],
      );
      await probe.pump(tester, const Duration(milliseconds: 1430));
      expect(probe.events, hasLength(14));
      await probe.pump(tester, const Duration(milliseconds: 130));
      expect(probe.events, hasLength(14));
      await probe.pump(tester, const Duration(milliseconds: 500));
      expect(probe.events, hasLength(14));
      expect(probe.kinds, everyElement('HapticFeedbackType.heavyImpact'));
    } finally {
      probe.dispose();
    }
  });
}

class _OwnedHapticProbe {
  _OwnedHapticProbe(this.now) {
    expect(
      messenger.checkMockMessageHandler(SystemChannels.platform.name, null),
      isTrue,
    );
    HapticService.instance.stopAlightPulse();
    messenger.setMockMethodCallHandler(SystemChannels.platform, handler);
  }

  final DateTime Function() now;
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final events = <({Object? kind, DateTime at})>[];
  late final Future<Object?> Function(MethodCall) handler = _handle;
  bool pulseCeilingExceeded = false;

  Iterable<Object?> get kinds => events.map((event) => event.kind);

  Future<Object?> _handle(MethodCall call) async {
    expectSync(call.method, 'HapticFeedback.vibrate');
    events.add((kind: call.arguments, at: now()));
    if (events.length > 64) {
      pulseCeilingExceeded = true;
      HapticService.instance.stopAlightPulse();
    }
    return null;
  }

  Future<void> pump(WidgetTester tester, Duration duration) async {
    await tester.pump(duration);
    expect(
      pulseCeilingExceeded,
      isFalse,
      reason: 'A finite haptic warning must not produce an unbounded burst.',
    );
  }

  void dispose() {
    try {
      HapticService.instance.stopAlightPulse();
    } finally {
      final ownsHandler = messenger.checkMockMessageHandler(
        SystemChannels.platform.name,
        handler,
      );
      try {
        expect(ownsHandler, isTrue);
      } finally {
        if (ownsHandler) {
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        }
      }
    }
  }
}
