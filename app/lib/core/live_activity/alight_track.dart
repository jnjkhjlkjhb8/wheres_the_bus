import 'package:flutter/services.dart';

/// Which transit network the tracked vehicle belongs to. Selects the tracker
/// glyph on the platform card; nothing else about the card varies by mode.
enum AlightTrackMode { bus, tra, thsr, metro }

enum AlightTrackPhase {
  /// Not yet aboard. Progress sits at the board stop and the chip counts
  /// minutes, not stops. This is the MaaS pre-board leg, folded in.
  waiting,

  /// Aboard and travelling toward the alight stop.
  riding,

  /// Past the rider's own 提前站數 threshold — the same moment the vibration
  /// fires. Colour, not a new card.
  approaching,

  /// Terminal: reached the alight stop.
  arrived,

  /// Terminal: the vehicle binding was lost or went stale.
  lost,
}

class AlightTrackContent {
  const AlightTrackContent({
    required this.mode,
    required this.phase,
    required this.vehicleLabel,
    required this.boardStation,
    required this.targetStation,
    required this.nextStation,
    required this.hopCount,
    required this.currentIndex,
    required this.remainingStops,
    required this.leadStops,
    this.vehicleId,
    this.etaMs,
    this.etaMinutes,
    this.walkMinutes = 0,
    this.scheduledDepartureMs,
    this.delayMinutes = 0,
    this.lineCode,
    this.lineColorHex,
    this.trackId,
  });

  final AlightTrackMode mode;
  final AlightTrackPhase phase;

  /// Route or train identity as the rider reads it: `307`, `自強 408`,
  /// `高鐵 663`, `板南線`.
  final String vehicleLabel;

  /// The specific vehicle within that route — plate, or the metro carID.
  /// Null when the session tracks a route rather than one vehicle.
  final String? vehicleId;

  final String boardStation;

  /// 下車站 — the whole point of the session.
  final String targetStation;

  final String nextStation;

  /// Segments on the progress bar: one per hop from board to target. Always
  /// at least 1, so the bar never collapses to nothing.
  final int hopCount;

  /// Hops already completed, `0..hopCount`.
  final int currentIndex;

  final int remainingStops;

  /// The rider's own 提前站數. Doubles as the colour threshold: at
  /// `remainingStops <= leadStops` the bar turns amber, which is the same
  /// moment the reminder vibrates. One number, one definition of "close".
  final int leadStops;

  /// Absolute arrival time, for iOS's Live Activity — ActivityKit renders its
  /// own live timer and needs a target date to do it. Null once stops carry
  /// the reading.
  final int? etaMs;

  final int? etaMinutes;

  /// Walk to the board stop, minutes. Only meaningful while
  /// [AlightTrackPhase.waiting]; 0 everywhere else.
  final int walkMinutes;

  final int? scheduledDepartureMs;
  final int delayMinutes;

  final String? lineCode;
  final String? lineColorHex;

  final String? trackId;

  /// Marks a device-local session id (see [trackId]). Mirrored on the platform
  /// side as `TrackNotification.LOCAL_TRACK_PREFIX`.
  static const localTrackIdPrefix = 'local-';

  Map<String, Object?> toArgs() => {
    'mode': mode.name,
    'phase': phase.name,
    'vehicleLabel': vehicleLabel,
    'vehicleId': vehicleId,
    'boardStation': boardStation,
    'targetStation': targetStation,
    'nextStation': nextStation,
    'hopCount': hopCount,
    'currentIndex': currentIndex,
    'remainingStops': remainingStops,
    'leadStops': leadStops,
    'etaMs': etaMs,
    'etaMinutes': etaMinutes,
    'walkMinutes': walkMinutes,
    'scheduledDepartureMs': scheduledDepartureMs,
    'delayMinutes': delayMinutes,
    'lineCode': lineCode,
    'lineColorHex': lineColorHex,
    'trackId': trackId,
  };
}

class AlightTrackChannel {
  static const _channel = MethodChannel('com.wheres.bus/live_activity');

  static const _opTimeout = Duration(seconds: 3);

  static bool _permissionRequested = false;

  static Future<void> requestNotificationPermission() async {
    _permissionRequested = true;
    try {
      await _channel
          .invokeMethod<bool>('requestNotificationPermission')
          .timeout(_opTimeout);
    } on Exception {
      // Denied, unimplemented, or unanswered — all three mean the same thing
      // here: start the session anyway.
    }
  }

  static Future<bool> notificationsEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('notificationsEnabled') ?? true;
    } on Exception {
      return true;
    }
  }

  /// Opens the system's notification settings for this app. The only way back
  /// once the runtime prompt has been refused — the system stops offering it.
  static Future<void> openNotificationSettings() async {
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } on Exception {
      // Nothing to fall back to, and nothing worth interrupting the rider for.
    }
  }

  int _nextLease = 0;
  int? _activeLease;
  Future<void> _queue = Future<void>.value();

  Future<int> start(AlightTrackContent content) async {
    final lease = ++_nextLease;
    // Ahead of the queue, not inside it: the rider may take as long as they
    // like over the system dialog, and that wait must not count against the
    // card's own command timeout.
    if (!_permissionRequested) await requestNotificationPermission();
    await _enqueue(() async {
      _activeLease = lease;
      try {
        await _channel.invokeMethod<String>('start', content.toArgs());
      } on PlatformException {
        _releaseIfCurrent(lease);
      } on MissingPluginException {
        _releaseIfCurrent(lease);
      }
    });
    return lease;
  }

  Future<void> update(int lease, AlightTrackContent content) {
    return _enqueue(() async {
      if (!_isActive(lease)) return; // stale: superseded before this ran
      try {
        await _channel.invokeMethod<void>('update', content.toArgs());
      } on PlatformException {
        // keep session alive; next update retries
      } on MissingPluginException {
        _releaseIfCurrent(lease);
      }
    });
  }

  Future<void> stop(int lease) {
    return _enqueue(() async {
      if (!_isActive(lease)) return; // stale: already superseded
      _activeLease = null;
      try {
        await _channel.invokeMethod<void>('stop');
      } on PlatformException {
        // already gone — nothing to clean up
      } on MissingPluginException {
        // no-op
      }
    });
  }

  Future<void> stopAny() {
    return _enqueue(() async {
      _activeLease = null;
      try {
        await _channel.invokeMethod<void>('stop');
      } on PlatformException {
        // already gone — nothing to clean up
      } on MissingPluginException {
        // no-op
      }
    });
  }

  bool _isActive(int lease) => _activeLease == lease;

  void _releaseIfCurrent(int lease) {
    if (_activeLease == lease) _activeLease = null;
  }

  Future<void> _enqueue(Future<void> Function() op) {
    final result = _queue.then(
      (_) => op().timeout(_opTimeout, onTimeout: () {}),
    );
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }
}
