import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/lifecycle/app_network.dart';

class _FakeConnectivity extends Fake implements Connectivity {
  _FakeConnectivity({
    this.initial = const [ConnectivityResult.wifi],
    this.initialError,
  });

  final List<ConnectivityResult> initial;
  final Object? initialError;
  final changes = StreamController<List<ConnectivityResult>>.broadcast();
  var checks = 0;

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => changes.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    checks++;
    final error = initialError;
    if (error != null) throw error;
    return initial;
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(AppNetwork.reset);
  tearDown(AppNetwork.reset);

  test('starts optimistic before anything is reported', () {
    expect(AppNetwork.online.value, isTrue);
  });

  test('the first reading is the platform connectivity check', () async {
    final source = _FakeConnectivity(initial: [ConnectivityResult.none]);
    AppNetwork.start(connectivity: source);
    await _settle();
    expect(source.checks, 1);
    expect(AppNetwork.online.value, isFalse);
  });

  test('any real transport counts as online, none and empty do not', () async {
    final source = _FakeConnectivity();
    AppNetwork.start(connectivity: source);
    await _settle();
    expect(AppNetwork.online.value, isTrue);

    source.changes.add([ConnectivityResult.none]);
    await _settle();
    expect(AppNetwork.online.value, isFalse);

    source.changes.add([ConnectivityResult.none, ConnectivityResult.mobile]);
    await _settle();
    expect(AppNetwork.online.value, isTrue);

    source.changes.add(const []);
    await _settle();
    expect(AppNetwork.online.value, isFalse);

    source.changes.add([ConnectivityResult.ethernet]);
    await _settle();
    expect(AppNetwork.online.value, isTrue);
  });

  test('starting twice keeps the first source', () async {
    final first = _FakeConnectivity();
    final second = _FakeConnectivity(initial: [ConnectivityResult.none]);
    AppNetwork.start(connectivity: first);
    AppNetwork.start(connectivity: second);
    await _settle();
    expect(second.checks, 0);
    expect(second.changes.hasListener, isFalse);
    expect(first.changes.hasListener, isTrue);
    expect(AppNetwork.online.value, isTrue);
  });

  test('a stream error leaves the app online', () async {
    final source = _FakeConnectivity();
    AppNetwork.start(connectivity: source);
    await _settle();
    source.changes.add([ConnectivityResult.none]);
    await _settle();
    expect(AppNetwork.online.value, isFalse);

    source.changes.addError(StateError('platform cannot report'));
    await _settle();
    expect(AppNetwork.online.value, isTrue);
  });

  test('a failing first check leaves the app online', () async {
    final source = _FakeConnectivity(initialError: StateError('unsupported'));
    AppNetwork.online.value = false;
    AppNetwork.start(connectivity: source);
    await _settle();
    expect(source.checks, 1);
    expect(AppNetwork.online.value, isTrue);
  });

  test('reset goes back online, stops listening and allows a new start', () async {
    final source = _FakeConnectivity(initial: [ConnectivityResult.none]);
    AppNetwork.start(connectivity: source);
    await _settle();
    expect(AppNetwork.online.value, isFalse);

    AppNetwork.reset();
    await _settle();
    expect(AppNetwork.online.value, isTrue);
    expect(source.changes.hasListener, isFalse);

    final next = _FakeConnectivity();
    AppNetwork.start(connectivity: next);
    await _settle();
    expect(next.changes.hasListener, isTrue);
    expect(next.checks, 1);
  });
}
