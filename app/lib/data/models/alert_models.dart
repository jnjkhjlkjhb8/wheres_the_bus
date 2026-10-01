import 'package:equatable/equatable.dart';

enum AlertSeverity { red, yellow, green }

enum AlertSourceKind { metro, busAlert, tra, thsr, appNotice }

/// What a notice *is*, independent of how loud it is. Derived from the source
/// rather than stored, so a row can never disagree with the stream it came
/// from.
enum NoticeKind {
  /// Something is broken or degraded right now.
  disruption,

  /// Ops-authored: maintenance windows and app announcements.
  announcement,
}

/// How loud a notice is allowed to be. The one input to notice coloring;
/// see `app/theme/notice_tone.dart` for the resolved colors.
enum NoticeTone { critical, caution, info, neutral }

/// Origin of an alert: the domain plus the operator/region code the stream was
/// opened with (e.g. metro `TRTC`, bus `Taipei`). Rail kinds carry an empty
/// code since their streams are nationwide.
class AlertSource extends Equatable {
  const AlertSource(this.kind, [this.code = '']);

  final AlertSourceKind kind;
  final String code;

  @override
  List<Object?> get props => [kind, code];
}

typedef AlertSourceId = AlertSource;

class AlertViewModel extends Equatable {
  const AlertViewModel({
    required this.message,
    required this.level,
    this.routeType = '',
    this.routeKeys = const [],
    this.title,
    this.time,
    this.source,
    this.department,
  });

  final String message;
  final AlertSeverity level;

  /// Transit type this alert belongs to (`bus`, `mrt`, `tra`, `thsr`).
  final String routeType;

  /// Route identities the alert is scoped to. Empty means it names no route
  /// and applies system-wide.
  final List<String> routeKeys;

  /// Optional headline distinct from [message]; may be null.
  final String? title;

  /// When the alert was published/updated, if the feed provided it.
  final DateTime? time;

  /// Which system and operator the alert came from, if known.
  final AlertSource? source;

  /// TDX's own publishing department for this alert, verbatim (e.g.
  /// "臺北市公共運輸處"), when the feed carries one.
  final String? department;

  /// What this notice is. Derived from [source] so it can never disagree with
  /// the stream the row came from.
  NoticeKind get kind => switch (source?.kind) {
    AlertSourceKind.appNotice => NoticeKind.announcement,
    _ => NoticeKind.disruption,
  };

  /// How loud this notice may be. Severity only decides tone for disruptions:
  /// announcements are never critical no matter what level the feed puts on
  /// them.
  NoticeTone get tone => switch (kind) {
    NoticeKind.announcement => NoticeTone.info,
    NoticeKind.disruption =>
      level == AlertSeverity.red ? NoticeTone.critical : NoticeTone.caution,
  };

  /// Whether this is something happening now (the 進行中 group) rather than
  /// something to read (the 訊息 group). Resolved disruptions stop being
  /// published, so they leave the group on their own.
  bool get ongoing => kind == NoticeKind.disruption;

  bool matchesScope(Set<String> scope) =>
      routeKeys.isEmpty ||
      routeKeys.any((key) => scope.contains('$routeType:$key'));

  // [message] stays the sole identity, so enriching a row with
  // title/time/source/scope must not change equality.
  @override
  List<Object?> get props => [message];
}
