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

abstract interface class PowerSyncConnection {
  PowerSyncDatabase get database;
  bool get connected;
  Stream<SyncStatus> get statusStream;
  Future<void> initialize();
  Future<void> connect(PowerSyncBackendConnector connector);
  Future<void> close();
  Future<List<Map<String, dynamic>>> getAll(
    String sql,
    List<Object?> parameters,
  );
}

typedef PowerSyncConnectionFactory = Future<PowerSyncConnection> Function();

class _NativePowerSyncConnection implements PowerSyncConnection {
  _NativePowerSyncConnection(this.database);
  @override
  final PowerSyncDatabase database;
  @override
  bool get connected => database.connected;
  @override
  Stream<SyncStatus> get statusStream => database.statusStream;
  @override
  Future<void> initialize() => database.initialize();
  @override
  Future<void> connect(PowerSyncBackendConnector connector) =>
      database.connect(connector: connector);
  @override
  Future<void> close() => database.close();
  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql,
    List<Object?> parameters,
  ) async {
    final rows = await database.getAll(sql, parameters);
    return [for (final row in rows) Map<String, dynamic>.of(row)];
  }
}

class PowerSyncService implements LocalDb {
  PowerSyncService({
    PowerSyncDatabaseFactory? dbFactory,
    PowerSyncConnectionFactory? connectionFactory,
    PowerSyncBackendConnector Function()? connectorFactory,
    String endpoint = _envPowersyncUrl,
  }) : _connectionFactory =
           connectionFactory ??
           (() async => _NativePowerSyncConnection(
             await (dbFactory ?? _defaultDbFactory)(),
           )),
       _connectorFactory =
           connectorFactory ??
           (() => CachedPowerSyncConnector(endpoint: endpoint)),
       _endpoint = endpoint;

  /// Constructs an isolated instance for unit tests. Never share this with
  /// [instance]: it exists so tests can exercise the memoization/StateError
  /// contract without touching real platform channels.
  @visibleForTesting
  factory PowerSyncService.forTesting({PowerSyncDatabaseFactory? dbFactory}) =>
      PowerSyncService(dbFactory: dbFactory);

  static final PowerSyncService instance = PowerSyncService();

  static Future<PowerSyncDatabase> _defaultDbFactory() async {
    final dir = await getApplicationDocumentsDirectory();
    return PowerSyncDatabase(
      schema: _schema,
      path: p.join(dir.path, 'bus_local.db'),
    );
  }

  final PowerSyncConnectionFactory _connectionFactory;
  final PowerSyncBackendConnector Function() _connectorFactory;
  final String _endpoint;
  final _health = PowerSyncHealth<SyncStatus>(
    errorOf: (status) => status.downloadError ?? status.uploadError,
    onError: CrashReporter.record,
    freshnessOf: (status) => status.lastSyncedAt,
  );

  /// Most recent successful PowerSync sync, or `null` before the first sync
  /// completes (or before [init] runs). Drives the "資料來源" freshness row
  /// in Settings instead of a hardcoded timestamp (F46).
  DateTime? get lastSyncedAt => _health.lastSyncedAt;

  PowerSyncConnection? _connection;
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
    final db = await _connectionFactory();
    await db.initialize();
    _health.listen(db.statusStream);
    _connection = db;
    AppForeground.value.addListener(_handleForeground);
    await _connect(db);
  }

  /// Opens the sync connection, if it isn't open already. Doing nothing on a
  /// failed credential fetch is the offline case, and is why this has to be
  /// retryable rather than a one-shot step of [_doInit].
  Future<void> _connect(PowerSyncConnection db) async {
    if (_endpoint.isEmpty || db.connected) return;
    try {
      await _connectWithCredentials(db);
    } on Object catch (e, s) {
      CrashReporter.record(e, s);
      _logOffline();
    }
  }

  Future<void> _connectWithCredentials(PowerSyncConnection db) async {
    final connector = _connectorFactory();
    if (await connector.fetchCredentials() != null) {
      await db.connect(connector);
    }
  }

  void _logOffline() {
    if (kDebugMode) {
      debugPrint(
        '[PowerSync] Connect: failed to fetch credentials, running offline',
      );
    }
  }

  void _handleForeground() {
    if (!AppForeground.value.value) return;
    final db = _connection;
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
  /// would otherwise let a release build dereference an unset database.
  PowerSyncDatabase get db => _readyConnection.database;

  PowerSyncConnection get _readyConnection {
    final connection = _connection;
    if (connection == null) {
      throw StateError('PowerSyncService.init() must complete before db');
    }
    return connection;
  }

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    return _readyConnection.getAll(sql, parameters);
  }

  Future<void> close() async {
    AppForeground.value.removeListener(_handleForeground);
    await _health.cancel();
    final db = _connection;
    if (db != null) {
      await db.close();
      _connection = null;
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
    String endpoint = _envPowersyncUrl,
  }) : _fetch = fetch ?? (() => _fetchFromRouter(endpoint)),
       _clock = clock ?? DateTime.now;

  final PowerSyncCredentialFetch _fetch;
  final PowerSyncClock _clock;
  PowerSyncCredentials? _credentials;
  DateTime? _credentialsExpireAt;
  Future<PowerSyncCredentials?>? _fetching;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final cached = _freshCredentials;
    if (cached != null) return cached;

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

  PowerSyncCredentials? get _freshCredentials {
    final cached = _credentials;
    final expiry = _credentialsExpireAt;
    if (cached == null || expiry == null) return null;
    return _clock().isBefore(expiry.subtract(const Duration(minutes: 1)))
        ? cached
        : null;
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
      return _payloadExpiry(payload);
    } on FormatException {
      return null;
    }
  }

  static DateTime? _payloadExpiry(Object? payload) {
    if (payload is! Map) return null;
    final expiry = payload['exp'];
    if (expiry is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      expiry.toInt() * Duration.millisecondsPerSecond,
    );
  }

  static Future<PowerSyncCredentials?> _fetchFromRouter(String endpoint) async {
    if (endpoint.isEmpty) return null;
    try {
      final installId = await InstallIdentity.getOrCreate();
      final res = await HttpClient.instance.dio.get<Map<String, dynamic>>(
        '/api/token/powersync',
        options: Options(headers: {'X-Install-Id': installId}),
      );
      final token = res.data?['token'] as String?;
      if (token == null) return null;
      return PowerSyncCredentials(endpoint: endpoint, token: token);
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
