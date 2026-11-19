// SW Oto Klip
// Uzun yayınlarda (Kick / YouTube / Twitch kayıtları) sohbet yoğunluğuna bakarak
// otomatik klip anlarını bulur, listeler ve 16:9 oynatıcıda o saniyeden açar.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

const Color kRed = Color(0xFFE50914);
const Color kBg = Color(0xFF0B0B0D);
const Color kCard = Color(0xFF17171B);
const Color kCardHi = Color(0xFF241217);

const String kDesktopUA =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SwApp());
}

class SwApp extends StatelessWidget {
  const SwApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SW Oto Klip',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme:
            ColorScheme.fromSeed(seedColor: kRed, brightness: Brightness.dark),
        scaffoldBackgroundColor: kBg,
      ),
      home: const HomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Yardımcılar
// ---------------------------------------------------------------------------

String fmtTime(num sec) {
  final s = sec.round();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final x = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(x)}' : '${two(m)}:${two(x)}';
}

String platName(String p) {
  switch (p) {
    case 'youtube':
      return 'YouTube';
    case 'kick':
      return 'Kick';
    case 'twitch':
      return 'Twitch';
  }
  return p;
}

String playerBase(String p) {
  switch (p) {
    case 'youtube':
      return 'https://www.youtube.com';
    case 'kick':
      return 'https://kick.com';
  }
  return 'https://localhost';
}

class Target {
  final String platform;
  final String id;
  final String pageUrl;
  const Target(this.platform, this.id, this.pageUrl);
}

Target? parseTarget(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
  final u = Uri.tryParse(s);
  if (u == null || u.host.isEmpty) return null;
  final host = u.host.toLowerCase().replaceFirst(RegExp(r'^(www\.|m\.)'), '');
  final seg = u.pathSegments.where((e) => e.isNotEmpty).toList();

  if (host == 'youtu.be' && seg.isNotEmpty) {
    final id = seg.first;
    if (RegExp(r'^[\w-]{11}$').hasMatch(id)) {
      return Target('youtube', id, 'https://www.youtube.com/watch?v=$id');
    }
    return null;
  }
  if (host.endsWith('youtube.com')) {
    String? id = u.queryParameters['v'];
    if (id == null &&
        seg.length >= 2 &&
        (seg[0] == 'live' ||
            seg[0] == 'embed' ||
            seg[0] == 'shorts' ||
            seg[0] == 'v')) {
      id = seg[1];
    }
    if (id != null && RegExp(r'^[\w-]{11}$').hasMatch(id)) {
      return Target('youtube', id, 'https://www.youtube.com/watch?v=$id');
    }
    return null;
  }
  if (host == 'kick.com' || host.endsWith('.kick.com')) {
    final m = RegExp(
            r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        .firstMatch(u.path);
    if (m != null) {
      final path = u.path.startsWith('/') ? u.path : '/${u.path}';
      return Target('kick', m.group(0)!.toLowerCase(), 'https://kick.com$path');
    }
    return null;
  }
  if (host.endsWith('twitch.tv')) {
    final m = RegExp(r'/videos/(\d+)').firstMatch(u.path);
    if (m != null) {
      final id = m.group(1)!;
      return Target('twitch', id, 'https://www.twitch.tv/videos/$id');
    }
    return null;
  }
  return null;
}

String buildPlayerHtml(Map<String, dynamic> meta, int start) {
  final p = (meta['platform'] ?? '').toString();
  final id = (meta['id'] ?? '').toString();
  const head =
      '<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
      '<style>html,body{margin:0;height:100%;background:#000;overflow:hidden;color:#fff;font-family:sans-serif}'
      'iframe,video{position:absolute;left:0;top:0;width:100%;height:100%;border:0;background:#000}'
      '.msg{position:absolute;left:0;right:0;top:40%;text-align:center;padding:12px}</style></head><body>';
  if (p == 'youtube') {
    return '$head<iframe src="https://www.youtube.com/embed/$id?start=$start&autoplay=1&playsinline=1&rel=0&modestbranding=1" '
        'allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe></body></html>';
  }
  if (p == 'twitch') {
    final h = start ~/ 3600;
    final m = (start % 3600) ~/ 60;
    final s = start % 60;
    return '$head<iframe src="https://player.twitch.tv/?video=v$id&parent=localhost&autoplay=true&time=${h}h${m}m${s}s" '
        'allow="autoplay; fullscreen" allowfullscreen></iframe></body></html>';
  }
  if (p == 'kick') {
    final src = (meta['source'] ?? '').toString();
    if (src.isEmpty) {
      return '$head<div class="msg">Kick video kaynağı bulunamadı. Aşağıdaki "sayfayı aç" düğmesini dene.</div></body></html>';
    }
    return '$head<video id="v" controls playsinline autoplay></video>'
        '<script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.8/dist/hls.min.js"></script><script>'
        'var src=${jsonEncode(src)};var start=$start;var v=document.getElementById("v");'
        'function err(m){try{SWP.postMessage("error:"+m)}catch(e){}}'
        'if(window.Hls&&Hls.isSupported()){var h=new Hls({startPosition:start});h.loadSource(src);h.attachMedia(v);'
        'h.on(Hls.Events.ERROR,function(e,d){if(d&&d.fatal)err(d.details)});v.play().catch(function(){});}'
        'else{v.src=src;v.addEventListener("loadedmetadata",function(){v.currentTime=start;v.play()});'
        'v.addEventListener("error",function(){err("video")});}'
        '</script></body></html>';
  }
  return '$head<div class="msg">Desteklenmeyen platform</div></body></html>';
}

class ItemClip {
  final int rank;
  final double start, end, peak, score, perMin, lift, heat;
  final int count, users;
  final List<String> tags, samples, words;

  ItemClip({
    required this.rank,
    required this.start,
    required this.end,
    required this.peak,
    required this.score,
    required this.perMin,
    required this.lift,
    required this.heat,
    required this.count,
    required this.users,
    required this.tags,
    required this.samples,
    required this.words,
  });

  factory ItemClip.fromJson(Map<String, dynamic> j) {
    double d(dynamic v) => (v is num) ? v.toDouble() : 0.0;
    int i(dynamic v) => (v is num) ? v.toInt() : 0;
    List<String> sl(dynamic v) =>
        (v is List) ? v.map((e) => e.toString()).toList() : <String>[];
    return ItemClip(
      rank: i(j['rank']),
      start: d(j['start']),
      end: d(j['end']),
      peak: d(j['peak']),
      score: d(j['score']),
      perMin: d(j['perMin']),
      lift: d(j['lift']),
      heat: d(j['heat']),
      count: i(j['count']),
      users: i(j['users']),
      tags: sl(j['tags']),
      samples: sl(j['samples']),
      words: sl(j['words']),
    );
  }
}

// ---------------------------------------------------------------------------
// Ana sayfa
// ---------------------------------------------------------------------------

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlCtl = TextEditingController();
  final GlobalKey _playerKey = GlobalKey();
  late final WebViewController _fetcher;
  late final WebViewController _player;

  String _analyzerJs = '';
  Target? _job;
  bool _busy = false;
  double _progress = 0;
  String _status = '';
  String? _error;
  Map<String, dynamic>? _result;
  Map<String, dynamic>? _meta;
  bool _canRerank = false;
  bool _playerActive = false;
  String? _playerNote;
  double? _selectedStart;
  bool _byScore = true;
  bool _onlyFavs = false;
  int _clipLen = 45;
  int _maxClips = 12;
  Set<String> _favs = <String>{};
  List<Map<String, dynamic>> _history = <Map<String, dynamic>>[];
  Timer? _watchdog;
  DateTime _lastSignal = DateTime.now();

  @override
  void initState() {
    super.initState();

    _fetcher = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('SW',
          onMessageReceived: (JavaScriptMessage m) => _onJsMessage(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (NavigationRequest r) =>
            r.url.startsWith('http') || r.url.startsWith('about:')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
        onPageFinished: (String url) => _onFetcherLoaded(url),
        onWebResourceError: (WebResourceError e) => _onFetcherError(e),
      ));
    final fp = _fetcher.platform;
    if (fp is AndroidWebViewController) {
      fp.setMediaPlaybackRequiresUserGesture(true);
    }

    _player = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('SWP', onMessageReceived: (JavaScriptMessage m) {
        if (!mounted) return;
        if (m.message.startsWith('error:')) {
          setState(() => _playerNote =
              'Oynatıcı hatası (${m.message.substring(6)}). Aşağıdan sayfayı açmayı dene.');
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (NavigationRequest r) =>
            r.url.startsWith('http') || r.url.startsWith('about:')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
      ));
    final pp = _player.platform;
    if (pp is AndroidWebViewController) {
      pp.setMediaPlaybackRequiresUserGesture(false);
    }

    rootBundle.loadString('assets/analyzer.js').then((v) => _analyzerJs = v);
    _loadPrefs();
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _urlCtl.dispose();
    super.dispose();
  }

  // ----------------------------- Ayarlar / geçmiş -----------------------------

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final h = p.getString('history');
    List<Map<String, dynamic>> hist = <Map<String, dynamic>>[];
    if (h != null) {
      try {
        hist = (jsonDecode(h) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _clipLen = (p.getInt('clipLen') ?? 45).clamp(15, 120).toInt();
      _maxClips = (p.getInt('maxClips') ?? 12).clamp(3, 30).toInt();
      _favs = (p.getStringList('favs') ?? <String>[]).toSet();
      _history = hist;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('clipLen', _clipLen);
    await p.setInt('maxClips', _maxClips);
    await p.setStringList('favs', _favs.toList());
  }

  Future<void> _persistHistory() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('history', jsonEncode(_history));
  }

  void _saveHistory(Map<String, dynamic> res) {
    final meta = Map<String, dynamic>.from(res['meta'] as Map);
    final key = '${meta['platform']}:${meta['id']}';
    _history.removeWhere((e) => e['key'] == key);
    _history.insert(0, <String, dynamic>{
      'key': key,
      'url': (meta['url'] ?? '').toString(),
      'title': (meta['title'] ?? '').toString(),
      'platform': (meta['platform'] ?? '').toString(),
      'ts': DateTime.now().millisecondsSinceEpoch,
      'result': res,
    });
    if (_history.length > 15) {
      _history = _history.sublist(0, 15);
    }
    _persistHistory();
  }

  // ----------------------------- Analiz akışı -----------------------------

  void _start() {
    final t = parseTarget(_urlCtl.text);
    if (t == null) {
      setState(() => _error =
          'Geçerli bir kayıt linki gir: Kick VOD (…/videos/…), YouTube video/canlı yayın kaydı veya Twitch /videos/… linki.');
      return;
    }
    if (_analyzerJs.isEmpty) {
      setState(() => _error = 'Analiz motoru yüklenemedi (assets/analyzer.js).');
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _stopPlayer();
    setState(() {
      _job = t;
      _busy = true;
      _error = null;
      _result = null;
      _meta = null;
      _progress = 0;
      _status = 'Sayfa açılıyor…';
      _canRerank = false;
      _selectedStart = null;
    });
    _lastSignal = DateTime.now();
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_busy && DateTime.now().difference(_lastSignal).inSeconds > 150) {
        _fail(
            'Zaman aşımı: yayın sayfasından veri gelmedi. İnternetini kontrol edip tekrar dene.');
      }
    });
    _fetcher.setUserAgent(t.platform == 'youtube' ? kDesktopUA : null);
    _fetcher.loadRequest(Uri.parse(t.pageUrl));
  }

  void _cancel() {
    _watchdog?.cancel();
    _fetcher.runJavaScript('window.swCancel&&window.swCancel()').catchError((_) {});
    _fetcher.loadHtmlString('<html><body></body></html>');
    setState(() {
      _busy = false;
      _status = '';
    });
  }

  void _fail(String msg) {
    _watchdog?.cancel();
    _fetcher.runJavaScript('window.swCancel&&window.swCancel()').catchError((_) {});
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = msg;
    });
  }

  void _stopPlayer() {
    _playerActive = false;
    _playerNote = null;
    _player.loadHtmlString('<html><body style="background:#000"></body></html>');
  }

  void _onFetcherLoaded(String url) {
    if (!_busy || _job == null || url.startsWith('about:')) return;
    _injectJob();
  }

  Future<void> _injectJob() async {
    final job = _job;
    if (job == null) return;
    final params = jsonEncode(<String, dynamic>{
      'platform': job.platform,
      'id': job.id,
      'clipLen': _clipLen,
      'maxClips': _maxClips,
    });
    try {
      await _fetcher
          .runJavaScript('$_analyzerJs\n;window.swStart && window.swStart($params);');
    } catch (e) {
      _fail('Analiz başlatılamadı: $e');
    }
  }

  void _onFetcherError(WebResourceError e) {
    if (!_busy) return;
    final d = e.description;
    if (d.contains('ERR_INTERNET_DISCONNECTED') ||
        d.contains('ERR_NAME_NOT_RESOLVED') ||
        d.contains('ERR_CONNECTION_')) {
      _fail('İnternet bağlantısı yok ya da yayın sitesine ulaşılamıyor.');
    }
  }

  void _onJsMessage(String s) {
    Map<String, dynamic> m;
    try {
      m = Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    _lastSignal = DateTime.now();
    switch (m['type']) {
      case 'progress':
        setState(() {
          _progress = (m['pct'] is num) ? (m['pct'] as num).toDouble() : _progress;
          _status = (m['text'] ?? '').toString();
        });
        break;
      case 'meta':
        setState(() {
          _meta = Map<String, dynamic>.from(m['meta'] as Map)
            ..['url'] = _job?.pageUrl ?? '';
        });
        break;
      case 'result':
        _onResult(m);
        break;
      case 'error':
        _fail((m['text'] ?? 'Bilinmeyen hata').toString());
        break;
    }
  }

  void _onResult(Map<String, dynamic> m) {
    _watchdog?.cancel();
    final meta = Map<String, dynamic>.from(m['meta'] as Map);
    meta['url'] = _job?.pageUrl ?? (_meta?['url'] ?? '');
    m['meta'] = meta;
    setState(() {
      _busy = false;
      _error = null;
      _result = m;
      _meta = meta;
      _canRerank = true;
      _progress = 1;
    });
    _saveHistory(m);
  }

  void _openHistory(Map<String, dynamic> e) {
    final res = Map<String, dynamic>.from(e['result'] as Map);
    final meta = Map<String, dynamic>.from(res['meta'] as Map);
    _stopPlayer();
    setState(() {
      _busy = false;
      _error = null;
      _result = res;
      _meta = meta;
      _canRerank = false;
      _selectedStart = null;
      _urlCtl.text = (e['url'] ?? '').toString();
    });
  }

  void _settingsChanged() {
    _savePrefs();
    if (_canRerank && _result != null) {
      final params = jsonEncode(
          <String, dynamic>{'clipLen': _clipLen, 'maxClips': _maxClips});
      _fetcher
          .runJavaScript('window.swRerank && window.swRerank($params);')
          .catchError((_) {});
    }
  }

  // ----------------------------- Oynatıcı -----------------------------

  void _play(ItemClip c) {
    final meta = _meta;
    if (meta == null) return;
    setState(() {
      _selectedStart = c.start;
      _playerActive = true;
      _playerNote = null;
    });
    _player.loadHtmlString(
      buildPlayerHtml(meta, c.start.floor()),
      baseUrl: playerBase((meta['platform'] ?? '').toString()),
    );
  }

  void _openPage() {
    final url = (_meta?['url'] ?? _job?.pageUrl ?? '').toString();
    if (url.isEmpty) return;
    setState(() {
      _playerActive = true;
      _playerNote = null;
    });
    _player.loadRequest(Uri.parse(url));
  }

  String _linkFor(double sec) {
    final meta = _meta;
    if (meta == null) return '';
    final p = (meta['platform'] ?? '').toString();
    final id = (meta['id'] ?? '').toString();
    final s = sec.floor();
    if (p == 'youtube') return 'https://youtu.be/$id?t=$s';
    if (p == 'twitch') {
      return 'https://www.twitch.tv/videos/$id?t=${s ~/ 3600}h${(s % 3600) ~/ 60}m${s % 60}s';
    }
    return (meta['url'] ?? '').toString();
  }

  String _favKey(ItemClip c) =>
      '${_meta?['platform']}:${_meta?['id']}#${c.start.round()}';

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text;
    if (t != null && t.trim().isNotEmpty) {
      setState(() => _urlCtl.text = t.trim());
    }
  }

  List<ItemClip> get _allClips {
    final r = _result;
    if (r == null) return <ItemClip>[];
    final raw = (r['clips'] as List?) ?? <dynamic>[];
    return raw
        .map((e) => ItemClip.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  List<ItemClip> get _visible {
    var l = _allClips;
    if (_onlyFavs) l = l.where((c) => _favs.contains(_favKey(c))).toList();
    if (_byScore) {
      l.sort((a, b) => b.score.compareTo(a.score));
    } else {
      l.sort((a, b) => a.start.compareTo(b.start));
    }
    return l;
  }

  void _copyOne(ItemClip c) {
    Clipboard.setData(ClipboardData(
        text:
            '#${c.rank}  ${fmtTime(c.start)}–${fmtTime(c.end)}  (skor ${c.score.round()})\n${_linkFor(c.start)}'));
    _toast('Kopyalandı');
  }

  void _copyAll() {
    final meta = _meta;
    if (meta == null) return;
    final b = StringBuffer('SW Oto Klip — ${meta['title']}\n\n');
    for (final c in _visible) {
      b.writeln(
          '#${c.rank}  ${fmtTime(c.start)}–${fmtTime(c.end)}  (skor ${c.score.round()})  ${c.tags.isNotEmpty ? c.tags.first : ''}');
      b.writeln(_linkFor(c.start));
      b.writeln();
    }
    Clipboard.setData(ClipboardData(text: b.toString()));
    _toast('Liste kopyalandı');
  }

  // ----------------------------- Alt sayfalar -----------------------------

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Ayarlar',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 16),
                Text('Klip süresi: $_clipLen sn'),
                Slider(
                  value: _clipLen.toDouble(),
                  min: 15,
                  max: 120,
                  divisions: 21,
                  label: '$_clipLen sn',
                  activeColor: kRed,
                  onChanged: (v) {
                    setS(() => _clipLen = (v / 5).round() * 5);
                    setState(() {});
                  },
                  onChangeEnd: (_) => _settingsChanged(),
                ),
                const SizedBox(height: 8),
                Text('En fazla klip sayısı: $_maxClips'),
                Slider(
                  value: _maxClips.toDouble(),
                  min: 3,
                  max: 30,
                  divisions: 27,
                  label: '$_maxClips',
                  activeColor: kRed,
                  onChanged: (v) {
                    setS(() => _maxClips = v.round());
                    setState(() {});
                  },
                  onChangeEnd: (_) => _settingsChanged(),
                ),
                const SizedBox(height: 4),
                Text(
                  _canRerank
                      ? 'Değişiklikler mevcut listeye hemen uygulanır.'
                      : 'Değişiklikler bir sonraki analizde geçerli olur.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showHistory() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Geçmiş analizler',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                if (_history.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('Henüz analiz yok.',
                        style: TextStyle(color: Colors.white54)),
                  ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _history.length,
                    itemBuilder: (c, i) {
                      final e = _history[i];
                      final n = ((e['result'] as Map)['clips'] as List).length;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.movie_filter, color: kRed),
                        title: Text('${e['title']}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle:
                            Text('${platName('${e['platform']}')} • $n klip'),
                        onTap: () {
                          Navigator.pop(ctx);
                          _openHistory(e);
                        },
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () {
                            setState(() => _history.removeAt(i));
                            _persistHistory();
                            setS(() {});
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ----------------------------- Arayüz -----------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        titleSpacing: 12,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset('assets/icon.png',
                  width: 34, height: 34, cacheWidth: 120),
            ),
            const SizedBox(width: 10),
            const Text('SW Oto Klip',
                style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.history),
              tooltip: 'Geçmiş',
              onPressed: _showHistory),
          IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Ayarlar',
              onPressed: _showSettings),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            child: LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 900;
                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 11,
                        child: SingleChildScrollView(
                          child: Column(
                            children: [_inputPanel(), _playerBox()],
                          ),
                        ),
                      ),
                      Expanded(flex: 9, child: _clipList()),
                    ],
                  );
                }
                return Column(
                  children: [
                    _inputPanel(),
                    _playerBox(),
                    const SizedBox(height: 6),
                    Expanded(child: _clipList()),
                  ],
                );
              },
            ),
          ),
          // Veriyi çeken gizli WebView (1-2 piksel)
          Positioned(
            left: 0,
            bottom: 0,
            width: 2,
            height: 2,
            child: IgnorePointer(child: WebViewWidget(controller: _fetcher)),
          ),
        ],
      ),
    );
  }

  Widget _inputPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlCtl,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) {
                    if (!_busy) _start();
                  },
                  decoration: InputDecoration(
                    hintText: 'Kick / YouTube / Twitch kayıt linki',
                    filled: true,
                    fillColor: kCard,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(Icons.link),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.content_paste),
                      tooltip: 'Yapıştır',
                      onPressed: _paste,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                child: FilledButton(
                  onPressed: _busy ? _cancel : _start,
                  style: FilledButton.styleFrom(
                    backgroundColor: kRed,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(_busy ? 'İptal' : 'Analiz Et',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress <= 0.01 ? null : _progress,
                minHeight: 6,
                color: kRed,
                backgroundColor: Colors.white12,
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(_status,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0x33E50914),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(_error!, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _playerBox() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  WebViewWidget(key: _playerKey, controller: _player),
                  if (!_playerActive)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Image.asset('assets/icon.png',
                                  width: 64, height: 64, cacheWidth: 200),
                              const SizedBox(height: 8),
                              const Text(
                                  'Listeden bir klip seç, yayın o saniyeden açılsın',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.white54, fontSize: 12)),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Row(
            children: [
              if (_playerNote != null)
                Expanded(
                  child: Text(_playerNote!,
                      style: const TextStyle(color: Colors.amber, fontSize: 12)),
                )
              else
                const Spacer(),
              if (_meta != null)
                TextButton(
                  onPressed: _openPage,
                  child: const Text('Oynatıcı açılmazsa: sayfayı aç',
                      style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _clipList() {
    final items = _visible;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length + 1,
      itemBuilder: (ctx, i) =>
          i == 0 ? _listHeader(items.length) : _clipCard(items[i - 1]),
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11.5)),
    );
  }

  Widget _listHeader(int shown) {
    final r = _result;
    final meta = _meta;
    if (r == null) {
      if (_busy && meta != null) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
          child: Text('${meta['title']}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700)),
        );
      }
      if (_busy) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
              color: kCard, borderRadius: BorderRadius.circular(14)),
          child: const Text(
            'Nasıl kullanılır\n\n'
            '1. Kick, YouTube veya Twitch\'te biten bir yayının kayıt (VOD) linkini yapıştır.\n'
            '2. "Analiz Et"e bas. Sohbet yoğunluğu, kahkaha/hype tepkileri ve klip istekleri taranır.\n'
            '3. Listeden bir ana dokun; yayın o saniyeden 16:9 oynatıcıda açılır.\n\n'
            'Not: Canlı devam eden yayınlar analiz edilemez; yayın bitince kaydıyla dene. '
            'YouTube için sohbet tekrarı açık olmalı.',
            style: TextStyle(color: Colors.white70, height: 1.4),
          ),
        ),
      );
    }

    final dur = (r['durationSec'] is num) ? (r['durationSec'] as num).toInt() : 0;
    final total = (r['totalMessages'] is num) ? (r['totalMessages'] as num).toInt() : 0;
    final avg = (r['avgPerMin'] is num) ? (r['avgPerMin'] as num).toDouble() : 0.0;
    final hasChat = r['hasChat'] == true;
    final hasHeat = r['hasHeat'] == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${meta?['title'] ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _pill(platName('${meta?['platform']}')),
              _pill('Süre ${fmtTime(dur)}'),
              _pill('$total mesaj'),
              _pill('ort. ${avg.round()} mesaj/dk'),
              if (hasHeat) _pill('YouTube "en çok izlenen" verisi'),
            ],
          ),
          if (!hasChat)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  'Yeterli sohbet verisi bulunamadı; yalnızca "en çok izlenen" verisi kullanıldı.',
                  style: TextStyle(color: Colors.amber, fontSize: 12)),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('Bulunan klipler ($shown)',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                onPressed: shown == 0 ? null : _copyAll,
                icon: const Icon(Icons.copy_all, size: 18),
                label: const Text('Listeyi kopyala'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Skora göre'),
                selected: _byScore,
                onSelected: (_) => setState(() => _byScore = true),
              ),
              ChoiceChip(
                label: const Text('Zamana göre'),
                selected: !_byScore,
                onSelected: (_) => setState(() => _byScore = false),
              ),
              FilterChip(
                label: const Text('Favoriler'),
                avatar: const Icon(Icons.star, size: 16),
                selected: _onlyFavs,
                onSelected: (v) => setState(() => _onlyFavs = v),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _clipCard(ItemClip c) {
    final selected = _selectedStart == c.start;
    final fav = _favs.contains(_favKey(c));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Container(
        decoration: BoxDecoration(
          color: selected ? kCardHi : kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? kRed : Colors.white10, width: selected ? 1.6 : 1),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _play(c),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: kRed,
                        child: Text('${c.rank}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 13)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('${fmtTime(c.start)} – ${fmtTime(c.end)}',
                            style: const TextStyle(
                                fontSize: 17, fontWeight: FontWeight.w800)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: kRed,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text('${c.score.round()}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 13)),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(fav ? Icons.star : Icons.star_border,
                            color: fav ? Colors.amber : Colors.white54),
                        onPressed: () {
                          setState(() {
                            final k = _favKey(c);
                            if (!_favs.remove(k)) _favs.add(k);
                          });
                          _savePrefs();
                        },
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.copy, size: 20, color: Colors.white54),
                        onPressed: () => _copyOne(c),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (c.score / 100).clamp(0.0, 1.0).toDouble(),
                        minHeight: 5,
                        color: kRed,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [for (final t in c.tags) _pill(t)],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      c.lift > 0
                          ? '${c.count} mesaj • dakikada ${c.perMin.round()} • normalin ${c.lift.toStringAsFixed(1)} katı • ${c.users} kişi'
                          : '"En çok izlenen" verisine göre öne çıkan bölüm',
                      style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                    ),
                  ),
                  if (c.words.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, right: 12),
                      child: Text('Öne çıkan: ${c.words.join(', ')}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ),
                  if (c.samples.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, right: 12),
                      child: Text(c.samples.map((e) => '“$e”').join('  '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                              fontStyle: FontStyle.italic)),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
