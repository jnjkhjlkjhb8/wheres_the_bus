import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:wheres_the_bus/data/generated/mrt.pbgrpc.dart';
import 'package:wheres_the_bus/data/repositories/mrt_repository.dart';

import '../../support/helpers/fake_grpc.dart';

void main() {
  test('eta builds the Ask_mrt request and decodes each frame', () async {
    final client = _FakeMrtClient(
      frames: [
        Resp_Mrt_eta(
          data: Mrt_live(
            lineID: 'BR',
            destinationStationName: '南港展覽館',
            estimateTime: 120,
          ),
        ),
      ],
    );
    final repo = MrtRepository(client: client);

    final arrivals = await repo.eta('TRTC', 'BR01').toList();

    expect(client.request?.system, 'TRTC');
    expect(client.request?.stationID, 'BR01');
    expect(arrivals, hasLength(1));
    expect(arrivals.single.line, 'BR');
    expect(arrivals.single.destination, '南港展覽館');
    expect(arrivals.single.estimateSeconds, 120);
  });

  test('a default frame decodes without throwing', () async {
    final client = _FakeMrtClient(frames: [Resp_Mrt_eta()]);
    final repo = MrtRepository(client: client);

    final arrivals = await repo.eta('TRTC', 'BR01').toList();

    expect(arrivals.single.estimateSeconds, 0);
  });
}

class _FakeMrtClient implements Mrt_ServiceClient {
  _FakeMrtClient({this.frames = const []});

  final List<Resp_Mrt_eta> frames;
  Ask_mrt? request;

  @override
  ResponseStream<Resp_Mrt_eta> eta(Ask_mrt request, {CallOptions? options}) {
    this.request = request;
    return FakeResponseStream(Stream.fromIterable(frames));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}
