import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';

void _resume(WidgetsBinding binding) {
  switch (binding.lifecycleState) {
    case AppLifecycleState.resumed:
      return;
    case AppLifecycleState.paused:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case AppLifecycleState.hidden:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
    case null || AppLifecycleState.inactive || AppLifecycleState.detached:
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      return;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppForeground.reset();
    _resume(binding);
  });
  tearDown(() {
    AppForeground.reset();
    _resume(binding);
  });

  test(
    'lifecycle events keep inactive visible and background states hidden',
    () {
      AppForeground.start();
      expect(AppForeground.value.value, isTrue);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(AppForeground.value.value, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(AppForeground.value.value, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(AppForeground.value.value, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      expect(AppForeground.value.value, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(AppForeground.value.value, isTrue);
    },
  );

  test('repeated start stays disposable and reset permits observing again', () {
    AppForeground.start();
    AppForeground.start();
    binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(AppForeground.value.value, isFalse);

    AppForeground.reset();
    expect(AppForeground.value.value, isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(AppForeground.value.value, isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(AppForeground.value.value, isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    AppForeground.start();
    binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(AppForeground.value.value, isFalse);
    binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
      ..handleAppLifecycleStateChanged(AppLifecycleState.detached)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(AppForeground.value.value, isTrue);
  });
}
