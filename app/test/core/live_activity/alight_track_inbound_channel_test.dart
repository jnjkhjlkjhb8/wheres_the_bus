import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/live_activity/alight_track_inbound_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.wheres.bus/live_activity');

  Future<void> fireCancel() async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('onCancelTrack'),
          ),
          (_) {},
        );
  }

  setUp(AlightTrackInboundChannel.reset);
  tearDown(AlightTrackInboundChannel.reset);

  test(
    "every owner hears the card's cancel, not just the last to bind",
    () async {
      // Bus/TRA/THSR sessions and metro sessions live in different blocs.
      // Bound one-at-a-time, whichever registered last would silently win
      // and 取消追蹤 would do nothing on the other network's card.
      final heard = <String>[];
      AlightTrackInboundChannel.bind(() => heard.add('journey'));
      AlightTrackInboundChannel.bind(() => heard.add('metro'));

      await fireCancel();

      expect(heard, ['journey', 'metro']);
    },
  );

  test('a listener added after a cancel still hears the next one', () async {
    final heard = <String>[];
    AlightTrackInboundChannel.bind(() => heard.add('first'));
    await fireCancel();
    AlightTrackInboundChannel.bind(() => heard.add('second'));
    await fireCancel();

    expect(heard, ['first', 'first', 'second']);
  });

  test('reset drops every binding', () async {
    final heard = <String>[];
    AlightTrackInboundChannel.bind(() => heard.add('x'));
    AlightTrackInboundChannel.reset();

    await fireCancel();

    expect(heard, isEmpty);
  });

  Future<void> firePushToken(Object? argument) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onPushToken', argument),
          ),
          (_) {},
        );
  }

  test('push tokens and cancels reach their own listeners', () async {
    // One MethodChannel has room for one handler, so both inbound messages
    // share it. A cancel listener firing on a token — or the reverse — would
    // end a ride the rider never asked to end.
    final cancels = <String>[];
    final tokens = <String>[];
    AlightTrackInboundChannel.bind(() => cancels.add('cancel'));
    AlightTrackInboundChannel.bindPushToken(tokens.add);

    await firePushToken('deadbeef');
    await fireCancel();

    expect(tokens, ['deadbeef']);
    expect(cancels, ['cancel']);
  });

  test('an empty or absent token is not forwarded', () async {
    // iOS hands up whatever ActivityKit gave it; an empty token addresses no
    // card, and storing one server-side would only cost a push per hop.
    final tokens = <String>[];
    AlightTrackInboundChannel.bindPushToken(tokens.add);

    await firePushToken('');
    await firePushToken(null);

    expect(tokens, isEmpty);
  });
}
