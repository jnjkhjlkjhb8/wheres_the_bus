import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/data/models/fare_type.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_event.dart';
import 'package:wheres_the_bus/features/settings/bloc/settings_state.dart';

void main() {
  group('SettingsEvent', () {
    test('single-value events compare their value', () {
      expect(
        const AppearanceSelected(Appearance.dark),
        const AppearanceSelected(Appearance.dark),
      );
      expect(
        const AppearanceSelected(Appearance.dark),
        isNot(const AppearanceSelected(Appearance.light)),
      );
      expect(
        const LanguageSelected(Language.en),
        isNot(const LanguageSelected(Language.zh)),
      );
      expect(
        const LiveActivityToggled(value: true),
        isNot(const LiveActivityToggled(value: false)),
      );
      expect(
        const ShakeToReportToggled(value: true),
        isNot(const ShakeToReportToggled(value: false)),
      );
      expect(
        const PushToggled(value: true),
        isNot(const PushToggled(value: false)),
      );
      expect(
        const FareTypeSelected(FareType.student),
        isNot(const FareTypeSelected(FareType.child)),
      );
      expect(
        const StepFreeRoutingToggled(value: true),
        isNot(const StepFreeRoutingToggled(value: false)),
      );
      expect(
        const WalkPaceSelected(WalkPace.faster),
        isNot(const WalkPaceSelected(WalkPace.slower)),
      );
      expect(const UpdateCheckRequested().props, isEmpty);
    });

    test('AppMetadataLoaded compares version and sync time', () {
      final base = AppMetadataLoaded(
        appVersion: '1.0.0',
        powerSyncLastSyncedAt: DateTime.utc(2030),
      );
      expect(
        base,
        AppMetadataLoaded(
          appVersion: '1.0.0',
          powerSyncLastSyncedAt: DateTime.utc(2030),
        ),
      );
      expect(
        base,
        isNot(
          AppMetadataLoaded(
            appVersion: '2.0.0',
            powerSyncLastSyncedAt: DateTime.utc(2030),
          ),
        ),
      );
      expect(
        base,
        isNot(
          const AppMetadataLoaded(
            appVersion: '1.0.0',
            powerSyncLastSyncedAt: null,
          ),
        ),
      );
    });
  });

  group('SettingsState', () {
    test('defaults', () {
      const state = SettingsState();
      expect(state.appearance, Appearance.system);
      expect(state.language, Language.system);
      expect(state.pushEnabled, isTrue);
      expect(state.pushUpdating, isFalse);
      expect(state.fareType, FareType.full);
      expect(state.liveActivityEnabled, isTrue);
      expect(state.shakeToReport, isTrue);
      expect(state.stepFreeRouting, isFalse);
      expect(state.walkPace, WalkPace.standard);
      expect(state.appVersion, '');
      expect(state.powerSyncLastSyncedAt, isNull);
      expect(state.updateCheck, UpdateCheck.idle);
      expect(state.latestVersion, '');
    });

    test('copyWith with no arguments keeps every field', () {
      final base = SettingsState(
        appearance: Appearance.dark,
        language: Language.en,
        pushEnabled: false,
        pushUpdating: true,
        fareType: FareType.child,
        liveActivityEnabled: false,
        shakeToReport: false,
        stepFreeRouting: true,
        walkPace: WalkPace.faster,
        appVersion: '1.2.3',
        powerSyncLastSyncedAt: DateTime.utc(2030),
        updateCheck: UpdateCheck.available,
        latestVersion: '2.0.0',
      );
      expect(base.copyWith(), base);
    });

    test('copyWith swaps exactly the field it is given', () {
      const base = SettingsState();
      final variants = <SettingsState>[
        base.copyWith(appearance: Appearance.dark),
        base.copyWith(language: Language.en),
        base.copyWith(pushEnabled: false),
        base.copyWith(pushUpdating: true),
        base.copyWith(fareType: FareType.student),
        base.copyWith(liveActivityEnabled: false),
        base.copyWith(shakeToReport: false),
        base.copyWith(stepFreeRouting: true),
        base.copyWith(walkPace: WalkPace.faster),
        base.copyWith(appVersion: '1'),
        base.copyWith(powerSyncLastSyncedAt: DateTime.utc(2030)),
        base.copyWith(updateCheck: UpdateCheck.failed),
        base.copyWith(latestVersion: '9'),
      ];
      for (final variant in variants) {
        expect(variant, isNot(base));
      }
      expect(variants[0].appearance, Appearance.dark);
      expect(variants[1].language, Language.en);
      expect(variants[2].pushEnabled, isFalse);
      expect(variants[3].pushUpdating, isTrue);
      expect(variants[4].fareType, FareType.student);
      expect(variants[5].liveActivityEnabled, isFalse);
      expect(variants[6].shakeToReport, isFalse);
      expect(variants[7].stepFreeRouting, isTrue);
      expect(variants[8].walkPace, WalkPace.faster);
      expect(variants[9].appVersion, '1');
      expect(variants[10].powerSyncLastSyncedAt, DateTime.utc(2030));
      expect(variants[11].updateCheck, UpdateCheck.failed);
      expect(variants[12].latestVersion, '9');
    });
  });
}
