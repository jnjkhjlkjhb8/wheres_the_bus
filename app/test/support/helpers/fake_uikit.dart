import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for UIKit's side of platform views and of each view's own method
/// channel (`<viewType>_<id>`), recording what Dart sends. Pass [viewType] to
/// see only that type's views in [created]; every type is hosted either way.
class FakeUiKit {
  FakeUiKit([this.viewType]) {
    _messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final args = call.arguments as Map<Object?, Object?>;
        _all.add(args);
        _messenger.setMockMethodCallHandler(_channel(args), (call) {
          calls.add(call);
          return null;
        });
      }
      return null;
    });
    addTearDown(() {
      _messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      for (final view in _all) {
        _messenger.setMockMethodCallHandler(_channel(view), null);
      }
    });
  }

  final String? viewType;
  final _all = <Map<Object?, Object?>>[];

  /// `create` arguments, one entry per platform view Dart asked for.
  List<Map<Object?, Object?>> get created => [
    for (final view in _all)
      if (viewType == null || view['viewType'] == viewType) view,
  ];

  /// Method calls Dart made on any view's channel.
  final calls = <MethodCall>[];

  static const _codec = StandardMethodCodec();

  TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  static MethodChannel _channel(Map<Object?, Object?> view) =>
      MethodChannel('${view['viewType']}_${view['id']}');

  /// Creation params of the [index]th view, decoded.
  Map<Object?, Object?> creationParams([int index = 0]) =>
      const StandardMessageCodec().decodeMessage(
            ByteData.sublistView(created[index]['params']! as Uint8List),
          )
          as Map<Object?, Object?>;

  /// Arguments of every `update` Dart pushed, oldest first.
  List<Map<Object?, Object?>> get updates => [
    for (final call in calls)
      if (call.method == 'update') call.arguments as Map<Object?, Object?>,
  ];

  /// Sends [method] from the [view]th native view to Dart; false when Dart
  /// has no handler listening on that view's channel.
  Future<bool> send(
    WidgetTester tester,
    String method, {
    Object? arguments,
    int view = 0,
  }) async {
    var handled = false;
    await _messenger.handlePlatformMessage(
      _channel(created[view]).name,
      _codec.encodeMethodCall(MethodCall(method, arguments)),
      (reply) => handled = reply != null,
    );
    await tester.pumpAndSettle();
    return handled;
  }
}

/// [testWidgets] with the platform set to iOS for the body. Reset inside the
/// body: the binding checks the override is cleared before tear-downs run.
void testWidgetsOnIos(String description, WidgetTesterCallback body) =>
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
