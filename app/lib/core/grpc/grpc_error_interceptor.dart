import 'dart:async';

import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/firebase/crash_reporter.dart';

class GrpcErrorInterceptor extends ClientInterceptor {
  GrpcErrorInterceptor();

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    final response = invoker(method, request, options);
    unawaited(
      response.then(
        (_) {},
        onError: (Object error, StackTrace stack) {
          CrashReporter.record(error, stack);
        },
      ),
    );
    return response;
  }
}
