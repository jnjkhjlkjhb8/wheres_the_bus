import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';
import 'package:wheres_the_bus/core/firebase/install_identity.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';
import 'package:wheres_the_bus/core/lifecycle/app_foreground.dart';
import 'package:wheres_the_bus/core/powersync/local_db.dart';
import 'package:wheres_the_bus/core/powersync/powersync_health.dart';

const String _envPowersyncUrl = String.fromEnvironment(
  'POWERSYNC_URL',
);

const _schema = Schema([
  Table('mrt_journey_matrix', [
    Column.text('from_station_id'),
    Column.text('to_station_id'),
    Column.text('system'),
    Column.integer('fare_nt'),
    Column.integer('half_fare_nt'),
    Column.integer('travel_time_min'),
  ]),
  Table('mrt_schedule', [
    Column.text('station_id'),
    Column.text('lineid'),
    Column.text('destinationstaionid'),
    Column.integer('serviceday'),
    Column.text('system'),
    Column.text('first_train_time'),
    Column.text('last_train_time'),
  ]),
]);

/// Builds the on-disk [PowerSyncDatabase]. Overridable in tests via
/// [PowerSyncService.forTesting] since the real factory needs
/// `path_provider`, which has no platform binding under `flutter test`.
typedef PowerSyncDatabaseFactory = Future<PowerSyncDatabase> Function();

class PowerSyncService implements LocalDb {
  PowerSyncService._(this._dbFactory);

  /// Constructs an isolated instance for unit tests. Never share this with
  /// [instance]: it exists so tests can exercise the memoization/StateError
  /// contract without touching real platform channels.
  @visibleForTesting
  factory PowerSyncService.forTesting({PowerSyncDatabaseFactory? dbFactory}) =>
      PowerSyncService._(dbFactory ?? _defaultDbFactory);

  static final PowerSyncService instance = PowerSyncService._(
    _defaultDbFactory,
  );

  static Future<PowerSyncDatabase> _defaultDbFactory() async {
    final dir = await getApplicationDocumentsDirectory();
    return PowerSyncDatabase(
      schema: _schema,
      path: p.join(dir.path, 'bus_local.db'),
    );
  }

  final PowerSyncDatabaseFactory _dbFactory;
  final _health = PowerSyncHealth<SyncStatus>(
    errorOf: (status) => status.downloadError ?? status.uploadError,
    onError: CrashReporter.record,
    freshnessOf: (status) => status.lastSyncedAt,
  );

  /// Most recent successful PowerSync sync, or `null` before the first sync
  /// completes (or before [init] runs). Drives the "資料來源" freshness row
  /// in Settings instead of a hardcoded timestamp (F46).
  DateTime? get lastSyncedAt => _health.lastSyncedAt;

  PowerSyncDatabase? _db;
  Future<void>? _initFuture;

  Future<void> init() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _doInit();
    _initFuture = future;
    unawaited(
      future.catchError((Object _, StackTrace _) {
        _initFuture = null;
      }),
    );
    return future;
  }

  Future<void> _doInit() async {
    final db = await _dbFactory();
    await db.initialize();
    _health.listen(db.statusStream);
    _db = db;
    AppForeground.value.addListener(_handleForeground);
    await _connect(db);
  }

  /// Opens the sync connection, if it isn't open already. Doing nothing on a
  /// failed credential fetch is the offline case, and is why this has to be
  /// retryable rather than a one-shot step of [_doInit].
  Future<void> _connect(PowerSyncDatabase db) async {
    if (_envPowersyncUrl.isEmpty || db.connected) return;
    try {
      final connector = CachedPowerSyncConnector();
      final creds = await connector.fetchCredentials();
      if (creds != null) {
        await db.connect(connector: connector);
      }
    } on Object catch (e, s) {
      CrashReporter.record(e, s);
      if (kDebugMode) {
        debugPrint(
          '[PowerSync] Connect: failed to fetch credentials, running offline',
        );
      }
    }
  }

  void _handleForeground() {
    if (!AppForeground.value.value) return;
    final db = _db;
    if (db != null) unawaited(_connect(db));
  }

  /// Resolves once initialization has completed, then returns [db]. Prefer
  /// this over `init().then((_) => db)` at call sites — it also joins an
  /// already-in-flight init instead of starting a second one.
  Future<PowerSyncDatabase> get readyDb async {
    await init();
    return db;
  }

  /// The initialized database. Guarded by an explicit [StateError] rather
  /// than `assert` (F15): `assert` is stripped in release builds, which
  /// would otherwise let a release build dereference an unset `_db`.
  PowerSyncDatabase get db {
    final db = _db;
    if (db == null) {
      throw StateError('PowerSyncService.init() must complete before db');
    }
    return db;
  }

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    final result = await db.getAll(sql, parameters);
    // Detach rows from the sqlite ResultSet so callers hold plain maps.
    return [for (final row in result) Map<String, dynamic>.of(row)];
  }

  Future<void> close() async {
    AppForeground.value.removeListener(_handleForeground);
    await _health.cancel();
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
    _initFuture = null;
  }
}

typedef PowerSyncCredentialFetch = Future<PowerSyncCredentials?> Function();
typedef PowerSyncClock = DateTime Function();

class CachedPowerSyncConnector extends PowerSyncBackendConnector {
  CachedPowerSyncConnector({
    PowerSyncCredentialFetch? fetch,
    PowerSyncClock? clock,
  }) : _fetch = fetch ?? _fetchFromRouter,
       _clock = clock ?? DateTime.now;

  final PowerSyncCredentialFetch _fetch;
  final PowerSyncClock _clock;
  PowerSyncCredentials? _credentials;
  DateTime? _credentialsExpireAt;
  Future<PowerSyncCredentials?>? _fetching;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final cached = _credentials;
    final expiresAt = _credentialsExpireAt;
    if (cached != null &&
        expiresAt != null &&
        _clock().isBefore(expiresAt.subtract(const Duration(minutes: 1)))) {
      return cached;
    }

    final fetching = _fetching;
    if (fetching != null) return fetching;
    final request = _refreshCredentials();
    _fetching = request;
    try {
      return await request;
    } finally {
      if (identical(_fetching, request)) _fetching = null;
    }
  }

  Future<PowerSyncCredentials?> _refreshCredentials() async {
    final credentials = await _fetch();
    final expiresAt = credentials == null
        ? null
        : _jwtExpiry(credentials.token);
    if (credentials != null && expiresAt != null) {
      _credentials = credentials;
      _credentialsExpireAt = expiresAt;
    } else {
      _credentials = null;
      _credentialsExpireAt = null;
    }
    return credentials;
  }

  static DateTime? _jwtExpiry(String token) {
    final segments = token.split('.');
    if (segments.length != 3) return null;
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))),
      );
      if (payload is! Map) return null;
      final expiry = payload['exp'];
      if (expiry is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        expiry.toInt() * Duration.millisecondsPerSecond,
      );
    } on FormatException {
      return null;
    }
  }

  static Future<PowerSyncCredentials?> _fetchFromRouter() async {
    if (_envPowersyncUrl.isEmpty) return null;
    try {
      final installId = await InstallIdentity.getOrCreate();
      final res = await HttpClient.instance.dio.get<Map<String, dynamic>>(
        '/api/token/powersync',
        options: Options(headers: {'X-Install-Id': installId}),
      );
      final token = res.data?['token'] as String?;
      if (token == null) return null;
      return PowerSyncCredentials(endpoint: _envPowersyncUrl, token: token);
    } on Object catch (e, s) {
      CrashReporter.record(e, s);
      return null;
    }
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    if (kDebugMode) debugPrint('[PowerSync] uploadData (no-op)');
  }
}
