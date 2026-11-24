import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:wheres_the_bus/shared/widgets/ui_kit_host.dart';

/// True on the platform whose controls UIKit draws for this app.
bool get usesUiKitControls => defaultTargetPlatform == TargetPlatform.iOS;

/// Marks a subtree as sitting on a UIKit navigation bar, where an action
/// should be a system button rather than a drawn one so it matches the bar's
/// own back button.
class UiKitBarScope extends StatelessWidget {
  const UiKitBarScope({required this.child, super.key});

  final Widget child;

  // An ancestor lookup, not an InheritedWidget: the scope never changes, so
  // nothing needs rebuilding when it does.
  static bool of(BuildContext context) =>
      context.findAncestorWidgetOfExactType<UiKitBarScope>() != null;

  @override
  Widget build(BuildContext context) => child;
}

/// A real UIDatePicker in wheel style, time only, 24-hour.
class NativeTimeWheel extends StatelessWidget {
  const NativeTimeWheel({
    required this.initial,
    required this.onChanged,
    super.key,
  });

  final TimeOfDay initial;
  final ValueChanged<TimeOfDay> onChanged;

  static const viewType = 'me.rabbitsayhello.wheresthebus/native_time_wheel';

  @override
  Widget build(BuildContext context) => UiKitHost(
    viewType: viewType,
    // The wheel lives in a draggable sheet, whose drag would take its swipes.
    claimGestures: true,
    params: {
      'hour': initial.hour,
      'minute': initial.minute,
      'dark': Theme.of(context).brightness == Brightness.dark,
    },
    onEvent: (method, arguments) {
      if (method == 'changed' && arguments is Map) {
        onChanged(
          TimeOfDay(
            hour: arguments['hour'] as int,
            minute: arguments['minute'] as int,
          ),
        );
      }
    },
  );
}

/// A real UIButton showing one SF Symbol, in the system's bar-button look
/// (a Liquid Glass circle on iOS 26).
class NativeIconButton extends StatelessWidget {
  const NativeIconButton({
    required this.symbol,
    required this.label,
    required this.onTap,
    this.prominent = false,
    super.key,
  });

  /// SF Symbol name.
  final String symbol;

  /// Read by VoiceOver.
  final String label;
  final VoidCallback onTap;

  /// Filled, for an action that is currently on.
  final bool prominent;

  static const viewType = 'me.rabbitsayhello.wheresthebus/native_icon_button';

  static const double dimension = 44;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: dimension,
      child: UiKitHost(
        viewType: viewType,
        params: {
          'symbol': symbol,
          'label': label,
          'prominent': prominent,
          // A prominent glass button fills with its tint; the app's ink would
          // put a white glyph on a white plate in dark mode.
          'tint': prominent ? null : cs.onSurface.toARGB32(),
          'dark': cs.brightness == Brightness.dark,
        },
        onEvent: (method, _) {
          if (method == 'tap') onTap();
        },
      ),
    );
  }
}
