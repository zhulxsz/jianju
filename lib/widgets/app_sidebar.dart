import 'package:flutter/material.dart';

import '../core/constants/app_constants.dart';
import '../core/theme/responsive.dart';
import 'brand_icon.dart';
import 'floating_nav_bar.dart';

/// 桌面端左侧常驻导航栏（宽窗口专用，替代移动端底部悬浮导航条）
///
/// 结构：品牌区 -> 四个主 Tab -> 分隔线 -> 设置入口 -> 底部说明。
/// 选中态为主色胶囊，鼠标悬停有中性底色反馈，光标为可点击形态。
class AppSidebar extends StatelessWidget {
  final List<NavItem> items;
  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onSettings;
  final Color primaryColor;

  const AppSidebar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onSelect,
    required this.onSettings,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final edge = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.07);

    return Container(
      width: AppLayout.sidebarWidth,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0A0A0B) : Colors.white,
        border: Border(right: BorderSide(color: edge, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 18),
          // ===== 品牌区 =====
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: [
                BrandIcon(size: 34, color: primaryColor),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(AppConstants.appName,
                          style:
                              TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 1),
                      Text(
                        AppConstants.appTagline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // ===== 主 Tab =====
          for (var i = 0; i < items.length; i++)
            _SidebarItem(
              icon: items[i].icon,
              activeIcon: items[i].activeIcon,
              label: items[i].label,
              selected: i == currentIndex,
              primaryColor: primaryColor,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Container(
              height: 1,
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.05),
            ),
          ),
          const SizedBox(height: 8),
          // ===== 设置入口 =====
          _SidebarItem(
            icon: Icons.settings_outlined,
            activeIcon: Icons.settings_rounded,
            label: '设置',
            selected: false,
            primaryColor: primaryColor,
            onTap: onSettings,
          ),
          const SizedBox(height: 6),
          // ===== 底部说明 =====
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Text(
              '数据仅存本机 · 无广告',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

/// 导航项：悬停中性底色 + 选中主色胶囊（无水波纹，桌面端更利落）
class _SidebarItem extends StatefulWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final Color primaryColor;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.primaryColor,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selected = widget.selected;
    final iconColor = selected
        ? widget.primaryColor
        : (isDark ? Colors.white60 : const Color(0xFF6B6B70));
    final textColor = selected
        ? widget.primaryColor
        : (isDark ? Colors.white70 : const Color(0xFF3A3A3C));

    Color background;
    if (selected) {
      background = widget.primaryColor.withValues(alpha: 0.14);
    } else if (_hovered) {
      background = isDark
          ? Colors.white.withValues(alpha: 0.07)
          : Colors.black.withValues(alpha: 0.045);
    } else {
      background = Colors.transparent;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _hovered = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  selected ? widget.activeIcon : widget.icon,
                  size: 20,
                  color: iconColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: textColor,
                    ),
                  ),
                ),
                if (selected)
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: widget.primaryColor,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
