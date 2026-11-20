import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';

/// URL Firebase Realtime Database untuk fitur "Total Pengguna Online".
/// Contoh: https://hazi-music-default-rtdb.asia-southeast1.firebasedatabase.app
/// Kosongkan kalau belum dibuat (angka online akan tampil "-").
const kDbUrl = '';

const kBg = Color(0xFF0B0710);
const kCard = Color(0xFF1A1226);
const kPurple = Color(0xFF9B4DFF);
const kPurpleSoft = Color(0x4D9B4DFF);

final googleSignIn = GoogleSignIn(
  scopes: ['email', 'https://www.googleapis.com/auth/youtube.readonly'],
);

// ───────────────────────── Model & State ─────────────────────────

class Song {
  final String id, title, channel, thumb;
  const Song(this.id, this.title, this.channel, this.thumb);
  Map<String, dynamic> toJson() =>
      {'id': id, 'title': title, 'channel': channel, 'thumb': thumb};
  factory Song.fromJson(Map<String, dynamic> j) =>
      Song(j['id'], j['title'], j['channel'], j['thumb']);
}

class AppState extends ChangeNotifier {
  GoogleSignInAccount? user;
  List<Song> queue = [];
  int index = -1;
  Map<String, List<Song>> playlists = {};
  YoutubePlayerController? ctrl;
  int? online;
  Timer? _hb;
  bool _ended = false;

  Song? get current =>
      (index >= 0 && index < queue.length) ? queue[index] : null;

  // ── Playlist ──
  Future<void> loadPlaylists() async {
    final u = user;
    if (u == null) return;
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('playlists_${u.id}');
    playlists = {};
    if (raw != null) {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      m.forEach((k, v) {
        playlists[k] = (v as List)
            .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      });
    }
    if (playlists.isEmpty) playlists['Favorit'] = [];
    notifyListeners();
  }

  Future<void> _save() async {
    final u = user;
    if (u == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(
      'playlists_${u.id}',
      jsonEncode(playlists
          .map((k, v) => MapEntry(k, v.map((s) => s.toJson()).toList()))),
    );
  }

  bool createPlaylist(String name) {
    final n = name.trim();
    if (n.isEmpty || playlists.containsKey(n)) return false;
    playlists[n] = [];
    _save();
    notifyListeners();
    return true;
  }

  void deletePlaylist(String name) {
    playlists.remove(name);
    _save();
    notifyListeners();
  }

  bool addToPlaylist(String name, Song s) {
    final list = playlists[name];
    if (list == null || list.any((e) => e.id == s.id)) return false;
    list.add(s);
    _save();
    notifyListeners();
    return true;
  }

  void removeFromPlaylist(String name, Song s) {
    playlists[name]?.removeWhere((e) => e.id == s.id);
    _save();
    notifyListeners();
  }

  // ── Pemutar ──
  void play(List<Song> list, int start) {
    if (list.isEmpty) return;
    queue = List.of(list);
    index = start;
    _load();
  }

  void playShuffled(List<Song> list) {
    if (list.isEmpty) return;
    play(List.of(list)..shuffle(), 0);
  }

  void addToQueue(Song s) {
    if (queue.isEmpty) {
      play([s], 0);
    } else {
      queue.add(s);
      notifyListeners();
    }
  }

  void playNext(Song s) {
    if (queue.isEmpty) {
      play([s], 0);
    } else {
      queue.insert(index + 1, s);
      notifyListeners();
    }
  }

  void jump(int i) {
    if (i < 0 || i >= queue.length) return;
    index = i;
    _load();
  }

  void next() {
    if (index + 1 < queue.length) jump(index + 1);
  }

  void prev() {
    if (index > 0) jump(index - 1);
  }

  void removeFromQueue(int i) {
    if (i == index) return;
    queue.removeAt(i);
    if (i < index) index--;
    notifyListeners();
  }

  void _load() {
    final s = current;
    if (s == null) return;
    _ended = false;
    if (ctrl == null) {
      ctrl = YoutubePlayerController(
        initialVideoId: s.id,
        flags: const YoutubePlayerFlags(autoPlay: true),
      )..addListener(_onValue);
    } else {
      ctrl!.load(s.id);
    }
    notifyListeners();
  }

  void _onValue() {
    final st = ctrl?.value.playerState;
    if (st == PlayerState.ended && !_ended) {
      _ended = true;
      next();
    } else if (st != PlayerState.ended) {
      _ended = false;
    }
  }

  // ── Pengguna online (Firebase Realtime Database via REST) ──
  void startPresence() {
    if (kDbUrl.isEmpty || user == null) return;
    _beat();
    _hb?.cancel();
    _hb = Timer.periodic(const Duration(seconds: 25), (_) => _beat());
  }

  Future<void> _beat() async {
    final u = user;
    if (u == null) return;
    try {
      final put = await http.put(
        Uri.parse('$kDbUrl/online/${u.id}.json'),
        body: jsonEncode({'t': {'.sv': 'timestamp'}}),
      );
      final now = (jsonDecode(put.body)['t'] as num).toInt();
      final res = await http.get(Uri.parse('$kDbUrl/online.json'));
      final data = jsonDecode(res.body);
      if (data is Map) {
        online = data.values
            .where((v) => v is Map && v['t'] is num && now - (v['t'] as num) < 70000)
            .length;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> stopPresence() async {
    _hb?.cancel();
    final u = user;
    if (kDbUrl.isNotEmpty && u != null) {
      try {
        await http.delete(Uri.parse('$kDbUrl/online/${u.id}.json'));
      } catch (_) {}
    }
  }

  void reset() {
    ctrl?.removeListener(_onValue);
    ctrl?.dispose();
    ctrl = null;
    queue = [];
    index = -1;
    playlists = {};
    online = null;
    user = null;
    notifyListeners();
  }
}

final app = AppState();

// ───────────────────────── Helper UI ─────────────────────────

void toast(BuildContext context, String msg) {
  final m = ScaffoldMessenger.of(context);
  m.clearSnackBars();
  m.showSnackBar(SnackBar(
    content: Text(msg),
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 2),
  ));
}

Future<String?> askName(BuildContext context) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Playlist baru'),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Nama playlist'),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Buat')),
      ],
    ),
  );
}

void pickPlaylist(BuildContext context, Song song) {
  final m = ScaffoldMessenger.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: kCard,
    builder: (ctx) => SafeArea(
      child: ListenableBuilder(
        listenable: app,
        builder: (_, __) => ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Pilih Playlist',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ...app.playlists.keys.map((name) => ListTile(
                  leading: const Icon(Icons.queue_music),
                  title: Text(name),
                  subtitle: Text('${app.playlists[name]!.length} lagu'),
                  onTap: () {
                    final ok = app.addToPlaylist(name, song);
                    Navigator.pop(ctx);
                    m.clearSnackBars();
                    m.showSnackBar(SnackBar(
                      behavior: SnackBarBehavior.floating,
                      content: Text(ok
                          ? 'Berhasil ditambahkan ke $name'
                          : 'Lagu sudah ada di $name'),
                    ));
                  },
                )),
            ListTile(
              leading: const Icon(Icons.add_circle_outline, color: kPurple),
              title: const Text('Playlist baru'),
              onTap: () async {
                final name = await askName(ctx);
                if (name == null) return;
                if (app.createPlaylist(name)) {
                  app.addToPlaylist(name.trim(), song);
                  if (ctx.mounted) Navigator.pop(ctx);
                  m.clearSnackBars();
                  m.showSnackBar(SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text('Berhasil ditambahkan ke ${name.trim()}'),
                  ));
                }
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class SongTile extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final bool selected;
  final VoidCallback? onRemove;
  const SongTile({
    super.key,
    required this.song,
    required this.onTap,
    this.selected = false,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      selected: selected,
      selectedColor: kPurple,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(song.thumb,
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
                width: 56, height: 56, color: kCard, child: const Icon(Icons.music_note))),
      ),
      title: Text(song.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(song.channel, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        color: kCard,
        onSelected: (v) {
          switch (v) {
            case 'queue':
              app.addToQueue(song);
              toast(context, 'Ditambahkan ke antrean');
              break;
            case 'next':
              app.playNext(song);
              toast(context, 'Akan diputar berikutnya');
              break;
            case 'playlist':
              pickPlaylist(context, song);
              break;
            case 'remove':
              onRemove?.call();
              break;
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'queue', child: Text('Tambahkan ke Antrean')),
          const PopupMenuItem(value: 'next', child: Text('Putar Berikutnya')),
          const PopupMenuItem(value: 'playlist', child: Text('Tambah ke Playlist')),
          if (onRemove != null)
            const PopupMenuItem(value: 'remove', child: Text('Hapus dari Playlist')),
        ],
      ),
    );
  }
}

// ───────────────────────── App & Login ─────────────────────────

void main() => runApp(const HaziMusicApp());

class HaziMusicApp extends StatelessWidget {
  const HaziMusicApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hazi Music',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          colorScheme: ColorScheme.fromSeed(
            seedColor: kPurple,
            brightness: Brightness.dark,
          ).copyWith(surface: kBg),
          appBarTheme: const AppBarTheme(backgroundColor: kBg),
          navigationBarTheme: const NavigationBarThemeData(
            backgroundColor: kCard,
            indicatorColor: kPurpleSoft,
          ),
        ),
        home: const Root(),
      );
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  bool _checking = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    googleSignIn.signInSilently().then((u) async {
      if (u != null) await _onLogin(u);
    }).catchError((_) {}).whenComplete(() {
      if (mounted) setState(() => _checking = false);
    });
  }

  Future<void> _onLogin(GoogleSignInAccount u) async {
    app.user = u;
    await app.loadPlaylists();
    app.startPresence();
    if (mounted) setState(() {});
  }

  Future<void> _login() async {
    setState(() => _error = null);
    try {
      final u = await googleSignIn.signIn();
      if (u != null) await _onLogin(u);
    } catch (e) {
      setState(() => _error = 'Login gagal: $e');
    }
  }

  Future<void> _logout() async {
    await app.stopPresence();
    app.reset();
    await googleSignIn.signOut();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (app.user == null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Image.asset('icon.png', width: 160, height: 160),
                ),
                const SizedBox(height: 24),
                const Text('Dengarkan musik favoritmu',
                    style: TextStyle(fontSize: 18)),
                const SizedBox(height: 32),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: kPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  ),
                  onPressed: _login,
                  icon: const Icon(Icons.login),
                  label: const Text('Masuk dengan Google'),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent)),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Shell(onLogout: _logout);
  }
}

// ───────────────────────── Shell + Pemutar ─────────────────────────

class Shell extends StatefulWidget {
  final Future<void> Function() onLogout;
  const Shell({super.key, required this.onLogout});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ListenableBuilder(
              listenable: app,
              builder: (_, __) =>
                  app.ctrl == null ? const SizedBox.shrink() : const NowPlaying(),
            ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  const HomePage(),
                  const PlaylistPage(),
                  AccountPage(onLogout: widget.onLogout),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Beranda'),
          NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Playlist'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Akun'),
        ],
      ),
    );
  }
}

class NowPlaying extends StatelessWidget {
  const NowPlaying({super.key});

  void _showQueue(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: app,
          builder: (_, __) => ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('Antrean (${app.queue.length})',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: app.queue.length,
                    itemBuilder: (_, i) {
                      final s = app.queue[i];
                      final cur = i == app.index;
                      return ListTile(
                        selected: cur,
                        selectedColor: kPurple,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(s.thumb, width: 48, height: 48, fit: BoxFit.cover),
                        ),
                        title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(s.channel, maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: cur
                            ? const Icon(Icons.graphic_eq)
                            : IconButton(
                                icon: const Icon(Icons.close),
                                onPressed: () => app.removeFromQueue(i),
                              ),
                        onTap: () => app.jump(i),
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

  @override
  Widget build(BuildContext context) {
    final c = app.ctrl!;
    final s = app.current;
    return Container(
      color: kCard,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          YoutubePlayer(
            controller: c,
            progressIndicatorColor: kPurple,
            bottomActions: [
              CurrentPosition(),
              ProgressBar(
                isExpanded: true,
                colors: const ProgressBarColors(
                  playedColor: kPurple,
                  handleColor: kPurple,
                ),
              ),
              RemainingDuration(),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s?.title ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(s?.channel ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Colors.white70)),
                    ],
                  ),
                ),
                IconButton(icon: const Icon(Icons.skip_previous), onPressed: app.prev),
                ValueListenableBuilder<YoutubePlayerValue>(
                  valueListenable: c,
                  builder: (_, v, __) => IconButton(
                    iconSize: 34,
                    color: kPurple,
                    icon: Icon(v.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill),
                    onPressed: () => v.isPlaying ? c.pause() : c.play(),
                  ),
                ),
                IconButton(icon: const Icon(Icons.skip_next), onPressed: app.next),
                IconButton(icon: const Icon(Icons.queue_music), onPressed: () => _showQueue(context)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Beranda ─────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _search = TextEditingController();
  List<Song> _songs = [];
  bool _loading = false;
  String? _error;

  String _clean(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"');

  Future<void> _doSearch(String q) async {
    if (q.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final auth = await app.user!.authentication;
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/search', {
        'part': 'snippet',
        'q': q,
        'type': 'video',
        'videoCategoryId': '10',
        'videoEmbeddable': 'true',
        'maxResults': '25',
      });
      final res = await http.get(uri, headers: {
        'Authorization': 'Bearer ${auth.accessToken}',
      });
      final data = jsonDecode(res.body);
      if (res.statusCode != 200) {
        throw data['error']?['message'] ?? 'Gagal mencari';
      }
      final items = (data['items'] as List).map((e) {
        final sn = e['snippet'];
        return Song(
          e['id']['videoId'],
          _clean(sn['title']),
          _clean(sn['channelTitle']),
          sn['thumbnails']['medium']['url'],
        );
      }).toList();
      setState(() => _songs = items);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = (app.user?.displayName ?? '').split(' ').first;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset('icon.png', width: 40, height: 40),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Hazi Music',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    Text('Halo, $name',
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
            ],
          ),
        ),
        ListenableBuilder(
          listenable: app,
          builder: (_, __) => Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                colors: [Color(0xFF5B1FD1), Color(0xFFB04DFF)],
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.people_alt_rounded, size: 36),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Total Pengguna Online',
                          style: TextStyle(fontSize: 13)),
                      Text(app.online?.toString() ?? '-',
                          style: const TextStyle(
                              fontSize: 32, fontWeight: FontWeight.bold)),
                      if (kDbUrl.isEmpty)
                        const Text('Belum dihubungkan ke database',
                            style: TextStyle(fontSize: 11, color: Colors.white70)),
                    ],
                  ),
                ),
                if (app.online != null)
                  Row(children: const [
                    Icon(Icons.circle, size: 10, color: Colors.greenAccent),
                    SizedBox(width: 6),
                    Text('LIVE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ]),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: _doSearch,
            decoration: InputDecoration(
              hintText: 'Cari lagu atau artis',
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: kCard,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (_loading) const LinearProgressIndicator(color: kPurple),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ),
        if (_songs.isEmpty && !_loading && _error == null)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(
              child: Text('Cari lagu untuk mulai memutar',
                  style: TextStyle(color: Colors.white54)),
            ),
          ),
        ListenableBuilder(
          listenable: app,
          builder: (_, __) => Column(
            children: [
              for (var i = 0; i < _songs.length; i++)
                SongTile(
                  song: _songs[i],
                  selected: app.current?.id == _songs[i].id,
                  onTap: () => app.play(_songs, i),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ───────────────────────── Playlist ─────────────────────────

class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key});
  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (_open != null && app.playlists.containsKey(_open)) {
          return _detail(context, _open!);
        }
        final names = app.playlists.keys.toList();
        return ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Playlist',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      final n = await askName(context);
                      if (n == null || !context.mounted) return;
                      toast(context, app.createPlaylist(n)
                          ? 'Playlist dibuat'
                          : 'Nama kosong atau sudah dipakai');
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Baru'),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            for (final n in names)
              Card(
                color: kCard,
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: ListTile(
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: kPurpleSoft,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.queue_music, color: kPurple),
                  ),
                  title: Text(n),
                  subtitle: Text('${app.playlists[n]!.length} lagu'),
                  onTap: () => setState(() => _open = n),
                  trailing: PopupMenuButton<String>(
                    color: kCard,
                    onSelected: (_) => app.deletePlaylist(n),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'del', child: Text('Hapus Playlist')),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _detail(BuildContext context, String name) {
    final songs = app.playlists[name]!;
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _open = null),
              ),
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              ),
              Text('${songs.length} lagu',
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: kPurple, foregroundColor: Colors.white),
                  onPressed: songs.isEmpty ? null : () => app.play(songs, 0),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Putar'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: songs.isEmpty ? null : () => app.playShuffled(songs),
                  icon: const Icon(Icons.shuffle),
                  label: const Text('Acak'),
                ),
              ),
            ],
          ),
        ),
        if (songs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Center(
              child: Text('Playlist masih kosong.\nTambahkan lagu lewat menu titik tiga.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54)),
            ),
          ),
        for (var i = 0; i < songs.length; i++)
          SongTile(
            song: songs[i],
            selected: app.current?.id == songs[i].id,
            onTap: () => app.play(songs, i),
            onRemove: () => app.removeFromPlaylist(name, songs[i]),
          ),
      ],
    );
  }
}

// ───────────────────────── Akun Member ─────────────────────────

class AccountPage extends StatelessWidget {
  final Future<void> Function() onLogout;
  const AccountPage({super.key, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    final u = app.user;
    final photo = u?.photoUrl;
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final total = app.playlists.values.fold<int>(0, (a, l) => a + l.length);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 12),
            Center(
              child: CircleAvatar(
                radius: 52,
                backgroundColor: kPurpleSoft,
                backgroundImage: photo != null ? NetworkImage(photo) : null,
                child: photo == null ? const Icon(Icons.person, size: 48) : null,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(u?.displayName ?? '',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(u?.email ?? '',
                  style: const TextStyle(color: Colors.white70)),
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                      colors: [Color(0xFF5B1FD1), Color(0xFFB04DFF)]),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.workspace_premium, size: 18, color: Colors.amber),
                    SizedBox(width: 6),
                    Text('Member Hazi Music',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                _stat('Playlist', '${app.playlists.length}'),
                const SizedBox(width: 12),
                _stat('Lagu Tersimpan', '$total'),
              ],
            ),
            const SizedBox(height: 28),
            Card(
              color: kCard,
              child: ListTile(
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text('Keluar'),
                onTap: onLogout,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _stat(String label, String value) => Expanded(
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.bold, color: kPurple)),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
}
