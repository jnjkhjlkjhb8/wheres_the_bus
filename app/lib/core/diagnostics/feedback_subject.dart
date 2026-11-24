import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// What the rider is looking at, in words they would use: 「307 · 往 板橋」,
/// 「臺北車站(鄭州)」. A report opened from that page names it back to them.
///
/// A stack, not a single value: a page pushed on top names itself, and when it
/// is popped the page underneath is the subject again without rebuilding. The
/// map keeps claim order, so its last entry is the innermost page.
abstract final class FeedbackSubject {
  static final Map<Object, String> _claims = {};

  static String? get current => _claims.isEmpty ? null : _claims.values.last;

  @visibleForTesting
  static void reset() => _claims.clear();
}

/// Names [label] as the report subject for as long as this widget is mounted.
/// An empty label (a page still loading its name) claims nothing.
class FeedbackSubjectScope extends StatefulWidget {
  const FeedbackSubjectScope({
    required this.label,
    required this.child,
    super.key,
  });

  final String label;
  final Widget child;

  @override
  State<FeedbackSubjectScope> createState() => _FeedbackSubjectScopeState();
}

class _FeedbackSubjectScopeState extends State<FeedbackSubjectScope> {
  @override
  void dispose() {
    FeedbackSubject._claims.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Claimed here rather than in a lifecycle hook: a rename is a rebuild, and
    // nothing listens to the subject, so writing it during build is safe.
    if (widget.label.isEmpty) {
      FeedbackSubject._claims.remove(this);
    } else {
      FeedbackSubject._claims[this] = widget.label;
    }
    return widget.child;
  }
}
