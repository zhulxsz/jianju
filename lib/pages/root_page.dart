import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/state/settings_provider.dart';
import '../core/state/theme_provider.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/responsive.dart';
import '../widgets/app_sidebar.dart';
import '../widgets/floating_nav_bar.dart';
import 'category/category_page.dart';
import 'home/home_page.dart';
import 'mine/mine_page.dart';
import 'rank/rank_page.dart';
import 'search/search_page.dart';
import 'settings/settings_page.dart';

/// 主框架
///
/// - 窄窗口（移动端）：四个 Tab + 苹果风格悬浮导航条
/// - 宽窗口（桌面端）：左侧常驻导航栏 + 内容区，支持 Ctrl+1~4 切 Tab、
///   Ctrl+F / Ctrl+K 打开搜索
class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    debugPrint('[NAV] root.init');
  }

  static const _navItems = [
    NavItem(icon: Icons.home_outlined, activeIcon: Icons.home_rounded, label: '首页'),
    NavItem(icon: Icons.grid_view_outlined, activeIcon: Icons.grid_view_rounded, label: '分类'),
    NavItem(icon: Icons.leaderboard_outlined, activeIcon: Icons.leaderboard_rounded, label: '排行榜'),
    NavItem(icon: Icons.favorite_border_rounded, activeIcon: Icons.favorite_rounded, label: '我的'),
  ];

  void _switchTab(int i) {
    if (i == _index) return;
    debugPrint('[NAV] tab=$i');
    setState(() => _index = i);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scope = FocusScope.of(context);
      if (scope.focusedChild == null) scope.nextFocus();
    });
  }

  void _openSearch() => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SearchPage()),
      );

  void _openSettings() => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsPage()),
      );

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => _switchTab(0),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => _switchTab(1),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => _switchTab(2),
        const SingleActivator(LogicalKeyboardKey.digit4, control: true): () => _switchTab(3),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _openSearch,
      };

  @override
  Widget build(BuildContext context) {
    final wide = AppLayout.isWide(context);
    final primary = context.watch<ThemeProvider>();
    final source = context.watch<SettingsProvider>().dataSource;
    final seed = AppPalette.colors[primary.colorIndex].color;

    // 数据源切换后整树重建：四个 Tab 全部按新站点重新拉数据。
    // IndexedStack 带 key，宽窄布局切换时仍按 key 复用，Tab 状态不丢。
    final pages = IndexedStack(
      key: ValueKey(source),
      index: _index,
      children: [
        ExcludeFocus(excluding: _index != 0, child: const HomePage()),
        ExcludeFocus(excluding: _index != 1, child: const CategoryPage()),
        ExcludeFocus(excluding: _index != 2, child: const RankPage()),
        ExcludeFocus(excluding: _index != 3, child: const MinePage()),
      ],
    );

    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Scaffold(
        // 桌面端没有底部悬浮条，不延展 body
        extendBody: !wide,
        body: Row(
          children: [
            if (wide)
              AppSidebar(
                items: _navItems,
                currentIndex: _index,
                primaryColor: seed,
                onSelect: _switchTab,
                onSettings: _openSettings,
              ),
            Expanded(child: pages),
          ],
        ),
        bottomNavigationBar: wide
            ? null
            : SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: FloatingNavBar(
                    items: _navItems,
                    currentIndex: _index,
                    primaryColor: seed,
                    onTap: _switchTab,
                  ),
                ),
              ),
      ),
    );
  }
}
