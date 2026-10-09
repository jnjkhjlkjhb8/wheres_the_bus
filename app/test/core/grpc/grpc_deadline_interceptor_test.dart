import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/grpc/grpc_deadline_interceptor.dart';

import '../../support/helpers/fake_grpc.dart';

List<int> _serialize(int v) => [v];
int _deserialize(List<int> v) => v.first;

void main() {
  group('GrpcDeadlineInterceptor', () {
    test('applies the default deadline when the caller set none', () {
      final interceptor = GrpcDeadlineInterceptor(
        defaultTimeout: const Duration(seconds: 7),
      );
      final method = ClientMethod<int, int>('/x', _serialize, _deserialize);
      CallOptions? seen;

      unawaited(
        interceptor.interceptUnary<int, int>(
          method,
          1,
          CallOptions(),
          (m, req, opts) {
            seen = opts;
            return FakeResponseFuture<int>(Future.value(1));
          },
        ),
      );

      expect(seen!.timeout, const Duration(seconds: 7));
    });

    test('leaves a caller-set deadline untouched', () {
      final interceptor = GrpcDeadlineInterceptor(
        defaultTimeout: const Duration(seconds: 7),
      );
      final method = ClientMethod<int, int>('/x', _serialize, _deserialize);
      CallOptions? seen;

      unawaited(
        interceptor.interceptUnary<int, int>(
          method,
          1,
          CallOptions(timeout: const Duration(seconds: 30)),
          (m, req, opts) {
            seen = opts;
            return FakeResponseFuture<int>(Future.value(1));
          },
        ),
      );

      expect(seen!.timeout, const Duration(seconds: 30));
    });
  });
}
