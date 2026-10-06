import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 电视遥控器 / 方向键适配：把 OK、Select、手柄 A 映射为激活当前焦点。
class RemoteActivateScope extends StatelessWidget {
  final Widget child;

  const RemoteActivateScope({super.key, required this.child});

  static const Map<ShortcutActivator, Intent> shortcuts = {
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  };

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: shortcuts,
      child: _DpadFocusBootstrap(child: child),
    );
  }
}

class _DpadFocusBootstrap extends StatefulWidget {
  final Widget child;

  const _DpadFocusBootstrap({required this.child});

  @override
  State<_DpadFocusBootstrap> createState() => _DpadFocusBootstrapState();
}

class _DpadFocusBootstrapState extends State<_DpadFocusBootstrap> {
  static bool _isNavKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.select;

  void _ensureFocus() {
    final scope = FocusScope.of(context);
    if (scope.focusedChild == null) {
      scope.nextFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (!_isNavKey(event.logicalKey)) return KeyEventResult.ignored;
        final scope = FocusScope.of(context);
        if (scope.focusedChild == null) {
          _ensureFocus();
          // Select/OK 交给刚获焦的控件激活；方向键到此为止，避免连跳两格
          if (event.logicalKey == LogicalKeyboardKey.select) {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: widget.child,
    );
  }
}
