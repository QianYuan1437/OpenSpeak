import 'package:flutter/material.dart';

import '../app_state.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'i18n.dart';
import 'theme.dart';
import 'models_page.dart';
import 'refine_page.dart';
import 'settings_page.dart';

/// Responsive navigation: side rail on wide windows, bottom bar on phones.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Page shown first (0 dictation, 1 history, 2 refine, 3 models, 4 settings).
  static int initialPage = 0;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // Static so the selected page survives the rebuild after pill mode.
  static int _index = HomeShell.initialPage;

  void go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(onOpenModels: () => go(3), onOpenSettings: () => go(4)),
      const HistoryPage(),
      const RefinePage(),
      const ModelsPage(),
      const SettingsPage(),
    ];
    final dests = [
      (Icons.mic_none_rounded, Icons.mic_rounded, t('听写', 'Dictate')),
      (Icons.history_rounded, Icons.history_rounded, t('历史', 'History')),
      (Icons.auto_fix_high_outlined, Icons.auto_fix_high_rounded, t('优化', 'Refine')),
      (Icons.memory_outlined, Icons.memory_rounded, t('模型', 'Models')),
      (Icons.tune_outlined, Icons.tune_rounded, t('设置', 'Settings')),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final body = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: KeyedSubtree(key: ValueKey(_index), child: pages[_index]),
    );
    if (!wide) {
      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: go,
          destinations: [
            for (final d in dests)
              NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3),
          ],
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          selectedIndex: _index,
          onDestinationSelected: go,
          minWidth: 84,
          leading: Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 22),
            child: Column(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset('assets/icon.png', width: 40, height: 40),
              ),
              const SizedBox(height: 6),
              Text('OpenSpeak',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.primary)),
            ]),
          ),
          trailing: Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ListenableBuilder(
                  listenable: updater,
                  builder: (context, _) => Tooltip(
                    message: updater.available != null
                        ? t('发现新版本 v${updater.available!.version}，点击查看', 'v${updater.available!.version} is available')
                        : t('检查更新', 'Check for updates'),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        SettingsPage.requestUpdateCheck();
                        go(4);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text('v${kAppVersion.replaceFirst('-dev.', '.')}',
                              style: TextStyle(fontSize: 11, color: scheme.outline)),
                          if (updater.available != null) ...[
                            const SizedBox(width: 4),
                            Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(color: kListening, shape: BoxShape.circle),
                            ),
                          ],
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          destinations: [
            for (final d in dests)
              NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3)),
          ],
        ),
        VerticalDivider(width: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
        Expanded(child: body),
      ]),
    );
  }
}

/// Common page scaffold: title + scrollable, width-limited content.
class PageFrame extends StatelessWidget {
  const PageFrame(
      {super.key, required this.title, this.actions = const [], required this.children, this.maxWidth = 860});

  final String title;
  final double maxWidth;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 720;
    // Content scrolling under the window's top edge fades out over 20 px
    // instead of being cut off with a hard line.
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x00000000), Color(0xFF000000)],
      ).createShader(Rect.fromLTWH(0, 0, rect.width, 20)),
      child: ListView(
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 32, narrow ? 12 : 28, narrow ? 16 : 32, 32),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(title,
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  ...actions,
                ]),
                const SizedBox(height: 18),
                for (final c in children) ...[c, const SizedBox(height: 14)],
              ],
            ),
          ),
        ),
      ],
      ),
    );
  }
}
