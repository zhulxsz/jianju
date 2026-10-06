import 'dart:ui';

import 'package:flutter/material.dart';

/// 苹果风格悬浮导航条
///
/// 悬浮胶囊形态 + 毛玻璃质感 + 选中态高亮胶囊，
/// 双端统一（Android / Windows），随主题主色实时变化。
class FloatingNavBar extends StatelessWidget {
  final List<NavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Color primaryColor;

  const FloatingNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final barColor = isDark ? Colors.white : const Color(0xFFF9F9F9);
    final iconInactive = isDark ? Colors.white60 : Colors.black45;

    return Semantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: barColor.withValues(alpha: isDark ? 0.16 : 0.72),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(
                color: isDark ? Colors.white24 : Colors.white.withValues(alpha: 0.6),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < items.length; i++)
                  _NavItemView(
                    item: items[i],
                    selected: i == currentIndex,
                    primaryColor: primaryColor,
                    iconInactive: iconInactive,
                    onTap: () => onTap(i),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

class _NavItemView extends StatefulWidget {
  final NavItem item;
  final bool selected;
  final Color primaryColor;
  final Color iconInactive;
  final VoidCallback onTap;

  const _NavItemView({
    required this.item,
    required this.selected,
    required this.primaryColor,
    required this.iconInactive,
    required this.onTap,
  });

  @override
  State<_NavItemView> createState() => _NavItemViewState();
}

class _NavItemViewState extends State<_NavItemView> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final primaryColor = widget.primaryColor;
    final item = widget.item;
    final iconInactive = widget.iconInactive;
    final onTap = widget.onTap;
    return Expanded(
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (v) {
          if (_focused == v) return;
          setState(() => _focused = v);
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onTap();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            padding: EdgeInsets.symmetric(horizontal: selected ? 14 : 0),
            decoration: BoxDecoration(
              color: selected
                  ? primaryColor.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(24),
              border: _focused
                  ? Border.all(color: primaryColor, width: 1.5)
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected ? item.activeIcon : item.icon,
                  size: 22,
                  color: selected ? primaryColor : iconInactive,
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  child: selected
                      ? Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            item.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: primaryColor,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
