import 'dart:ui' show PlatformDispatcher;

/// Minimal two-language support: every UI string is written inline as
/// `t('中文', 'English')`.
class L {
  static bool zh = true;

  static void apply(String uiLanguage) {
    zh = switch (uiLanguage) {
      'zh' => true,
      'en' => false,
      _ => PlatformDispatcher.instance.locale.languageCode == 'zh',
    };
  }
}

String t(String zh, String en) => L.zh ? zh : en;
