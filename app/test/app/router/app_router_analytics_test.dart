import 'package:firebase_analytics_platform_interface/firebase_analytics_platform_interface.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wheres_the_bus/app/router/app_router.dart';

class _Analytics extends FirebaseAnalyticsPlatform {
  final screens = <String?>[];

  @override
  FirebaseAnalyticsPlatform delegateFor({
    required FirebaseApp app,
    Map<String, dynamic>? webOptions,
  }) => this;

  @override
  Future<void> logEvent({
    required String name,
    Map<String, Object?>? parameters,
    AnalyticsCallOptions? callOptions,
  }) async {
    expect(name, 'screen_view');
    screens.add(parameters?['screen_name'] as String?);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('route graph builds before Firebase core has initialized', () {
    expect(
      () => buildAppRoutes(firebaseEnabled: true),
      returnsNormally,
    );
  });

  test(
    'deferred route observer starts reporting once Firebase initializes',
    () async {
      final analytics = _Analytics();
      final original = FirebaseAnalyticsPlatform.instance;
      FirebaseAnalyticsPlatform.instance = analytics;
      addTearDown(() => FirebaseAnalyticsPlatform.instance = original);
      setupFirebaseCoreMocks();
      final shell = buildAppRoutes(
        firebaseEnabled: true,
      ).whereType<StatefulShellRoute>().single;
      final observer = shell.branches.single.observers!.single;
      MaterialPageRoute<void> route(String name) => MaterialPageRoute<void>(
        settings: RouteSettings(name: name),
        builder: (_) => const SizedBox.shrink(),
      );
      final home = route('/');
      final search = route('/search');
      final settings = route('/settings');
      observer.didPush(home, null);
      await Future<void>.delayed(Duration.zero);
      expect(analytics.screens, isEmpty);
      await Firebase.initializeApp();
      observer
        ..didPush(search, home)
        ..didReplace(newRoute: settings, oldRoute: search)
        ..didPop(settings, home);
      await Future<void>.delayed(Duration.zero);
      expect(analytics.screens, ['/search', '/settings', '/']);
    },
  );
}
