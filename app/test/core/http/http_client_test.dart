import 'package:flutter_test/flutter_test.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';
import 'package:wheres_the_bus/core/http/http_client.dart';

void main() {
  group('HttpClient request logging', () {
    test('adds PrettyDioLogger in debug builds', () {
      final client = HttpClient.forTesting(debug: true);
      expect(
        client.dio.interceptors.whereType<PrettyDioLogger>(),
        hasLength(1),
      );
    });

    test('never adds PrettyDioLogger in release builds', () {
      final client = HttpClient.forTesting(debug: false);
      expect(client.dio.interceptors.whereType<PrettyDioLogger>(), isEmpty);
    });
  });

  group('redactSensitiveLog', () {
    test('masks a bearer token value while keeping the rest of the line', () {
      final line = redactSensitiveLog(
        '║ "token": "eyJhbGciOiJIUzI1NiJ9.secret.stuff", "city": "Taipei"',
      );
      expect(line, isNot(contains('eyJhbGciOiJIUzI1NiJ9.secret.stuff')));
      expect(line, contains('"city": "Taipei"'));
      expect(line, contains('***'));
    });

    test('masks common secret key spellings case-insensitively', () {
      for (final key in ['Authorization', 'secret', 'PASSWORD', 'apiKey']) {
        final line = redactSensitiveLog('"$key": "leak-me"');
        expect(line, isNot(contains('leak-me')), reason: key);
      }
    });

    test('leaves lines without sensitive keys untouched', () {
      const line = '"city": "Taipei", "stopId": "12345"';
      expect(redactSensitiveLog(line), line);
    });
  });
}
