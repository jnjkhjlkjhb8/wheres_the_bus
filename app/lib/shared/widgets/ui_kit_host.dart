import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Hosts one UIKit control as a platform view and keeps it in step with
/// [params]. iOS only; callers decide when to build it.
///
/// The native side registers a factory under [viewType], reads [params] at
/// creation, takes later ones through an `update` call on the view's own
/// channel (`<viewType>_<id>`), and reports user input back on that channel,
/// which arrives here as [onEvent].
class UiKitHost extends StatefulWidget {
  const UiKitHost({
    required this.viewType,
    required this.params,
    this.onEvent,
    this.claimGestures = false,
    super.key,
  });

  final String viewType;
  final Map<String, Object?> params;
  final void Function(String method, Object? arguments)? onEvent;

  /// Gives every touch to the UIKit view. Needed inside a draggable sheet or
  /// scrollable, whose own drag would otherwise take a wheel's swipes.
  final bool claimGestures;

  @override
  State<UiKitHost> createState() => _UiKitHostState();
}

class _UiKitHostState extends State<UiKitHost> {
  static final _eager = <Factory<OneSequenceGestureRecognizer>>{
    const Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
  };

  MethodChannel? _channel;
  Map<String, Object?> _sent = const {};

  void _push() => unawaited(_channel?.invokeMethod<void>('update', _sent));

  /// UIKit reads creation params once, so later changes are pushed to the
  /// view instead of rebuilding it, which would flash.
  void _sync() {
    if (mapEquals(widget.params, _sent)) return;
    _sent = widget.params;
    _push();
  }

  void _onCreated(int id) {
    _channel = MethodChannel('${widget.viewType}_$id')
      ..setMethodCallHandler(_onCall);
    // Covers a change that landed while UIKit was still creating the view.
    _push();
  }

  Future<void> _onCall(MethodCall call) async =>
      widget.onEvent?.call(call.method, call.arguments);

  @override
  void dispose() {
    // The native view is gone with this widget; a handler left behind would
    // keep the page's context alive under a channel name nothing sends on.
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Every input reaches here as a rebuild, so this is the one place that
    // sees them all; it sends only when something changed.
    _sync();
    return UiKitView(
      viewType: widget.viewType,
      creationParams: _sent,
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onCreated,
      gestureRecognizers: widget.claimGestures ? _eager : null,
    );
  }
}
