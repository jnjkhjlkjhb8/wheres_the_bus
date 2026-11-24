import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wheres_the_bus/core/locale/system_app_language.dart';
import 'package:wheres_the_bus/data/repositories/settings_repository.dart';

import '../../support/helpers/in_memory_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> sent;
  late Object? reply;

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void fakeNative() {
    sent = [];
    reply = null;
    messenger().setMockMethodCallHandler(SystemAppLanguage.channel, (
      call,
    ) async {
      sent.add(call);
      return reply;
    });
    addTearDown(
      () => messenger().setMockMethodCallHandler(
        SystemAppLanguage.channel,
        null,
      ),
    );
  }

  test('maps system tags onto in-app keys', () {
    expect(
      {
        for (final tag in [
          'zh-TW',
          'zh-Hant-TW',
          'ZH-cn',
          'zh-Hans',
          'en-US',
          'ja',
          '',
        ])
          tag: SystemAppLanguage.keyFor(tag),
      },
      {
        'zh-TW': 'zh',
        'zh-Hant-TW': 'zh',
        'ZH-cn': 'zh_CN',
        'zh-Hans': 'zh_CN',
        'en-US': 'en',
        'ja': null,
        '': null,
      },
    );
  });

  test('push sends the tag for each in-app key, empty for system', () async {
    fakeNative();
    for (final key in ['zh', 'zh_CN', 'en', 'system']) {
      await SystemAppLanguage.push(key);
    }

    expect(sent.map((c) => c.method).toSet(), {'set'});
    expect(sent.map((c) => c.arguments), ['zh-TW', 'zh-CN', 'en', '']);
  });

  test('pull reads the system tag as an in-app key', () async {
    fakeNative();
    reply = 'zh-CN';
    final cn = await SystemAppLanguage.pull();
    reply = '';
    final unset = await SystemAppLanguage.pull();
    reply = null;
    final unsupported = await SystemAppLanguage.pull();

    expect((cn, unset, unsupported), ('zh_CN', null, null));
    expect(sent.first.method, 'get');
  });

  test('adopt takes a different system choice and keeps the rest', () async {
    fakeNative();
    SettingsRepository settings(String key) => SettingsRepository(
      store: InMemorySettingsStore({SettingsRepository.languageKey: key}),
    );
    final changed = settings('zh');
    reply = 'en-GB';
    await SystemAppLanguage.adopt(changed);
    final same = settings('en');
    await SystemAppLanguage.adopt(same);
    final unset = settings('zh_CN');
    reply = '';
    await SystemAppLanguage.adopt(unset);

    expect(
      (changed.languageCode, same.languageCode, unset.languageCode),
      ('en', 'en', 'zh_CN'),
    );
  });

  test('without a native side both calls are no-ops', () async {
    await SystemAppLanguage.push('en');
    expect(await SystemAppLanguage.pull(), isNull);
  });
}
