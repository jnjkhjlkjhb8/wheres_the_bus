import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/decoders/mrt_decoder.dart';
import 'package:wheres_the_bus/data/generated/mrt.pb.dart';
import 'package:wheres_the_bus/data/models/metro_models.dart';

const MrtDecoder _decoder = MrtDecoder.instance;

void main() {
  group('decodeEta', () {
    test('a fully-populated Mrt_live decodes to the expected view model', () {
      final live = Mrt_live(
        lineID: 'BR',
        stationID: 'BR01',
        destinationStationName: '南港展覽館',
        estimateTime: 120,
      );
      final out = _decoder.decodeEta(live);
      expect(
        out,
        const MetroLiveArrival(
          line: 'BR',
          destination: '南港展覽館',
          estimateSeconds: 120,
          // The board station id now threads through for car binding.
          stationId: 'BR01',
        ),
      );
    });

    test('a default-constructed Mrt_live decodes without throwing', () {
      final out = _decoder.decodeEta(Mrt_live());
      expect(
        out,
        const MetroLiveArrival(line: '', destination: '', estimateSeconds: 0),
      );
    });

    test(
      'Weight decodes to per-car levels, skipping empty/unparsable cars',
      () {
        final out = _decoder.decodeEta(
          Mrt_live(
            lineID: 'BL',
            trainNumber: '215',
            cN1: '163/164',
            weight: CartWeight(
              cart1L: '1',
              cart2L: '2',
              cart3L: '3',
              cart4L: '',
              cart5L: 'x',
              cart6L: '2',
            ),
          ),
        );
        expect(out.congestion, [1, 2, 3, 2]);
        expect(out.trainNumber, '215');
        expect(out.cn1, '163/164');
      },
    );

    test('a Mrt_live with no Weight decodes to empty congestion', () {
      final out = _decoder.decodeEta(Mrt_live(lineID: 'BL'));
      expect(out.congestion, isEmpty);
    });

    test('zero estimateTime decodes to a zero countdown', () {
      final out = _decoder.decodeEta(
        Mrt_live(lineID: 'BL', destinationStationName: '頂溪', estimateTime: 0),
      );
      expect(out.estimateSeconds, 0);
    });

    test(
      'a negative estimateTime passes through unclamped (no derivation)',
      () {
        final out = _decoder.decodeEta(
          Mrt_live(lineID: 'BL', estimateTime: -30),
        );
        expect(out.estimateSeconds, -30);
      },
    );
  });
}
