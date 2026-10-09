import 'dart:async';

import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:wheres_the_bus/core/firebase/firebase_gate.dart';

class AppConfig {
  AppConfig._();

  /// Bumped whenever a Realtime Remote Config update is activated, so widgets
  /// reading config (e.g. the maintenance banner) can rebuild without a
  /// relaunch. Listen via a ValueListenableBuilder; the value itself is opaque.
  static final version = ValueNotifier<int>(0);

  /// Single source of truth for defaults. Also fed to `setDefaults()` at
  /// bootstrap so registered and fallback values can't drift apart.
  static const defaults = <String, Object>{
    'maintenance_banner_enabled': false,
    'maintenance_banner_text': '',
    // General app announcement. No enable flag: empty text is off, which is
    // one fewer switch for ops to leave in the wrong position.
    'announcement_text': '',
    'push_enabled': true,
    'min_supported_version': '1.0.0',
    // The newest published build. Only ever nudges; `min_supported_version`
    // is the one that blocks. Defaults equal to the floor so a project with
    // no value set nudges nobody.
    'latest_version': '1.0.0',
    'store_url_ios': '',
    'store_url_android': '',
    'arrival_lead_minutes': '1,3,5',
    'eta_approaching_threshold_s': 30,
    // Tagged tokens: `metro:<system>` and `bus:<city>`, comma-separated.
    'alert_sources': 'metro:TRTC,bus:Taipei',
    'nearby_fallback_radius_m': 900,
    // Kill switch for the search screen's ask lane. It is the one surface
    // whose cost and latency come from a third party, so it needs to be
    // switchable off without a release.
    genUiEnabledKey: true,
    genUiSystemPromptKey:
        '你是大眾運輸 App 的搜尋助理,涵蓋公車、捷運、台鐵、高鐵與 YouBike。 '
        '使用者用自然語言提問,你必須先呼叫 searchTransit 工具向後端查詢真實的路線與站點資料, '
        '不可以自行編造站名、路線號碼或到站時間。 '
        '取得資料後,你只能透過呼叫 renderUI 工具回覆,把結果整理成精簡的卡片節點。 '
        '用 heading 當區塊標題,text 寫一兩句說明,route 呈現路線或轉乘建議, '
        'step 列出搭乘步驟,chip 提供可點擊的後續搜尋(query 必須是可直接搜尋的站名或路線), '
        'divider 分隔區塊。route 與 chip 若對應某筆 searchTransit 查詢結果, '
        '必須把該筆結果的 uid 原樣放進 refUid,不可自行編造 uid。 '
        '任何文字都不要寫到站時間、還有幾分鐘或班次時刻 — App 會自己從即時資料顯示,你寫的一定是錯的。 '
        '內容務必簡短,查詢路線的部分請直接搜尋路線名不要在後面加XXX「路」，站牌也一樣。',
  };

  /// The ask lane's Remote Config key. Named rather than inlined because the
  /// default map and the read site have to agree.
  static const genUiEnabledKey = 'genui_enabled';

  static const genUiSystemPromptKey = 'genui_system_prompt';

  static Stream<void> revisions() {
    late final StreamController<void> controller;
    void listener() => controller.add(null);
    controller = StreamController<void>.broadcast(
      onListen: () => version.addListener(listener),
      onCancel: () => version.removeListener(listener),
    );
    return controller.stream;
  }

  static Future<bool> refresh() async {
    if (!FirebaseGate.enabled) return false;
    try {
      await FirebaseRemoteConfig.instance.fetchAndActivate();
      version.value++;
      return true;
    } on Object catch (_) {
      return false;
    }
  }

  static bool getBool(String key) => _read(key, (rc) => rc.getBool(key));
  static String getString(String key) => _read(key, (rc) => rc.getString(key));
  static int getInt(String key) => _read(key, (rc) => rc.getInt(key));

  static T _read<T>(String key, T Function(FirebaseRemoteConfig) read) {
    if (FirebaseGate.enabled) {
      try {
        return read(FirebaseRemoteConfig.instance);
      } on Object catch (_) {
        // Fall through to the registered default.
      }
    }
    return defaults[key]! as T;
  }
}
