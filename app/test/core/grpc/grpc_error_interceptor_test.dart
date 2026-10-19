import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/grpc/grpc_error_interceptor.dart';

import '../../support/helpers/fake_grpc.dart';

List<int> _serialize(int value) => [value];
int _deserialize(List<int> values) => values.single;

void main() {
  group('GrpcErrorInterceptor', () {
    test('preserves the call and its successful response', () async {
      final method = ClientMethod<int, int>(
        '/contract',
        _serialize,
        _deserialize,
      );
      final options = CallOptions(metadata: {'x-contract': 'kept'});
      final completed = Completer<int>();
      final original = FakeResponseFuture<int>(completed.future);
      var invocations = 0;

      final response = GrpcErrorInterceptor().interceptUnary<int, int>(
        method,
        41,
        options,
        (seenMethod, seenRequest, seenOptions) {
          invocations++;
          expect(seenMethod, same(method));
          expect(seenRequest, 41);
          expect(seenOptions, same(options));
          return original;
        },
      );

      expect(invocations, 1);
      expect(response, same(original));
      final observed = expectLater(response, completion(42));
      completed.complete(42);
      await observed;
    });

    test('the caller still receives the original asynchronous error', () async {
      final method = ClientMethod<int, int>(
        '/contract',
        _serialize,
        _deserialize,
      );
      final completed = Completer<int>();
      final original = FakeResponseFuture<int>(completed.future);
      const failure = GrpcError.unavailable('contract unavailable');
      final response = GrpcErrorInterceptor().interceptUnary<int, int>(
        method,
        41,
        CallOptions(),
        (_, _, _) => original,
      );

      expect(response, same(original));
      final observed = expectLater(response, throwsA(same(failure)));
      completed.completeError(failure, StackTrace.current);
      await observed;
      await Future<void>.delayed(Duration.zero);
    });
  });
}
