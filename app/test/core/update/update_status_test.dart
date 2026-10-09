import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/update/update_status.dart';

void main() {
  group('isBelowVersion', () {
    test('below', () {
      expect(isBelowVersion('1.0.0', '1.2.0'), isTrue);
      expect(isBelowVersion('1.9.9', '2.0.0'), isTrue);
      expect(isBelowVersion('1.2', '1.2.1'), isTrue);
    });

    test('equal or above is not below', () {
      expect(isBelowVersion('1.2.0', '1.2.0'), isFalse);
      expect(isBelowVersion('2.0.0', '1.9.9'), isFalse);
      expect(isBelowVersion('1.2.1', '1.2'), isFalse);
    });

    test('build/pre-release suffix on current is ignored', () {
      expect(isBelowVersion('1.2.0+42', '1.2.0'), isFalse);
      expect(isBelowVersion('1.1.0-beta', '1.2.0'), isTrue);
    });

    test('malformed input fails open (never locks users out)', () {
      expect(isBelowVersion('1.0.0', 'garbage'), isFalse);
      expect(isBelowVersion('', '1.0.0'), isFalse);
      expect(isBelowVersion('1.x.0', '1.2.0'), isFalse);
    });
  });

  group('resolveUpdateStatus', () {
    test('below the floor blocks', () {
      expect(
        resolveUpdateStatus(
          current: '1.0.0',
          minSupported: '1.1.0',
          latest: '1.4.0',
        ),
        UpdateStatus.blocked,
      );
    });

    test('blocked wins over available', () {
      // Below both bars: the rider must get the interstitial, never a
      // dismissible nudge for a build that cannot run.
      expect(
        resolveUpdateStatus(
          current: '0.9.0',
          minSupported: '1.0.0',
          latest: '1.4.0',
        ),
        UpdateStatus.blocked,
      );
    });

    test('at the floor but behind the latest only nudges', () {
      expect(
        resolveUpdateStatus(
          current: '1.1.0',
          minSupported: '1.1.0',
          latest: '1.4.0',
        ),
        UpdateStatus.available,
      );
    });

    test('at the latest is up to date', () {
      expect(
        resolveUpdateStatus(
          current: '1.4.0',
          minSupported: '1.1.0',
          latest: '1.4.0',
        ),
        UpdateStatus.upToDate,
      );
    });

    test('ahead of the latest (TestFlight/internal) is up to date', () {
      expect(
        resolveUpdateStatus(
          current: '1.5.0',
          minSupported: '1.1.0',
          latest: '1.4.0',
        ),
        UpdateStatus.upToDate,
      );
    });

    test('a malformed latest never nags', () {
      expect(
        resolveUpdateStatus(
          current: '1.0.0',
          minSupported: '1.0.0',
          latest: '',
        ),
        UpdateStatus.upToDate,
      );
    });
  });

  group('isAllowedStoreUrl', () {
    test('allows the official App Store host over https', () {
      expect(
        isAllowedStoreUrl(Uri.parse('https://apps.apple.com/tw/app/x')),
        isTrue,
      );
    });

    test('allows the official Play Store host over https', () {
      expect(
        isAllowedStoreUrl(
          Uri.parse('https://play.google.com/store/apps/details?id=x'),
        ),
        isTrue,
      );
    });

    test('rejects non-https schemes even on an allowed host', () {
      expect(
        isAllowedStoreUrl(Uri.parse('http://apps.apple.com/tw/app/x')),
        isFalse,
      );
      expect(
        isAllowedStoreUrl(Uri.parse('javascript://apps.apple.com/x')),
        isFalse,
      );
    });

    test('rejects hosts outside the allowlist', () {
      expect(
        isAllowedStoreUrl(
          Uri.parse('https://evil.example.com/apps.apple.com'),
        ),
        isFalse,
      );
      expect(
        isAllowedStoreUrl(Uri.parse('https://apps.apple.com.evil.com/x')),
        isFalse,
      );
    });
  });

  group('storeUrl', () {
    test('unset Remote Config values resolve to no link', () {
      // Firebase is off under test, so `AppConfig` serves its defaults, which
      // are empty. Both platforms must degrade to null rather than to a Uri
      // that `launchUrl` would silently drop.
      expect(storeUrl(isIOS: true), isNull);
      expect(storeUrl(isIOS: false), isNull);
    });
  });
}
