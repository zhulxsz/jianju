import 'package:flutter/material.dart';

import '../core/models/drama.dart';
import 'cover_image.dart';

/// 海报网格卡片（首页桌面网格 / 分类 / 搜索结果共用）
///
/// 鼠标悬停：封面轻微放大 + 播放遮罩 + 标题变主色，光标变为可点击形态；
/// 触屏设备上悬停态不会触发，表现与普通卡片一致。
class PosterCard extends StatefulWidget {
  final Drama drama;
  final VoidCallback onTap;

  /// 资源站点名（搜索结果标明来源站点），null 不显示
  final String? sourceLabel;

  const PosterCard({
    super.key,
    required this.drama,
    required this.onTap,
    this.sourceLabel,
  });

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;
  bool _focused = false;

  void _setHover(bool v) {
    if (_hovered == v) return;
    setState(() => _hovered = v);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final secondary = isDark ? Colors.white54 : Colors.black45;
    final primary = theme.colorScheme.primary;
    final drama = widget.drama;
    final highlighted = _hovered || _focused;

    return Semantics(
      button: true,
      label: drama.title,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: _setHover,
        onShowFocusHighlight: (v) {
          if (_focused == v) return;
          setState(() => _focused = v);
        },
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 封面：悬停时在圆角内轻微放大，制造"聚焦"感
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: AnimatedScale(
                        scale: highlighted ? 1.05 : 1,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        child: CoverImage(
                          url: drama.coverUrl,
                          width: double.infinity,
                          height: double.infinity,
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                    ),
                    // 悬停播放遮罩
                    AnimatedOpacity(
                      opacity: highlighted ? 1 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: LinearGradient(
                            begin: Alignment.center,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.05),
                              Colors.black.withValues(alpha: 0.55),
                            ],
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.play_circle_fill_rounded,
                                    color: Colors.white, size: 30),
                                const SizedBox(width: 6),
                                Text(
                                  drama.episodeCount > 0
                                      ? '全${drama.episodeCount}集'
                                      : '立即播放',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 悬停高亮描边
                    AnimatedOpacity(
                      opacity: highlighted ? 1 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.7),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              Text(
                drama.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: highlighted ? primary : null,
                ),
              ),
              const SizedBox(height: 3),
              _MetaRow(drama: drama, secondary: secondary, primary: primary),
              if (widget.sourceLabel != null) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.dns_outlined, size: 11, color: primary),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        '来源 ${widget.sourceLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: primary),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 卡片底部元信息：热度优先，其次状态 / 集数
class _MetaRow extends StatelessWidget {
  final Drama drama;
  final Color secondary;
  final Color primary;

  const _MetaRow({
    required this.drama,
    required this.secondary,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (drama.readCountText.isNotEmpty) {
      children.addAll([
        Icon(Icons.local_fire_department_rounded, size: 12, color: primary),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            drama.readCountText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: primary),
          ),
        ),
      ]);
    } else if (drama.statusText.isNotEmpty) {
      children.add(Flexible(
        child: Text(
          drama.statusText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: secondary),
        ),
      ));
    } else if (drama.episodeCount > 0) {
      children.add(Flexible(
        child: Text(
          '${drama.episodeCount}集',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: secondary),
        ),
      ));
    }

    if (children.isEmpty) return const SizedBox(height: 14);
    return Row(children: children);
  }
}
