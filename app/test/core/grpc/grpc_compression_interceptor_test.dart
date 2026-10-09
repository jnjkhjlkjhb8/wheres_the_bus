import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/grpc/grpc_compression_interceptor.dart';

import '../../support/helpers/fake_grpc.dart';

List<int> _serialize(int v) => [v];
int _deserialize(List<int> v) => v.first;

CallOptions _run(CallOptions incoming) {
  final method = ClientMethod<int, int>('/x', _serialize, _deserialize);
  late CallOptions seen;
  unawaited(
    GrpcCompressionInterceptor().interceptUnary<int, int>(
      method,
      1,
      incoming,
      (m, req, opts) {
        seen = opts;
        return FakeResponseFuture<int>(Future.value(1));
      },
    ),
  );
  return seen;
}

CallOptions _runStreaming(CallOptions incoming) {
  final method = ClientMethod<int, int>('/x', _serialize, _deserialize);
  late CallOptions seen;
  GrpcCompressionInterceptor().interceptStreaming<int, int>(
    method,
    const Stream<int>.empty(),
    incoming,
    (m, reqs, opts) {
      seen = opts;
      return FakeResponseStream<int>(const Stream<int>.empty());
    },
  );
  return seen;
}

void main() {
  group('GrpcCompressionInterceptor', () {
    test('gzips a request the caller left uncompressed', () {
      expect(_run(CallOptions()).compression?.encodingName, 'gzip');
    });

    test('leaves a caller-set codec untouched', () {
      final seen = _run(CallOptions(compression: const IdentityCodec()));
      expect(seen.compression?.encodingName, 'identity');
    });

    test('gzips streaming calls too', () {
      expect(_runStreaming(CallOptions()).compression?.encodingName, 'gzip');
    });

    test('leaves a caller-set codec untouched on a stream', () {
      final seen = _runStreaming(
        CallOptions(compression: const IdentityCodec()),
      );
      expect(seen.compression?.encodingName, 'identity');
    });

    test('preserves the options it merges over', () {
      final seen = _run(
        CallOptions(
          timeout: const Duration(seconds: 3),
          metadata: {'authorization': 'Bearer x'},
        ),
      );
      expect(seen.compression?.encodingName, 'gzip');
      expect(seen.timeout, const Duration(seconds: 3));
      expect(seen.metadata['authorization'], 'Bearer x');
    });
  });
}
