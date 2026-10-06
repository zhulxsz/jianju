import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianju/core/models/drama.dart';
import 'package:jianju/widgets/clickable.dart';
import 'package:jianju/widgets/floating_nav_bar.dart';
import 'package:jianju/widgets/poster_card.dart';
import 'package:jianju/widgets/remote_scope.dart';
import 'package:jianju/widgets/search_trigger.dart';

Drama _drama() => const Drama(
      bookId: '1',
      title: '测试短剧',
      coverUrl: '',
      abstractText: '简介',
      tags: [],
      episodeCount: 12,
      readCountText: '',
      statusText: '完结',
      categoryText: '',
    );

Future<void> _pump(WidgetTester tester, Widget child, {Size size = const Size(1280, 720)}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        navigationMode: NavigationMode.directional,
      ),
      child: child ?? const SizedBox.shrink(),
    ),
    home: Scaffold(body: child),
  ));
}

void main() {
  testWidgets('遥控器 Select 映射为 ActivateIntent', (tester) async {
    var tapped = false;
    await _pump(
      tester,
      RemoteActivateScope(
        child: Center(
          child: Clickable(
            onTap: () => tapped = true,
            child: const SizedBox(width: 80, height: 40, child: Text('确定')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('海报卡片方向键获焦后 Select 触发 onTap', (tester) async {
    var tapped = false;
    await _pump(
      tester,
      RemoteActivateScope(
        child: SizedBox(
          width: 180,
          height: 280,
          child: PosterCard(drama: _drama(), onTap: () => tapped = true),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('底部导航项可被遥控器激活', (tester) async {
    var index = -1;
    await _pump(
      tester,
      RemoteActivateScope(
        child: FloatingNavBar(
          items: const [
            NavItem(
                icon: Icons.home_outlined,
                activeIcon: Icons.home_rounded,
                label: '首页'),
            NavItem(
                icon: Icons.grid_view_outlined,
                activeIcon: Icons.grid_view_rounded,
                label: '分类'),
          ],
          currentIndex: 0,
          primaryColor: const Color(0xFF0A84FF),
          onTap: (i) => index = i,
        ),
      ),
      size: const Size(400, 200),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(index, isNonNegative);
  });

  testWidgets('搜索入口可获焦', (tester) async {
    await _pump(
      tester,
      RemoteActivateScope(child: const Center(child: SearchTrigger())),
    );
    await tester.pump();
    expect(find.byType(FocusableActionDetector), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
