import 'package:flutter/material.dart';

import '../app_state.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'i18n.dart';
import 'models_page.dart';
import 'settings_page.dart';

/// Responsive navigation: side rail on wide windows, bottom bar on phones.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  // Static so the selected page survives the rebuild after pill mode.
  static int _index = 0;

  void go(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(onOpenModels: () => go(2), onOpenSettings: () => go(3)),
      const HistoryPage(),
      const ModelsPage(),
      const SettingsPage(),
    ];
    final dests = [
      (Icons.mic_none_rounded, Icons.mic_rounded, t('听写', 'Dictate')),
      (Icons.history_rounded, Icons.history_rounded, t('历史', 'History')),
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
                padding: const EdgeInsets.only(bottom: 16),
                child: Text('v$kAppVersion', style: TextStyle(fontSize: 11, color: scheme.outline)),
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
  const PageFrame({super.key, required this.title, this.actions = const [], required this.children});

  final String title;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 720;
    return ListView(
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 32, narrow ? 12 : 28, narrow ? 16 : 32, 32),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
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
    );
  }
}
