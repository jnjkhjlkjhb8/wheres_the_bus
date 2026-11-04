import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/core/grpc/grpc_heartbeat_interceptor.dart';
import 'package:wheres_the_bus/data/generated/alert.pb.dart';
import 'package:wheres_the_bus/data/generated/bike.pb.dart';
import 'package:wheres_the_bus/data/generated/near.pb.dart';

import '../../support/helpers/fake_grpc.dart';

/// The exact bytes the Go heartbeat.Marker() frame encodes to: field 1000,
/// varint, value 1 (tag 8000 = 0xC0 0x3E).
const _markerBytes = [0xC0, 0x3E, 0x01];

class _CancelTracking<R> extends FakeResponseStream<R> {
  _CancelTracking(super.stream);

  bool cancelled = false;

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<Map<String, String>> get headers async => const {'h': '1'};

  @override
  Future<Map<String, String>> get trailers async => const {'t': '1'};
}

ResponseStream<R> _intercept<R>(ResponseStream<R> upstream) =>
    GrpcHeartbeatInterceptor().interceptStreaming<int, R>(
      ClientMethod<int, R>('/x', (v) => [v], (_) => throw UnimplementedError()),
      const Stream<int>.empty(),
      CallOptions(),
      (m, reqs, opts) => upstream,
    );

void main() {
  group('isStreamHeartbeat', () {
    test('the server marker decodes as a heartbeat into any stream type', () {
      expect(isStreamHeartbeat(Resp_Bike_eta.fromBuffer(_markerBytes)), isTrue);
      expect(isStreamHeartbeat(resp_near.fromBuffer(_markerBytes)), isTrue);
      expect(isStreamHeartbeat(Alert_Msg.fromBuffer(_markerBytes)), isTrue);
    });

    test('an empty message is data, not a heartbeat', () {
      expect(isStreamHeartbeat(resp_near()), isFalse);
      expect(isStreamHeartbeat(Alert_Msg.fromBuffer(const [])), isFalse);
    });

    test('a message with data is not a heartbeat', () {
      final eta = Resp_Bike_eta(data: Bike_eta(generalBikes: 3));
      expect(isStreamHeartbeat(eta), isFalse);
    });

    test('a non-protobuf value is not a heartbeat', () {
      expect(isStreamHeartbeat(1), isFalse);
      expect(isStreamHeartbeat(null), isFalse);
    });
  });

  group('GrpcHeartbeatInterceptor', () {
    test('drops heartbeats and keeps every data message in order', () async {
      final data = Resp_Bike_eta(data: Bike_eta(generalBikes: 2));
      final empty = Resp_Bike_eta();
      final stream = _intercept(
        FakeResponseStream(
          Stream.fromIterable([
            Resp_Bike_eta.fromBuffer(_markerBytes),
            data,
            Resp_Bike_eta.fromBuffer(_markerBytes),
            empty,
          ]),
        ),
      );
      expect(await stream.toList(), [data, empty]);
    });

    test('passes cancel, headers and trailers through', () async {
      final upstream = _CancelTracking<int>(const Stream<int>.empty());
      final stream = _intercept(upstream);
      expect(await stream.headers, {'h': '1'});
      expect(await stream.trailers, {'t': '1'});
      await stream.cancel();
      expect(upstream.cancelled, isTrue);
    });

    test('delegates single to the upstream call', () {
      final stream = _intercept(FakeResponseStream<int>(const Stream.empty()));
      expect(() => stream.single, throwsUnimplementedError);
    });

    test('leaves unary calls untouched', () async {
      final interceptor = GrpcHeartbeatInterceptor();
      final result = await interceptor.interceptUnary<int, int>(
        ClientMethod<int, int>('/x', (v) => [v], (v) => v.first),
        1,
        CallOptions(),
        (m, req, opts) => FakeResponseFuture<int>(Future.value(7)),
      );
      expect(result, 7);
    });
  });
}
