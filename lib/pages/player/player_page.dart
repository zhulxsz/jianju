import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/constants/api_constants.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/drama.dart';
import '../../core/models/episode.dart';
import '../../core/services/api_service.dart';
import '../../core/services/history_service.dart';
import '../../core/services/pip_service.dart';
import '../../core/services/play_headers.dart';
import '../../core/services/play_lines.dart';
import '../../core/services/prebuffer_service.dart';
import '../../core/state/settings_provider.dart';
import '../../core/theme/responsive.dart';

/// 播放模块（核心）
///
/// 1. 播放直链：前 3 集官方 MP4 直链，其余集数由内置线路（30 条）按测速竞速兜底
/// 2. 倍速 0.75x ~ 5x（默认值读取设置页全局配置）
/// 3. 进度拖拽 + 进度记忆、全屏播放、音量调节
/// 4. 播放线路：默认自动选最快，可手动锁定任意一条
/// 5. 播放完毕自动跳转下一集
class PlayerPage extends StatefulWidget {
  final Drama drama;
  final List<Episode> episodes;
  final Episode initialEpisode;

  const PlayerPage({
    super.key,
    required this.drama,
    required this.episodes,
    required this.initialEpisode,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _controller;
  StreamSubscription? _completedSub;
  final List<StreamSubscription> _subs = [];
  Timer? _progressTimer;
  Timer? _hideTimer;
  final FocusNode _playerFocus = FocusNode(debugLabel: 'playerRemote');
  final FocusNode _playButtonFocus = FocusNode(debugLabel: 'playerPlay');

  late Episode _episode;
  double _speed = 1.0;
  double _volume = 100;
  bool _loading = true;
  String _error = '';
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _dragValue;
  bool _controlsVisible = true;

  /// 鼠标是否悬停在播放区：悬停期间控件不自动隐藏（桌面端）
  bool _hovering = false;

  /// 画中画小窗模式（小窗内隐藏所有浮层，只留画面）
  bool _pipMode = false;
  bool _fullscreen = false;

  /// 本集结尾已处理标记：防 completed 与位置兜底双触发、重复换集
  bool _endHandled = false;

  /// 换集序号：过期异步结果直接丢弃，防止快速换集时旧解析覆盖新集
  int _openSeq = 0;

  /// 直链打不开（mpv「Failed to open」）的自动换线重试次数（连续最多 2 次）
  int _openFails = 0;

  /// 本集累计自动换线次数：与 _openFails 配合，防「起播 3s 又失败」
  /// 反复换线抖动，单集硬上限 4 次（换集/手动重试归零）
  int _openAutoTries = 0;

  /// 本次 open 实际使用的直链：失败时用它自检原因、换线时排除它
  String? _lastPlayUrl;

  /// 加载期（_loading 为 true）收到的「Failed to open」：挂起，
  /// open 流程收尾时再触发自动换线，避免错误被 _loading 门槛吞掉
  String? _pendingOpenError;

  /// 本次起播是否用了本地改写清单（剔广告）：起播失败可回退原始网络流
  bool _playedRewritten = false;

  /// 已回退过一次（改写清单 → 原始网络流），防反复套娃
  bool _rewrittenRetried = false;

  // ==================== 预载下一集 ====================
  bool _preloadStarted = false;
  bool _preloadReady = false;
  String? _preloadedUrl;
  int _preloadedIndex = -1;
  bool _preloadLocal = false; // 下一集已跨集预缓存到本地
  DateTime? _preloadFailedAt;

  // ==================== 进度跳回防护 ====================
  /// 最近稳定播放位置：正常播放时取到达过的最大值，用户拖动/恢复 seek
  /// 时更新为目标位，供“跳回 0/早期重置”检测与恢复
  Duration _lastStable = Duration.zero;

  /// mpv demuxer 缓冲到的绝对位置（进度条上显示为“已缓冲”浅色段）
  Duration _bufferEnd = Duration.zero;

  /// 最近一次由我们发起的 seek 时间（其后的回跳是正常行为）
  DateTime? _seekIssuedAt;

  /// seek 所有权令牌：每次新 seek（换集/拖动/恢复）自增，
  /// 旧的校验循环检测到令牌过期即退出，防止多路校验互相打架
  int _seekToken = 0;

  /// 跳回恢复统计：该 CDN 连接有字节配额、断点固定，越过断点的唯一手段
  /// 是 seek（成功率不高且常“落位即回退”）。因此恢复改为持久重试+退避：
  /// 连续整轮失败到顶或总次数到顶才停手
  int _recoverCount = 0;
  int _recoverFailStreak = 0;
  DateTime? _lastRecoverAt;
  bool _recoverDisabled = false;
  /// 恢复 seek 校验进行中：期间的跳回事件由校验重试接管，不再重复计划
  bool _recoverInFlight = false;

  /// 计划中的延迟恢复：断流瞬间 mpv 正在重载，立即 seek 会把刚起来的
  /// 流再次砸死（实测 300ms 内重载回 0）。改为等新连接从 0 稳定起播
  /// 若干秒后，再在健康连接上单发 seek 回目标（健康连接上 seek 实测可用）
  Timer? _recoveryTimer;

  /// 断流类错误的自动恢复观察：可恢复错误先不弹全屏错误，
  /// 6s 内 mpv 没自己续播才转成真错误提示
  Timer? _errorWatchdog;

  /// 退后台前是否在播放（回前台自动续播用）
  bool _wasPlaying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _player = Player();
    _controller = VideoController(_player);
    _volume = _player.state.volume;
    _speed = context.read<SettingsProvider>().defaultSpeed;

    _bindStreams();
    _openEpisode(widget.initialEpisode, resumeSaved: true);
    PipService.ensureAttached();
    PipService.onChanged = _onPipChanged;
  }

  // ==================== 生命周期（退后台 / 回前台） ====================

  void _onPipChanged(bool inPip) {
    if (!mounted) return;
    debugPrint('[PIP] mode -> $inPip');
    setState(() {
      _pipMode = inPip;
      if (inPip) _controlsVisible = false;
    });
    if (!inPip && _playing) _scheduleHideControls();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!mounted) return;
    if (state == AppLifecycleState.paused) {
      _wasPlaying = _playing;
      debugPrint(
          '[EP] lifecycle paused pos=${_fmt(_position)} playing=$_playing');
    } else if (state == AppLifecycleState.resumed) {
      debugPrint('[EP] lifecycle resumed err=${_error.isNotEmpty} '
          'pos=${_fmt(_position)} loading=$_loading');
      if (_error.isNotEmpty && !_loading) {
        // 后台期间播放失败：回前台自动重试，并从当前（或最近）位置续播
        debugPrint('[EP] resume: auto-retry from ${_fmt(_position)}');
        _openEpisode(_episode, resumeSaved: true, resumeAt: _position);
      } else if (_wasPlaying && !_playing && !_loading) {
        _player.play();
      }
    }
  }

  void _bindStreams() {
    _subs
      ..add(_player.stream.playing.listen((v) {
        if (!mounted) return;
        if (v) _errorWatchdog?.cancel(); // 已恢复播放，撤销断流错误观察
        setState(() => _playing = v);
        // 告知原生是否在播放（Home 键自动进画中画的依据）
        PipService.setActive(v && !_loading);
      }))
      ..add(_player.stream.position.listen(_onPosition))
      ..add(_player.stream.duration
          .listen((v) => mountedSafe(() => setState(() => _duration = v))))
      ..add(_player.stream.buffer
          .listen((v) => mountedSafe(() => setState(() => _bufferEnd = v))))
      ..add(_player.stream.error.listen((e) {
        if (e.isEmpty || !mounted) return;
        // 起播即打不开：多半是 CDN 防盗链（403）或地址已失效——排除该地址
        // 自动换线重解析，仍打不开才转错误页。加载期（含 seek 等待）收到的
        // 先挂起，open 流程收尾时再处理，避免错误被 _loading 门槛吞掉。
        // 「Failed to recognize file format」= 打开成功但内容不是可识别媒体
        // （直链回 HTML、本地改写清单缺密钥取不到明文等），同样按起播失败处理
        if (RegExp(r'failed to open|failed to recognize file format',
                caseSensitive: false)
            .hasMatch(e)) {
          debugPrint('[EP] player open failed: $e (loading=$_loading)');
          PipService.setActive(false);
          if (_loading) {
            _pendingOpenError ??= e;
          } else {
            final pending = _pendingOpenError;
            _pendingOpenError = null;
            _onOpenFailed(pending ?? e);
          }
          return;
        }
        if (_loading) return;
        debugPrint('[EP] player error: $e');
        PipService.setActive(false);
        // CDN 中途掐线（ffurl_read -103/ECONNABORTED、超时等）mpv 会
        // 自动重载续播，属可恢复错误：先只记日志，6s 没恢复才转错误页
        final recoverable = RegExp(
                r'ffurl_read|tcp:|timeout|timed out|Connection|'
                r'ECONNABORTED|Network is unreachable|Broken pipe',
                caseSensitive: false)
            .hasMatch(e);
        if (!recoverable) {
          mountedSafe(() => setState(() => _error = '播放出错：$e'));
          return;
        }
        final seq = _openSeq;
        final pAt = _player.state.position;
        _errorWatchdog?.cancel();
        _errorWatchdog = Timer(const Duration(seconds: 6), () {
          if (!mounted || seq != _openSeq || _error.isNotEmpty) return;
          if (!_loading && !_playing && _player.state.position == pAt) {
            debugPrint('[EP] 断流 6s 未自动恢复，转为错误提示');
            setState(() => _error = '播放出错：$e');
          }
        });
      }));
    // 播放完毕自动跳转下一集（换集瞬间的过期 completed 由 _loading/_endHandled 拦截）
    _completedSub = _player.stream.completed.listen((completed) {
      if (!completed || !mounted) return;
      _onEpisodeEnd();
    });
  }

  void mountedSafe(VoidCallback fn) {
    if (mounted) fn();
  }

  /// mpv 打不开直链（`Failed to open <url>`）：排除该地址重新解析，
  /// 逼其他线路/来源给出新地址（连续最多 2 次、单集最多 4 次）；用尽才
  /// 转错误页，并用与播放器一致的请求头自检一次，把原因（403 防盗链/
  /// 地址失效/网络不通）补进错误文案，便于判断该换线路还是该检查网络
  Future<void> _onOpenFailed(String e) async {
    // 本地改写清单（剔广告）起播失败：清单里取不到密钥/内容不可识别时，
    // 已验证的原始网络流可以直起——先回退它重试一次，不计入换线预算
    if (_playedRewritten && !_rewrittenRetried) {
      _rewrittenRetried = true;
      debugPrint('[EP] 改写清单起播失败，回退原始网络流重试: $e');
      await _openEpisode(_episode, resumeAt: _position, noRewrite: true);
      return;
    }
    final seq = _openSeq;
    final url = _lastPlayUrl;
    final canRetry = url != null &&
        url.startsWith('http') &&
        _openFails < 2 &&
        _openAutoTries < 4;
    if (canRetry) {
      _openFails++;
      _openAutoTries++;
      debugPrint('[EP] 直链打不开，换线重试（第 $_openAutoTries 次）: $url');
      await _openEpisode(
        _episode,
        resumeAt: _position,
        excludeUrl: url,
      );
      return;
    }
    mountedSafe(() => setState(() => _error = '播放出错：$e'));
    final why = await PlayHeaders.diagnose(url ?? '');
    if (!mounted || seq != _openSeq || why.isEmpty) return;
    mountedSafe(() => setState(() => _error = '播放出错：$e\n$why'));
  }

  /// 诊断节流：位置日志最多每 3 秒一条（排查"进度卡死"类问题）
  int _lastPosLogSec = -99;

  void _onPosition(Duration v) {
    final prev = _position;
    if ((v.inSeconds - _lastPosLogSec).abs() >= 3) {
      _lastPosLogSec = v.inSeconds;
      debugPrint(
          '[POS] ${_fmt(v)}/${_fmt(_duration)} loading=$_loading playing=$_playing');
    }
    mountedSafe(() => setState(() => _position = v));
    if (v + const Duration(seconds: 1) < prev) {
      // 拖回进度重看：解除片尾防重入，允许再次自动下一集
      _endHandled = false;
    }
    if (v > _lastStable) _lastStable = v;
    // 稳定起播即视为本轮换线成功：归还自动换线预算，供后续故障使用
    if (_openFails > 0 && v > const Duration(seconds: 3)) _openFails = 0;
    _recoverJumpBack(prev, v);
    _maybePreloadNext(v);
    _maybeFinish(v);
  }

  /// 片尾兜底：completed 流未触发时，以播放位置逼近结尾判定
  void _maybeFinish(Duration v) {
    if (_loading || _endHandled || _duration <= Duration.zero) return;
    if (v >= _duration - const Duration(milliseconds: 300)) {
      _onEpisodeEnd();
    }
  }

  /// 长视频中途“莫名跳回开头”防护：
  /// 服务器断流重连/mpv 重载时位置可能被重置到 0 或大幅后退，
  /// 若非用户主动拖动（[_seekIssuedAt] 窗口内），自动 seek 回最近稳定位置。
  void _recoverJumpBack(Duration prev, Duration v) {
    if (_loading || _dragValue != null || _endHandled) return;
    if (_recoverDisabled) return;
    // 仅真实跳变事件才进入判定：正常播放的逐 tick 位置事件
    // （如重载后 00:00→00:04 连续推进）不重复触发，防止连败数被刷爆
    if (prev - v <= const Duration(seconds: 2)) return;
    final sinceSeek = _seekIssuedAt == null
        ? const Duration(days: 1)
        : DateTime.now().difference(_seekIssuedAt!);
    if (sinceSeek < const Duration(seconds: 6)) return;
    if (_duration < const Duration(seconds: 60)) return;

    final bigBack = prev - v > const Duration(seconds: 30);
    // 断流重载把 playhead 砸回开头：早期段（开场前几秒）同样要恢复，
    // 否则新集开场反复重播片头（prev > 3s 才算真实播放过，避开起播 0 事件）
    final restartToZero =
        v < const Duration(seconds: 5) && prev > const Duration(seconds: 3);
    if (!bigBack && !restartToZero) return;
    // 安全区：重载落在非零锚点（mpv 会记住上次成功 seek 的位置）且差距
    // 不大时，自然续播即可免费覆盖已看段落，不冒 seek 砸死流的风险
    if (v >= const Duration(seconds: 10) &&
        prev - v <= const Duration(seconds: 45)) {
      return;
    }
    // 距最近稳定位不足 2s 视为正常抖动/起播，不干预
    if (_lastStable <= v + const Duration(seconds: 2)) return;

    // 恢复 seek 校验进行中：跳回由校验重试接管，不重复计划
    if (_recoverInFlight) return;
    // 已有计划中的恢复：不重复调度/计数
    if (_recoveryTimer != null) return;

    final now = DateTime.now();
    // 两次恢复至少隔 15s；连续整轮失败 10 次或累计 40 次 → 停手放养。
    // 断点固定时越过断点只能靠 seek（失败仅损失“已看段的重看”，不亏），
    // 故预算给足；失败节奏由退避（12→30s）压住，避免打爆 CDN
    if (_lastRecoverAt != null &&
        now.difference(_lastRecoverAt!) < const Duration(seconds: 15)) {
      return;
    }
    if (_recoverFailStreak >= 10 || _recoverCount >= 40) {
      _recoverDisabled = true;
      debugPrint('[POS] 恢复预算用尽（总数 $_recoverCount'
          '/连续失败 $_recoverFailStreak）→ 停止干预，自然续播');
      return;
    }
    _recoverCount++;
    _lastRecoverAt = now;
    final target = _lastStable;

    debugPrint('[POS] 异常跳回 ${_fmt(v)}（上一帧 ${_fmt(prev)}）'
        ' → 计划 8s 后恢复到 ${_fmt(target)}（第 $_recoverCount 次）');
    final seq = _openSeq;
    _recoveryTimer =
        Timer(const Duration(seconds: 8), () => _executeRecovery(target, seq, 0));
  }

  /// 执行计划中的恢复：流必须已稳定起播（>3s）才 seek——重载中 seek 会把
  /// 刚起来的流再次砸死（实测 300ms 内重载回 0）。未稳定则最多重试 3 轮。
  /// seek 后必须“落位且推进”才算成功（防“落位即冻结→回退”的过早放行）；
  /// 失败则退避后重试——该 CDN 断点固定，seek 是唯一出路
  Future<void> _executeRecovery(Duration target, int seq, int attempt) async {
    _recoveryTimer = null;
    if (!mounted || seq != _openSeq || _recoverDisabled) return;
    if (_loading || _endHandled || _dragValue != null) return;
    final p = _player.state.position;
    if (p < const Duration(seconds: 3)) {
      if (attempt < 2) {
        debugPrint('[POS] 恢复暂缓：流未稳定起播（当前 ${_fmt(p)}），'
            '8s 后重试（第 ${attempt + 2} 次）');
        _recoveryTimer = Timer(const Duration(seconds: 8),
            () => _executeRecovery(target, seq, attempt + 1));
        return;
      }
      debugPrint('[POS] 放弃本轮恢复：流一直未稳定起播');
      _undoRecoveryCycle();
      return;
    }
    if (p + const Duration(seconds: 10) >= target) {
      debugPrint('[POS] 恢复取消：流已自行推进到 ${_fmt(p)}');
      _undoRecoveryCycle();
      return;
    }
    _recoverInFlight = true;
    // 等 readahead 覆盖目标再 seek：缓存内 seek 走本地（拖动实测必成、无
    // Resize）；越过缓存的网络 range 在该 CDN 上必触发 tcp -103 掐线，
    // 形成 seek→重载→回 0 死循环（实测 0/24 次全败即此因）。
    // 边界必须取 target+3s：缓冲刚到 target-3s 就放行时 seek 点仍在缓存外
    // （实测缓冲 01:08/目标 01:11 即败），须留安全余量
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (_bufferEnd < target + const Duration(seconds: 3)) {
      if (DateTime.now().isAfter(deadline)) {
        debugPrint('[POS] 等缓冲覆盖超时（缓冲 ${_fmt(_bufferEnd)}'
            ' < 目标 ${_fmt(target)}），仍尝试 seek');
        break;
      }
      if (!mounted || seq != _openSeq || _recoverDisabled || _loading ||
          _endHandled || _dragValue != null) {
        _recoverInFlight = false;
        return;
      }
      final cur = _player.state.position;
      if (cur + const Duration(seconds: 10) >= target) {
        debugPrint('[POS] 恢复取消：等待缓冲期间已推进到 ${_fmt(cur)}');
        _recoverInFlight = false;
        _undoRecoveryCycle();
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    debugPrint('[POS] 执行恢复 seek -> ${_fmt(target)}'
        '（当前 ${_fmt(_player.state.position)}，缓冲 ${_fmt(_bufferEnd)}）');
    final ok =
        await _seekWithVerify(target, seq, requireAdvance: true);
    _recoverInFlight = false;
    if (!mounted || seq != _openSeq) return;
    if (ok) {
      _recoverFailStreak = 0;
      debugPrint('[POS] 恢复成功：已站稳 ${_fmt(_player.state.position)}');
      return;
    }
    if (_dragValue != null || _endHandled) return; // 用户接管，不再重试
    _recoverFailStreak++;
    if (_recoverFailStreak >= 10 || _recoverCount >= 40) {
      _recoverDisabled = true;
      debugPrint('[POS] 恢复预算用尽（总数 $_recoverCount'
          '/连续失败 $_recoverFailStreak）→ 停止干预，自然续播');
      return;
    }
    // 退避重试：12/16/20/25/30s 封顶；失败只损失已看段的重看，不亏
    const backoff = [12, 16, 20, 25, 30];
    final delaySec = backoff[(_recoverFailStreak - 1).clamp(0, 4)];
    _recoverCount++;
    _lastRecoverAt = DateTime.now();
    debugPrint('[POS] 恢复未站稳（连续失败 $_recoverFailStreak），'
        '${delaySec}s 后重试 → ${_fmt(target)}');
    _recoveryTimer = Timer(Duration(seconds: delaySec),
        () => _executeRecovery(target, seq, attempt + 1));
  }

  /// 撤销一个“从未出手”的恢复周期：归还预算与冷却窗口
  void _undoRecoveryCycle() {
    if (_recoverCount > 0) _recoverCount--;
    _lastRecoverAt = null;
  }

  // ==================== 预载下一集 ====================

  /// 距结尾达到预载提前量时，提前解析下一集直链（结果进线路会话缓存，
  /// 本集播完后换集只需 open，无需再等解析）
  void _maybePreloadNext(Duration v) {
    if (!mounted || _loading || _duration <= Duration.zero) return;
    final settings = context.read<SettingsProvider>();
    if (!settings.preloadNext) return;
    if (_preloadReady) return;
    if (_preloadStarted) return; // 已在解析中
    final failedAt = _preloadFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(seconds: 5)) {
      return; // 失败后 5 秒冷却，避免每帧重试
    }
    _preloadFailedAt = null;
    final next = _nextPlayable;
    if (next == null) return;
    final remain = _duration - v;
    if (remain > Duration(seconds: settings.preloadLeadSec) ||
        remain <= Duration.zero) {
      return;
    }
    _preloadStarted = true;
    _preloadFailedAt = null;
    final seq = _openSeq;
    debugPrint('[PRE] 预载第${next.index}集（剩 ${remain.inSeconds}s）');
    _preload(next, seq);
    _startPrebufferChain(); // 结尾补跑跨集预缓存（开播时触发失败则此处重试）
  }

  /// 跨集预缓存：缓冲设置 = 当前集读取余量 + 后续几集本地预下载预算。
  /// 播放开始即触发（不等结尾），顺序把下一集、下下集…下载到本地，
  /// 换集时直接本地起播，黑屏降到毫秒级。
  void _startPrebufferChain() {
    final bufferSecs = context.read<SettingsProvider>().bufferSecs;
    if (bufferSecs < PrebufferService.minBudgetSecs) return;
    debugPrint('[PBF] 触发跨集预缓存（第${_episode.index}集起，'
        '预算 ${bufferSecs}s）');
    PrebufferService.prefetchChain(
      bookId: widget.drama.bookId,
      title: widget.drama.title,
      episodes: widget.episodes,
      fromIndex: _episode.index,
      bufferSecs: bufferSecs,
    );
  }

  Future<void> _preload(Episode next, int seq) async {
    // 跨集预缓存已就位：本地文件可直接开播，无需再解析直链
    final local =
        await PrebufferService.localPathFor(widget.drama.bookId, next.index);
    if (local != null && mounted && seq == _openSeq) {
      setState(() {
        _preloadedUrl = null;
        _preloadedIndex = next.index;
        _preloadLocal = true;
        _preloadReady = true;
      });
      debugPrint('[PBF] 第${next.index}集已在本地缓存，无需解析');
      return;
    }
    try {
      final url = await ApiService.fetchPlayUrl(
        seriesId: widget.drama.bookId,
        vid: next.itemId,
        title: widget.drama.title,
        episodeIndex: next.index,
      );
      if (!mounted || seq != _openSeq) return;
      setState(() {
        _preloadedUrl = url;
        _preloadedIndex = next.index;
        _preloadLocal = false;
        _preloadReady = true;
      });
      debugPrint('[PRE] 预载完成 #${next.index}');
    } catch (e) {
      debugPrint('[PRE] 预载失败 #${next.index}: $e');
      if (!mounted || seq != _openSeq) return;
      _preloadStarted = false;
      _preloadFailedAt = DateTime.now();
    }
  }

  /// 右上角提示：“即将播放下一集 · 倒计时”
  Widget _buildPreloadHint() {
    if (_loading || _error.isNotEmpty || !_preloadStarted) {
      return const SizedBox.shrink();
    }
    if (_duration <= Duration.zero) return const SizedBox.shrink();
    final lead = context.read<SettingsProvider>().preloadLeadSec;
    final remain = _duration - _position;
    if (remain > Duration(seconds: lead) || remain <= Duration.zero) {
      return const SizedBox.shrink();
    }
    final next = _nextPlayable;
    if (next == null) return const SizedBox.shrink();
    final label = _preloadReady
        ? (_preloadLocal
            ? '已缓存第${next.index}集 · ${remain.inSeconds}s'
            : '即将播放第${next.index}集 · ${remain.inSeconds}s')
        : '正在预载第${next.index}集…';
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 54,
      right: 12,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.skip_next_rounded,
                  color: Colors.white70, size: 14),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// mpv 音频/缓冲调优（针对第三方线路 m3u8：缓冲换顿/破音/倍速变调）。
  /// 属性不存在或不允许运行时修改时静默忽略，不影响播放。
  Future<void> _applyMpvTweaks() async {
    final p = _player.platform;
    if (p is! NativePlayer) return;
    final bufferSecs = context.read<SettingsProvider>().bufferSecs;
    Future<void> set(String key, String value) async {
      try {
        await p.setProperty(key, value);
      } catch (e) {
        debugPrint('mpv setProperty($key) 失败: $e');
      }
    }

    await set('audio-buffer', '500'); // 加大音频输出缓冲，减少换气/破音
    await set('cache-secs', '$bufferSecs'); // 网络流读取余量（设置页可调档位）
    await set('audio-pitch-correction', 'yes'); // 倍速时保持音高
    await set('volume-max', '100'); // 禁止超过 100% 增益导致破音
    // 防盗链 CDN 按 UA 过滤：与 Media.httpHeaders 双保险，避免 UA 走
    // mpv 自带的 mpv/curl 串被 403 拒（Failed to open）
    await set('user-agent', ApiConstants.browserUserAgent);
  }

  // ==================== 换集 / 播放源 ====================

  /// 换集统一入口：命中跨集预缓存则本地起播（免解析、免网络首缓冲）
  Future<void> _openEpisodeSmart(Episode ep) async {
    final local =
        await PrebufferService.localPathFor(widget.drama.bookId, ep.index);
    if (!mounted) return;
    await _openEpisode(ep, localPath: local);
  }

  Future<void> _openEpisode(
    Episode episode, {
    bool resumeSaved = false,
    String? presetUrl,
    Duration? resumeAt,
    String? localPath,
    String? excludeUrl,
    bool noRewrite = false,
  }) async {
    if (!mounted) return;
    debugPrint('[EP] open #${episode.index} resume=$resumeSaved'
        '${localPath != null ? ' local=1' : ''}'
        '${presetUrl != null ? ' preset=1' : ''}'
        '${excludeUrl != null ? ' exclude=1' : ''}'
        '${noRewrite ? ' noRewrite=1' : ''}'
        '${resumeAt != null ? ' at=${_fmt(resumeAt)}' : ''}');
    final seq = ++_openSeq;
    _endHandled = false;
    // 换集/手动重试给足自动换线预算；自动重试本身（带 excludeUrl）不重置
    if (excludeUrl == null) {
      _openFails = 0;
      _openAutoTries = 0;
      _rewrittenRetried = false;
    }
    _pendingOpenError = null; // 上一集挂起的加载期错误不再追责
    PipService.setActive(false); // 解析/换集期间不满足自动小窗条件
    // 预载/进度防护状态属于上一集，换集即重置
    _preloadStarted = false;
    _preloadReady = false;
    _preloadedUrl = null;
    _preloadedIndex = -1;
    _preloadLocal = false;
    _preloadFailedAt = null;
    _lastStable = Duration.zero;
    _seekIssuedAt = null;
    _seekToken++; // 作废上一集遗留的 seek 校验循环
    _recoverCount = 0;
    _recoverFailStreak = 0;
    _lastRecoverAt = null;
    _recoverInFlight = false;
    _recoverDisabled = false;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _errorWatchdog?.cancel();
    _errorWatchdog = null;
    setState(() {
      _episode = episode;
      _loading = true;
      _error = '';
      _position = Duration.zero;
      _duration = Duration.zero;
      _bufferEnd = Duration.zero;
      _dragValue = null;
    });
    // 历史指针跟随当前集：自动下一集后不再停留在旧集
    if (HistoryService.recordOf(widget.drama.bookId)?.lastEpisodeItemId !=
        episode.itemId) {
      await HistoryService.upsert(
        widget.drama,
        episodeIndex: episode.index,
        episodeItemId: episode.itemId,
        positionMs: 0,
      );
    }
    if (!mounted || seq != _openSeq) return;
    _startProgressSaving();
    try {
      // 1) 获取播放直链：本地缓存 > 预载直链 > 官方直链/线路竞速
      final String playUrl;
      if (localPath != null && File(localPath).existsSync()) {
        debugPrint('[PBF] #${episode.index} 本地缓存起播（跳过解析）');
        playUrl = localPath;
      } else if (presetUrl != null) {
        debugPrint('[EP] #${episode.index} 使用预载直链（跳过解析）');
        playUrl = presetUrl;
      } else {
        playUrl = await ApiService.fetchPlayUrl(
          seriesId: widget.drama.bookId,
          vid: episode.itemId,
          title: widget.drama.title,
          episodeIndex: episode.index,
          excludeUrl: excludeUrl,
        );
      }
      if (!mounted || seq != _openSeq) return;
      _lastPlayUrl = playUrl;
      await _applyMpvTweaks();
      if (!mounted || seq != _openSeq) return;
      // 网络流先改写为去广告清单：中插广告段会让 mpv 把流重启回 00:00
      // （"跳回开始播放"死循环，实测自然播放/seek 进广告段必触发）。
      // 本地 .ts/.mp4 及无广告清单会返回 null，原样起播。
      final rewritten = noRewrite
          ? null
          : await PrebufferService.rewritePlaylist(playUrl);
      if (!mounted || seq != _openSeq) return;
      _playedRewritten = rewritten != null;
      // 浏览器请求头（UA + 来源 Referer）：CDN 防盗链时 mpv 裸连会被 403
      // 拒绝，表现为「播放出错：Failed to open <m3u8>」。清单改写成文件时
      // 头按本地清单登记，供 mpv 拉分片时同样带上
      await _player.open(Media(
        rewritten ?? playUrl,
        httpHeaders: PlayHeaders.forUrl(playUrl),
      ));
      if (!mounted || seq != _openSeq) return;
      await _player.setRate(_speed);
      if (!mounted || seq != _openSeq) return;
      // 2) 进度记忆：resumeAt（当前内存进度，重试/换线用）优先，
      //    其次历史保存位置（历史进入/后台恢复用）
      var targetMs = 0;
      if (resumeAt != null && resumeAt > Duration.zero) {
        targetMs = resumeAt.inMilliseconds;
      } else if (resumeSaved) {
        targetMs =
            HistoryService.progressOf(widget.drama.bookId, episode.itemId);
      }
      if (targetMs > 0) {
        await _seekWhenReady(targetMs, seq);
        if (!mounted || seq != _openSeq) return;
      }
      setState(() => _loading = false);
      PipService.setActive(_playing);
      debugPrint('[EP] opened #${episode.index} ready');
      _scheduleHideControls();
      _startPrebufferChain(); // 播放一开始即跨集预缓存（不等结尾）
      // 加载期挂起的「Failed to open」在此兑现：触发自动换线重试
      final pending = _pendingOpenError;
      _pendingOpenError = null;
      if (pending != null && mounted && seq == _openSeq) {
        debugPrint('[EP] 起播期错误延后处理: $pending');
        _onOpenFailed(pending);
      }
    } catch (e) {
      if (!mounted || seq != _openSeq) return;
      debugPrint('[EP] open failed #${episode.index}: $e');
      setState(() {
        _loading = false;
        _error = PlayLineResolver.lastError ?? '播放源获取失败，请稍后重试';
      });
    }
  }

  /// 等新文件可 seek（时长已知）后再 seek，避免打开瞬间 seek 被 mpv 丢弃
  /// 导致“重试/历史进入从头开始播”
  Future<void> _seekWhenReady(int ms, int seq) async {
    final target = Duration(milliseconds: ms);
    try {
      // 慢网络下打开媒体可达 10s+，等待时长事件的预算放宽到 20s
      final d = await _player.stream.duration
          .firstWhere((v) => v > Duration.zero)
          .timeout(const Duration(seconds: 20));
      if (!mounted || seq != _openSeq) return;
      if (target >= d - const Duration(seconds: 1)) {
        debugPrint('[EP] seek 跳过：目标 ${_fmt(target)} >= 时长 ${_fmt(d)}');
        return;
      }
      debugPrint('[EP] seek -> ${_fmt(target)}（时长 ${_fmt(d)}）');
      await _seekWithVerify(target, seq);
    } on TimeoutException {
      // 超时兜底：状态里已有时长时仍尝试 seek
      final d = _player.state.duration;
      if (!mounted || seq != _openSeq || d <= Duration.zero) {
        debugPrint('[EP] seek 放弃：20 秒内时长未知');
        return;
      }
      if (target >= d - const Duration(seconds: 1)) return;
      debugPrint('[EP] seek 兜底 -> ${_fmt(target)}（时长 ${_fmt(d)}）');
      await _seekWithVerify(target, seq);
    } catch (e) {
      debugPrint('[EP] seek 失败: $e');
    }
  }

  /// seek 后校验：每 4s 检查一次位置与目标的漂移，若 >15s（加载完成后
  /// mpv 可能把 playhead 重锚到 0，丢掉加载期发出的 seek）则重试，
  /// 最多 3 轮，命中即停。入口接管 seek 令牌，旧校验循环自动退出。
  /// [requireAdvance] 为 true（恢复路径）时额外要求“落位且真在推进”
  /// ——防“落位即冻结、数秒后回退 0”的假成功；返回是否站稳。
  Future<bool> _seekWithVerify(Duration target, int seq,
      {bool requireAdvance = false}) async {
    final tok = ++_seekToken;
    _seekIssuedAt = DateTime.now();
    if (target <= const Duration(seconds: 10)) {
      await _player.seek(target);
      return true;
    }
    final rounds = requireAdvance ? 4 : 3;
    for (var attempt = 0; attempt < rounds; attempt++) {
      if (tok != _seekToken) return false; // 已被更新的 seek/换集接管
      _seekIssuedAt = DateTime.now(); // 重试期间同样屏蔽跳回恢复，避免双机制打架
      await _player.seek(target);
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!mounted || seq != _openSeq) return false;
      if (tok != _seekToken) return false;
      var p = _player.state.position;
      if ((p - target).abs() > const Duration(seconds: 15)) {
        debugPrint('[EP] seek 未生效(第${attempt + 1}次)，重试 -> '
            '${_fmt(target)}（当前 ${_fmt(p)}）');
        continue;
      }
      if (!requireAdvance) return true;
      // 落位后确认流在推进（4s 内至少前进 2s），否则视为假落位
      final p1 = p;
      await Future<void>.delayed(const Duration(seconds: 4));
      if (!mounted || seq != _openSeq) return false;
      if (tok != _seekToken) return false;
      p = _player.state.position;
      if ((p - target).abs() <= const Duration(seconds: 15) &&
          p - p1 >= const Duration(seconds: 2)) {
        return true;
      }
      debugPrint('[EP] 恢复 seek 未站稳(第${attempt + 1}次) -> '
          '${_fmt(target)}（当前 ${_fmt(p)}）');
    }
    return false;
  }

  // ==================== 进度记忆 ====================

  void _startProgressSaving() {
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(AppConstants.progressSaveInterval, (_) {
      if (_loading || !_playing || _position < AppConstants.progressMinKeep) {
        return;
      }
      // 尾部不保存：避免进度存到结尾，下次进入即“看完”循环
      if (_duration > Duration.zero &&
          _position >= _duration - AppConstants.progressEndTrim) {
        return;
      }
      HistoryService.upsert(
        widget.drama,
        episodeIndex: _episode.index,
        episodeItemId: _episode.itemId,
        positionMs: _position.inMilliseconds,
      );
    });
  }

  Future<void> _onEpisodeEnd() async {
    debugPrint('[EP] end-of-episode #${_episode.index} handled=$_endHandled');
    if (_endHandled || _loading || !mounted) return;
    _endHandled = true;
    final seq = _openSeq;
    await HistoryService.markEpisodeFinished(
      widget.drama,
      episodeIndex: _episode.index,
    );
    // 处理期间用户手动换集则不再接管
    if (!mounted || seq != _openSeq) return;
    final next = _nextPlayable;
    if (next != null) {
      final local = await PrebufferService.localPathFor(
          widget.drama.bookId, next.index);
      final preset = _preloadReady && _preloadedIndex == next.index
          ? _preloadedUrl
          : null;
      if (local != null) {
        debugPrint('[PBF] 结尾用本地缓存开 #${next.index}');
      } else if (preset != null) {
        debugPrint('[PRE] 结尾用预载直链开 #${next.index}');
      }
      _openEpisode(next, presetUrl: preset, localPath: local);
      return;
    }
    setState(() => _playing = false);
    _showControls();
    final hasLater = widget.episodes.any((e) => e.index > _episode.index);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(hasLater ? '官方仅开放前 3 集，后续剧集暂未解锁' : '已看完最后一集'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 下一集可播剧集（跳过官方锁定集）
  Episode? get _nextPlayable {
    for (final ep in widget.episodes) {
      if (ep.index > _episode.index && ep.playable) return ep;
    }
    return null;
  }

  /// 上一集可播剧集（跳过编号缺口与锁定集）
  Episode? get _prevEpisode {
    Episode? best;
    for (final ep in widget.episodes) {
      if (ep.index >= _episode.index || !ep.playable) continue;
      if (best == null || ep.index > best.index) best = ep;
    }
    return best;
  }

  bool get _hasNextPlayable => _nextPlayable != null;

  // ==================== 控制条 ====================

  void _toggleControls() {
    debugPrint('[UI] toggleControls -> ${_controlsVisible ? 'hide' : 'show'}');
    if (_controlsVisible) {
      setState(() => _controlsVisible = false);
      _playerFocus.requestFocus();
    } else {
      _showControls();
    }
  }

  void _showControls() {
    setState(() => _controlsVisible = true);
    _scheduleHideControls();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playButtonFocus.requestFocus();
    });
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && !_hovering) {
        setState(() => _controlsVisible = false);
        _playerFocus.requestFocus();
      }
    });
  }

  void _togglePlay() {
    debugPrint('[UI] togglePlay from playing=$_playing');
    if (_playing) {
      _player.pause();
      _showControls();
    } else {
      _player.play();
      _scheduleHideControls();
    }
  }

  void _seekRelative(Duration delta) {
    if (_duration <= Duration.zero) return;
    var target = _position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _duration) target = _duration;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _lastStable = target;
    _seekWithVerify(target, _openSeq);
    _showControls();
  }

  void _nudgeVolume(double delta) {
    final next = (_volume + delta).clamp(0, 100).toDouble();
    _volume = next;
    _player.setVolume(next);
    if (mounted) setState(() {});
    _showControls();
  }

  KeyEventResult _onRemoteKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (_fullscreen) {
        _toggleFullscreen();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (_loading) return KeyEventResult.handled;
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (_loading) return KeyEventResult.handled;
      if (!_controlsVisible) {
        _showControls();
        return KeyEventResult.handled;
      }
      // 控件已显示：交给按钮焦点处理 OK
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      _player.play();
      _scheduleHideControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      _player.pause();
      _showControls();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      _seekRelative(const Duration(seconds: -10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward) {
      _seekRelative(const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.audioVolumeUp) {
      _nudgeVolume(5);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.audioVolumeDown) {
      _nudgeVolume(-5);
      return KeyEventResult.handled;
    }
    if (!_controlsVisible) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _seekRelative(const Duration(seconds: -10));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _seekRelative(const Duration(seconds: 10));
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _nudgeVolume(5);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _nudgeVolume(-5);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      if (_hasNextPlayable) _openEpisodeSmart(_nextPlayable!);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      final prev = _prevEpisode;
      if (prev != null) _openEpisodeSmart(prev);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu) {
      _showEpisodeSheet();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ==================== 全屏 ====================

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (_fullscreen) {
      if (!PlatformCheck.isAndroid) {
        await windowManager.setFullScreen(true);
      } else {
        // Android 全屏：横屏 + 沉浸式
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    } else {
      if (!PlatformCheck.isAndroid) {
        await windowManager.setFullScreen(false);
      } else {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]);
      }
    }
  }

  Future<void> _exitFullscreenIfAny() async {
    if (_fullscreen) {
      if (!PlatformCheck.isAndroid) {
        await windowManager.setFullScreen(false);
      } else {
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]);
      }
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  // ==================== 倍速 ====================

  Future<void> _pickSpeed() async {
    _showControls();
    final defaultSpeed = context.read<SettingsProvider>().defaultSpeed;
    await showModalBottomSheet<void>(
      context: context,
      constraints: sheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final seed = Theme.of(sheetContext).colorScheme.primary;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text('播放倍速',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: seed)),
                    const Spacer(),
                    Text('默认 ${_speedLabel(defaultSpeed)}（设置页可改）',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(sheetContext).colorScheme.outline)),
                  ],
                ),
              ),
              ...AppConstants.playbackSpeeds.map((s) {
                final selected = s == _speed;
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: selected
                      ? Icon(Icons.check_rounded, color: seed, size: 20)
                      : const SizedBox(width: 20),
                  title: Text(_speedLabel(s)),
                  selected: selected,
                  selectedColor: seed,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    setState(() => _speed = s);
                    _player.setRate(s);
                  },
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  static String _speedLabel(double s) {
    if (s == s.roundToDouble()) return '${s.toInt()}.0x';
    return '${s}x';
  }

  // ==================== 音量 ====================

  Future<void> _adjustVolume() async {
    _showControls();
    await showModalBottomSheet<void>(
      context: context,
      constraints: sheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_volume > 0
                            ? Icons.volume_up_rounded
                            : Icons.volume_off_rounded),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Slider(
                            value: _volume.clamp(0, 100),
                            max: 100,
                            divisions: 100,
                            label: '${_volume.round()}',
                            onChanged: (v) {
                              setSheetState(() => _volume = v);
                              _player.setVolume(v);
                              if (mounted) setState(() => _volume = v);
                            },
                          ),
                        ),
                        SizedBox(
                          width: 40,
                          child: Text('${_volume.round()}',
                              textAlign: TextAlign.end,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  // ==================== 分集列表 ====================

  /// 已跨集预缓存到本地的集号（选集列表"已缓存"标记）
  Set<int> _cachedEps = const {};

  /// 打开选集面板前刷新本地缓存快照（文件系统遍历，毫秒级）
  Future<void> _refreshCachedEps() async {
    final set = <int>{};
    for (final ep in widget.episodes) {
      if (!ep.playable) continue;
      final p = await PrebufferService.localPathFor(
          widget.drama.bookId, ep.index);
      if (p != null) set.add(ep.index);
    }
    if (!mounted) return;
    setState(() => _cachedEps = set);
  }

  Future<void> _showEpisodeSheet() async {
    debugPrint('[UI] episodeSheet.show');
    _showControls();
    await _refreshCachedEps();
    if (!mounted) return;
    final seed = Theme.of(context).colorScheme.primary;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: sheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.62,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Text('选择分集（共${widget.episodes.length}集）',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: seed)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: widget.episodes.length,
                    itemBuilder: (context, index) {
                      final ep = widget.episodes[index];
                      final current = ep.index == _episode.index;
                      final locked = !ep.playable;
                      return ListTile(
                        dense: true,
                        selected: current,
                        selectedColor: seed,
                        enabled: !locked,
                        leading: current
                            ? Icon(Icons.play_arrow_rounded, color: seed, size: 20)
                            : SizedBox(
                                width: 20,
                                child: Text('${ep.index}',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey)),
                              ),
                        title: Text(
                          '第${ep.index}集 ${ep.title == '第${ep.index}集' ? '' : ep.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: current ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                        trailing: locked
                            ? const Icon(Icons.lock_outline_rounded,
                                size: 16, color: Colors.grey)
                            : (_cachedEps.contains(ep.index)
                                ? Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text('已缓存',
                                        style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.green)),
                                  )
                                : null),
                        onTap: locked
                            ? null
                            : () {
                                Navigator.pop(sheetContext);
                                _openEpisodeSmart(ep);
                              },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ==================== 播放线路 ====================

  /// 线路选择：首项为“自动（最快）”，其余为内置 30 条线路，可手动锁定
  Future<void> _showLineSheet() async {
    debugPrint('[UI] lineSheet.show');
    _showControls();
    final seed = Theme.of(context).colorScheme.primary;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: sheetConstraints(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * 0.66,
            child: Consumer<SettingsProvider>(
              builder: (context, settings, _) {
                final pinned = settings.pinnedLineId;
                final lines = PlayLineResolver.orderedLines();
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Text('播放线路',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: seed)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                                '共${PlayLineResolver.allLines.length}条 · 默认最快 · 已按测速排序',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(sheetContext)
                                        .colorScheme
                                        .outline)),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView(
                        children: [
                          _lineTile(
                            sheetContext: sheetContext,
                            seed: seed,
                            pinned: pinned,
                          ),
                          for (final line in lines)
                            _lineTile(
                              sheetContext: sheetContext,
                              seed: seed,
                              pinned: pinned,
                              line: line,
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _lineTile({
    required BuildContext sheetContext,
    required Color seed,
    required String pinned,
    PlayLine? line,
  }) {
    final auto = line == null;
    final selected = auto ? pinned.isEmpty : pinned == line.id;
    final inUse = !auto && PlayLineResolver.lastUsedLine?.id == line.id;
    final st = auto ? null : PlayLineResolver.statOf(line.id);
    final latency = st?.emaMs;

    final String subtitle;
    if (auto) {
      subtitle = '按历史测速自动选择最快线路（本集可播时立即生效）';
    } else {
      subtitle = <String>[
        latency == null ? '未测速' : '平均 ${latency.round()}ms',
        if (st != null && st.fails > 0) '连续失败${st.fails}次',
      ].join(' · ');
    }

    return ListTile(
      dense: true,
      selected: selected,
      selectedColor: seed,
      leading: selected
          ? Icon(Icons.check_rounded, color: seed, size: 20)
          : inUse
              ? Icon(Icons.cell_tower_rounded, color: seed, size: 18)
              : const SizedBox(width: 20),
      title: Text(
        auto ? '自动选择（最快）' : line.name,
        style: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
          color: st != null && st.fails >= 3 ? Colors.grey : null,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 11.5,
          color: st != null && st.fails > 0
              ? Colors.orange
              : Theme.of(sheetContext).colorScheme.outline,
        ),
      ),
      trailing: auto
          ? null
          : Text(
              line.mode == PlayLineMode.api ? 'API' : '网页',
              style: TextStyle(
                  fontSize: 10.5,
                  color: Theme.of(sheetContext).colorScheme.outline),
            ),
      onTap: () => _selectLine(sheetContext, line),
    );
  }

  /// 锁定/取消锁定线路：与当前选择不同才重载本集
  void _selectLine(BuildContext sheetContext, PlayLine? line) {
    debugPrint('[LINE] select ${line?.id ?? 'auto'}');
    final settings = context.read<SettingsProvider>();
    final next = line?.id ?? '';
    final prev = settings.pinnedLineId;
    Navigator.of(sheetContext).pop();
    if (next == prev) return;
    settings.setPinnedLine(next).then((_) {
      if (!mounted) return;
      // 换线重载：从当前播放位置续播，避免从头开始
      _openEpisode(_episode, resumeSaved: true, resumeAt: _position);
    });
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final Widget page = Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          _hovering = true;
          // 鼠标移入即唤出控件，并取消自动隐藏计时
          if (!_controlsVisible && !_pipMode && !_loading) _showControls();
        },
        onExit: (_) {
          _hovering = false;
          _scheduleHideControls();
        },
        child: GestureDetector(
          onTap: _toggleControls,
          // 桌面端双击全屏；移动端不挂双击判定，避免单击出现延迟
          onDoubleTap: PlatformCheck.isAndroid ? null : _toggleFullscreen,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!_fullscreen) ..._buildPortraitLayout(),
              Video(
                controller: _controller,
                controls: NoVideoControls,
              ),
              if (_loading) _buildLoading(),
              if (_error.isNotEmpty) _buildError(),
              _buildControls(context),
              if (!_pipMode) _buildPreloadHint(),
              if (!_pipMode && !_loading && _error.isEmpty)
                _buildSlimProgress(context),
            ],
          ),
        ),
      ),
    );

    // 遥控器 / 键盘：OK 播放暂停，左右快进，上下音量，返回键退出全屏
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) _toggleFullscreen();
      },
      child: Focus(
        focusNode: _playerFocus,
        autofocus: true,
        onKeyEvent: _onRemoteKey,
        child: page,
      ),
    );
  }

  /// 底部细进度条（设置页可开关）：控件隐藏时也能一眼看到播放进度
  Widget _buildSlimProgress(BuildContext context) {
    if (!context.watch<SettingsProvider>().slimProgress) {
      return const SizedBox.shrink();
    }
    if (_duration <= Duration.zero) return const SizedBox.shrink();
    final p = (_position.inMilliseconds / _duration.inMilliseconds)
        .clamp(0.0, 1.0);
    final bp = (_bufferEnd.inMilliseconds / _duration.inMilliseconds)
        .clamp(0.0, 1.0);
    final seed = Theme.of(context).colorScheme.primary;
    final bottomPad =
        _fullscreen ? MediaQuery.paddingOf(context).bottom : 0.0;
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottomPad,
      child: IgnorePointer(
        child: SizedBox(
          height: 2,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.white12),
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: bp,
                  child: Container(color: Colors.white30),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: p,
                  child: Container(color: seed),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPortraitLayout() {
    // 竖屏时视频区域占顶部（16:9），下方留操作区
    return [
      Align(
        alignment: Alignment.topCenter,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(color: Colors.black),
        ),
      ),
      Align(
        alignment: Alignment.bottomCenter,
        child: Container(height: 4, color: Colors.black),
      ),
    ];
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
                strokeWidth: 2.5, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          const Text(
            '正在解析最佳线路…',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, color: Colors.white54, size: 40),
          const SizedBox(height: 10),
          Text(_error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 14),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                style:
                    OutlinedButton.styleFrom(foregroundColor: Colors.white70),
                onPressed: () {
                  _openFails = 0; // 手动重试：重新给足自动换线预算
                  _openAutoTries = 0;
                  _openEpisode(_episode,
                      resumeSaved: true, resumeAt: _position);
                },
                child: const Text('重试'),
              ),
              const SizedBox(width: 10),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.white54),
                onPressed: _showLineSheet,
                child: const Text('换个线路'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    if (_pipMode) return const SizedBox.shrink(); // 小窗内不叠任何浮层
    final visible = _controlsVisible;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 220),
      child: IgnorePointer(
        ignoring: !visible,
        child: Column(
          children: [
            // 顶部：返回 / 标题 / 分集
            _buildTopBar(context),
            const Spacer(),
            // 中间：播放/暂停
            Center(
              child: AnimatedOpacity(
                opacity: _playing && !visible ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: IconButton(
                  focusNode: _playButtonFocus,
                  iconSize: 68,
                  color: Colors.white,
                  onPressed: _loading ? null : _togglePlay,
                  icon: Icon(
                    _playing
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_fill_rounded,
                  ),
                ),
              ),
            ),
            const Spacer(),
            // 底部：进度 + 工具栏
            _buildBottomBar(context),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.paddingOf(context).top + 4,
        left: 6,
        right: 12,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Text(
              '${widget.drama.title} · 第${_episode.index}集',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.cell_tower_rounded, color: Colors.white),
            tooltip: '播放线路',
            onPressed: _showLineSheet,
          ),
          IconButton(
            icon: const Icon(Icons.menu_open_rounded, color: Colors.white),
            tooltip: '分集列表',
            onPressed: _showEpisodeSheet,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    final pos = _dragValue != null
        ? Duration(milliseconds: (_dragValue! * _duration.inMilliseconds).round())
        : _position;
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + 8,
        left: 14,
        right: 8,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度条（可拖拽）
            Row(
              children: [
                Text(_fmt(pos),
                    style: const TextStyle(color: Colors.white, fontSize: 11.5)),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      // 已缓冲段：从进度头延伸到 demuxer 缓冲位（浅色）
                      trackShape: _BufferedSliderTrackShape(
                        bufferedColor: Colors.white30,
                        bufferedFraction: _duration <= Duration.zero
                            ? 0
                            : (_bufferEnd.inMilliseconds /
                                    _duration.inMilliseconds)
                                .clamp(0.0, 1.0),
                      ),
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: _duration.inMilliseconds == 0
                          ? 0
                          : (pos.inMilliseconds /
                                  _duration.inMilliseconds)
                              .clamp(0.0, 1.0),
                      max: 1,
                      onChanged: _duration.inMilliseconds == 0
                          ? null
                          : (v) => setState(() => _dragValue = v),
                      onChangeEnd: (v) {
                        final target = Duration(
                            milliseconds: (v * _duration.inMilliseconds).round());
                        // 用户接管：取消计划中的延迟恢复，防止它把
                        // 进度拽回上一个恢复目标
                        _recoveryTimer?.cancel();
                        _recoveryTimer = null;
                        // 恢复目标锚到用户意图位：拖动后 mpv 若重锚到 0，
                        // 跳回防护会恢复到目标而不是旧的稳定位
                        _lastStable = target;
                        setState(() => _dragValue = null);
                        // 带漂移校验：缓冲期发出的 seek 可能被 mpv 丢弃，
                        // 加载完成后从头播（校验发现漂移>15s 会重试）
                        _seekWithVerify(target, _openSeq);
                      },
                    ),
                  ),
                ),
                Text(_fmt(_duration),
                    style: const TextStyle(color: Colors.white, fontSize: 11.5)),
              ],
            ),
            // 工具栏：倍速 / 音量 / 上一集 / 下一集 / 全屏
            Row(
              children: [
                _toolButton(context, Icons.speed_rounded, _speedLabel(_speed), _pickSpeed),
                _toolButton(
                    context,
                    _volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                    '音量',
                    _adjustVolume),
                _toolButton(context, Icons.skip_previous_rounded,
                    _prevEpisode != null ? '上一集' : '',
                    _prevEpisode != null
                        ? () => _openEpisodeSmart(_prevEpisode!)
                        : null),
                _toolButton(
                    context,
                    Icons.skip_next_rounded,
                    _hasNextPlayable ? '下一集' : '',
                    _hasNextPlayable
                        ? () => _openEpisodeSmart(_nextPlayable!)
                        : null),
                const Spacer(),
                if (PipService.isSupported)
                  _toolButton(
                      context,
                      Icons.picture_in_picture_alt_rounded,
                      '弹窗播放',
                      _playing && !_loading
                          ? () {
                              setState(() => _controlsVisible = false);
                              PipService.enterPip();
                            }
                          : null),
                _toolButton(
                    context,
                    _fullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    '全屏',
                    _toggleFullscreen),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolButton(
      BuildContext context, IconData icon, String label, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 21),
              if (label.isNotEmpty)
                Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ==================== 生命周期 ====================

  @override
  void dispose() {
    // 退出前保存进度
    if (_position >= AppConstants.progressMinKeep &&
        _position < _duration - AppConstants.progressEndTrim) {
      HistoryService.upsert(
        widget.drama,
        episodeIndex: _episode.index,
        episodeItemId: _episode.itemId,
        positionMs: _position.inMilliseconds,
      );
    }
    _progressTimer?.cancel();
    _hideTimer?.cancel();
    _playerFocus.dispose();
    _playButtonFocus.dispose();
    _recoveryTimer?.cancel();
    _errorWatchdog?.cancel();
    _completedSub?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    PipService.onChanged = null;
    PipService.setActive(false);
    WidgetsBinding.instance.removeObserver(this);
    _player.dispose();
    _exitFullscreenIfAny();
    super.dispose();
  }
}

/// 平台判断（隔离 window_manager 仅桌面可用的事实）
class PlatformCheck {
  static bool get isAndroid =>
      defaultTargetPlatform == TargetPlatform.android;
}

/// 进度条轨道：在标准“已播/未播”两段之上，补一段“已缓冲”浅色区间
/// （进度头 → demuxer 缓冲位）。缓冲位不足进度头时不绘制。
class _BufferedSliderTrackShape extends RoundedRectSliderTrackShape {
  const _BufferedSliderTrackShape({
    required this.bufferedColor,
    required this.bufferedFraction,
  });

  final Color bufferedColor;
  final double bufferedFraction;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    final trackHeight = sliderTheme.trackHeight;
    if (trackHeight == null ||
        trackHeight <= 0 ||
        bufferedFraction <= 0 ||
        bufferedFraction > 1) {
      return;
    }
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final bufferX = (trackRect.left + trackRect.width * bufferedFraction)
        .clamp(trackRect.left, trackRect.right);
    // 缓冲位没超过进度头：整段都被“已播”覆盖，无需绘制
    if (bufferX <= thumbCenter.dx + trackHeight / 2) return;
    final paint = Paint()..color = bufferedColor;
    context.canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(
            thumbCenter.dx + trackHeight / 2, trackRect.top, bufferX, trackRect.bottom),
        topRight: Radius.circular(trackHeight / 2),
        bottomRight: Radius.circular(trackHeight / 2),
      ),
      paint,
    );
  }
}
