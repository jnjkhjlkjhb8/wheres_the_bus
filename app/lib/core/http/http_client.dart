import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:pretty_dio_logger/pretty_dio_logger.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';

final _sensitiveKeyPattern = RegExp(
  r'("(?:authorization|token|secret|password|apikey|api_key)"\s*:\s*")[^"]*(")',
  caseSensitive: false,
);

/// Replaces the value of any sensitive-looking key in [line] with `***`,
/// leaving the rest of the line (and non-matching lines) untouched.
String redactSensitiveLog(String line) =>
    line.replaceAllMapped(_sensitiveKeyPattern, (m) => '${m[1]}***${m[2]}');

void _redactedLogPrint(Object object) =>
    debugPrint(redactSensitiveLog('$object'));

class HttpClient {
  HttpClient._({bool? debug}) : _debug = debug ?? kDebugMode;

  /// Injectable for tests, so the debug-only logger can be exercised without
  /// depending on the ambient `kDebugMode` (always true under `flutter
  /// test`).
  @visibleForTesting
  factory HttpClient.forTesting({required bool debug}) =>
      HttpClient._(debug: debug);

  static final HttpClient instance = HttpClient._();

  final bool _debug;

  static const _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  late final Dio dio =
      Dio(
          BaseOptions(
            baseUrl: _baseUrl,
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 30),
          ),
        )
        ..interceptors.addAll([
          // Request/response logging never ships in release builds: it is a
          // debugging aid, not a product feature, and even with redaction it
          // shouldn't run where end users can see console output (F41).
          if (_debug)
            PrettyDioLogger(
              requestBody: true,
              responseBody: false,
              logPrint: _redactedLogPrint,
            ),
          InterceptorsWrapper(
            onError: (error, handler) {
              CrashReporter.record(error, error.stackTrace);
              handler.next(error);
            },
          ),
        ]);
}
