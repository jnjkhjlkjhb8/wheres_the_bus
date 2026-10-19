import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/firebase_models.dart';

void main() {
  group('FirebaseAck', () {
    test('defaults to an empty message', () {
      const ack = FirebaseAck(ok: true);
      expect(ack.ok, isTrue);
      expect(ack.message, '');
    });

    test('compares by outcome and message', () {
      expect(const FirebaseAck(ok: true), const FirebaseAck(ok: true));
      expect(
        const FirebaseAck(ok: true).hashCode,
        const FirebaseAck(ok: true).hashCode,
      );
      expect(
        const FirebaseAck(ok: true),
        isNot(const FirebaseAck(ok: false)),
      );
      expect(
        const FirebaseAck(ok: true, message: 'a'),
        isNot(const FirebaseAck(ok: true, message: 'b')),
      );
    });
  });

  group('FirebaseDeviceState', () {
    test('defaults to an unregistered, push-off device', () {
      const state = FirebaseDeviceState();
      expect(state.installId, '');
      expect(state.fcmToken, '');
      expect(state.platform, '');
      expect(state.appVersion, '');
      expect(state.pushEnabled, isFalse);
    });

    test('every field takes part in equality', () {
      const base = FirebaseDeviceState(
        installId: 'i',
        fcmToken: 't',
        platform: 'ios',
        appVersion: '1.0',
        pushEnabled: true,
      );
      const same = FirebaseDeviceState(
        installId: 'i',
        fcmToken: 't',
        platform: 'ios',
        appVersion: '1.0',
        pushEnabled: true,
      );
      expect(base, same);
      expect(base.hashCode, same.hashCode);
      const others = [
        FirebaseDeviceState(
          installId: 'x',
          fcmToken: 't',
          platform: 'ios',
          appVersion: '1.0',
          pushEnabled: true,
        ),
        FirebaseDeviceState(
          installId: 'i',
          fcmToken: 'x',
          platform: 'ios',
          appVersion: '1.0',
          pushEnabled: true,
        ),
        FirebaseDeviceState(
          installId: 'i',
          fcmToken: 't',
          platform: 'x',
          appVersion: '1.0',
          pushEnabled: true,
        ),
        FirebaseDeviceState(
          installId: 'i',
          fcmToken: 't',
          platform: 'ios',
          appVersion: 'x',
          pushEnabled: true,
        ),
        FirebaseDeviceState(
          installId: 'i',
          fcmToken: 't',
          platform: 'ios',
          appVersion: '1.0',
        ),
      ];
      for (final other in others) {
        expect(other, isNot(base));
      }
    });
  });

  test('a reminder receipt is identified by its reminder id', () {
    expect(
      const ArrivalReminderReceipt(reminderId: 'r1').reminderId,
      'r1',
    );
    expect(
      const ArrivalReminderReceipt(reminderId: 'r1'),
      const ArrivalReminderReceipt(reminderId: 'r1'),
    );
    expect(
      const ArrivalReminderReceipt(reminderId: 'r1'),
      isNot(const ArrivalReminderReceipt(reminderId: 'r2')),
    );
  });
}
