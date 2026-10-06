import 'package:flutter/material.dart';

/// 可点击区域：鼠标指针、悬停、以及电视遥控器焦点/OK 键
class Clickable extends StatefulWidget {
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final Widget child;
  final MouseCursor cursor;
  final HitTestBehavior behavior;

  const Clickable({
    super.key,
    required this.child,
    this.onTap,
    this.onDoubleTap,
    this.cursor = SystemMouseCursors.click,
    this.behavior = HitTestBehavior.deferToChild,
  });

  @override
  State<Clickable> createState() => _ClickableState();
}

class _ClickableState extends State<Clickable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onDoubleTap != null;
    final focusColor = Theme.of(context).colorScheme.primary;
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: widget.cursor,
      onShowFocusHighlight: (v) {
        if (_focused == v) return;
        setState(() => _focused = v);
      },
      actions: {
        if (widget.onTap != null)
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap!();
              return null;
            },
          ),
      },
      child: GestureDetector(
        behavior: widget.behavior,
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: _focused ? Border.all(color: focusColor, width: 2) : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
