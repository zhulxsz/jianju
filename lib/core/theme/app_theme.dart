import 'package:flutter/material.dart';

/// 预设主题色板（设置页可选，选中后 APP 全局主色实时切换）
class PaletteColor {
  final String name;
  final Color color;
  const PaletteColor(this.name, this.color);
}

class AppPalette {
  AppPalette._();

  static const List<PaletteColor> colors = [
    PaletteColor('苹果蓝', Color(0xFF0A84FF)),
    PaletteColor('靛蓝', Color(0xFF5E5CE6)),
    PaletteColor('紫罗兰', Color(0xFFBF5AF2)),
    PaletteColor('玫瑰粉', Color(0xFFFF2D55)),
    PaletteColor('珊瑚红', Color(0xFFFF453A)),
    PaletteColor('活力橙', Color(0xFFFF9F0A)),
    PaletteColor('柠檬黄', Color(0xFFFFD60A)),
    PaletteColor('清新绿', Color(0xFF30D158)),
    PaletteColor('薄荷青', Color(0xFF00C7BE)),
    PaletteColor('天空蓝', Color(0xFF64D2FF)),
    PaletteColor('岩灰', Color(0xFF8E8E93)),
    PaletteColor('咖啡棕', Color(0xFFA2845E)),
  ];
}

/// 主题构建（iOS 风：圆润卡片、大字号标题、克制分割线）
///
/// [wide] 为宽窗口（桌面）标记：标题左对齐 + AppBar 底部细分隔线 +
/// 鼠标悬停态与滚动条按桌面习惯微调。
class AppTheme {
  AppTheme._();

  static ThemeData light(Color seed, {bool wide = false}) =>
      _build(seed, Brightness.light, wide: wide);

  static ThemeData dark(Color seed, {bool wide = false}) =>
      _build(seed, Brightness.dark, wide: wide);

  static ThemeData _build(Color seed, Brightness brightness,
      {required bool wide}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;
    final base =
        isDark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);

    final scaffold = isDark ? const Color(0xFF000000) : const Color(0xFFF5F5F7);
    final divider = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.07);

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      // 桌面端鼠标悬停底色：中性微亮，不抢主色
      hoverColor: isDark
          ? Colors.white.withValues(alpha: 0.07)
          : Colors.black.withValues(alpha: 0.04),
      highlightColor: isDark
          ? Colors.white.withValues(alpha: 0.05)
          : Colors.black.withValues(alpha: 0.03),
      focusColor: seed.withValues(alpha: 0.22),
      appBarTheme: AppBarTheme(
        // 桌面端标题左对齐（更接近原生桌面应用），移动端保持居中
        centerTitle: !wide,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scaffold,
        foregroundColor: isDark ? Colors.white : const Color(0xFF1C1C1E),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : const Color(0xFF1C1C1E),
        ),
        // 宽窗口下补一条底部细线，与侧边栏分割线连成整体框架
        shape: wide
            ? Border(bottom: BorderSide(color: divider, width: 0.5))
            : null,
      ),
      cardTheme: CardThemeData(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
      ),
      dividerTheme: DividerThemeData(color: divider, thickness: 0.5),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFE9E9EB),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      // 文本选中态跟随主色（桌面端复制文字时更清晰）
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: seed,
        selectionColor: seed.withValues(alpha: 0.35),
        selectionHandleColor: seed,
      ),
      // 桌面滚动条：细、可拖拽、悬停时加粗加深
      scrollbarTheme: ScrollbarThemeData(
        interactive: true,
        radius: const Radius.circular(10),
        crossAxisMargin: 3,
        mainAxisMargin: 3,
        trackVisibility: const WidgetStatePropertyAll(false),
        thickness: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.dragged)
                ? 9.0
                : 5.0),
        thumbColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.dragged)
                ? (isDark ? Colors.white54 : Colors.black45)
                : (isDark ? Colors.white24 : Colors.black38)),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFF1C1C1E),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(fontSize: 12, color: Colors.white),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
