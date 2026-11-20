import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_player_flutter/youtube_player_flutter.dart';
import 'config.dart';

/// Email pemilik app. Akun ini otomatis jadi Owner dan bisa membuat kode membership.
/// (Harus sama dengan email di SQL Supabase.)
const kOwnerEmail = 'zeefifa47@gmail.com';

const kBg = Color(0xFF0B0710);
const kCard = Color(0xFF1A1226);
const kPurple = Color(0xFF9B4DFF);
const kPurpleSoft = Color(0x4D9B4DFF);

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
  // ── Sesi ──
  String? uid, email, accessToken, refreshToken;
  DateTime? expiresAt;
  bool isGuest = false;

  bool get ready => isGuest || uid != null;
  bool get hasBackend => kSupabaseUrl.isNotEmpty && kSupabaseAnonKey.isNotEmpty;
  bool get isOwner => (email ?? '').toLowerCase() == kOwnerEmail;
  String get displayName => isGuest ? 'Tamu' : (email ?? '').split('@').first;
  String get _base => kSupabaseUrl.replaceAll(RegExp(r'/+$'), '');

  // ── Data ──
  List<Song> queue = [];
  int index = -1;
  Map<String, List<Song>> playlists = {};
  YoutubePlayerController? ctrl;
  int? online;
  bool member = false;
  List<Map<String, dynamic>> codes = [];
  Timer? _hb;
  bool _ended = false;
  String? _device;

  Song? get current =>
      (index >= 0 && index < queue.length) ? queue[index] : null;

  // ───────── HTTP helper ─────────
  Map<String, String> _h({String? token}) => {
        'apikey': kSupabaseAnonKey,
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, String>> _authH() async => _h(token: await freshToken());

  String _errMsg(http.Response r) {
    try {
      final d = jsonDecode(r.body);
      return (d['msg'] ?? d['error_description'] ?? d['message'] ?? 'Terjadi kesalahan')
          .toString();
    } catch (_) {
      return 'Terjadi kesalahan (${r.statusCode})';
    }
  }

  // ───────── Login email OTP (Supabase Auth via REST) ─────────
  Future<String?> sendOtp(String mail) async {
    if (!hasBackend) return 'Server login belum diatur (config.dart)';
    try {
      final r = await http.post(
        Uri.parse('$_base/auth/v1/otp'),
        headers: _h(),
        body: jsonEncode({'email': mail.trim(), 'create_user': true}),
      );
      if (r.statusCode == 200) return null;
      return _errMsg(r);
    } catch (_) {
      return 'Tidak ada koneksi internet';
    }
  }

  Future<String?> verifyOtp(String mail, String code) async {
    try {
      final r = await http.post(
        Uri.parse('$_base/auth/v1/verify'),
        headers: _h(),
        body: jsonEncode({'type': 'email', 'email': mail.trim(), 'token': code.trim()}),
      );
      if (r.statusCode != 200) return _errMsg(r);
      _setSession(jsonDecode(r.body));
      final p = await SharedPreferences.getInstance();
      await p.setString('rt', refreshToken ?? '');
      await p.setString('mode', 'user');
      return null;
    } catch (_) {
      return 'Tidak ada koneksi internet';
    }
  }

  void _setSession(Map d) {
    accessToken = d['access_token'];
    refreshToken = d['refresh_token'];
    final exp = (d['expires_in'] as num?)?.toInt() ?? 3600;
    expiresAt = DateTime.now().add(Duration(seconds: exp));
    final u = d['user'];
    if (u is Map) {
      uid = u['id'];
      email = u['email'];
    }
    isGuest = false;
  }

  Future<bool> _refresh() async {
    if (refreshToken == null || !hasBackend) return false;
    try {
      final r = await http.post(
        Uri.parse('$_base/auth/v1/token?grant_type=refresh_token'),
        headers: _h(),
        body: jsonEncode({'refresh_token': refreshToken}),
      );
      final p = await SharedPreferences.getInstance();
      if (r.statusCode == 200) {
        _setSession(jsonDecode(r.body));
        await p.setString('rt', refreshToken ?? '');
        return true;
      }
      if (r.statusCode == 400 || r.statusCode == 401) {
        await p.remove('rt');
        await p.remove('mode');
        uid = email = accessToken = refreshToken = null;
      }
    } catch (_) {}
    return false;
  }

  Future<String?> freshToken() async {
    if (accessToken == null) return null;
    final exp = expiresAt;
    if (exp != null && DateTime.now().isAfter(exp.subtract(const Duration(seconds: 60)))) {
      await _refresh();
    }
    return accessToken;
  }

  Future<void> restore() async {
    final p = await SharedPreferences.getInstance();
    if (p.getString('mode') == 'guest') {
      isGuest = true;
      return;
    }
    final rt = p.getString('rt');
    if (rt != null && rt.isNotEmpty) {
      refreshToken = rt;
      await _refresh();
    }
  }

  Future<void> enterGuest() async {
    isGuest = true;
    final p = await SharedPreferences.getInstance();
    await p.setString('mode', 'guest');
    await afterLogin();
  }

  Future<void> afterLogin() async {
    await loadPlaylists();
    startPresence();
    await refreshMember();
    loadCodes();
  }

  Future<void> logout() async {
    final t = accessToken;
    if (t != null && hasBackend) {
      try {
        await http.post(Uri.parse('$_base/auth/v1/logout'), headers: _h(token: t));
      } catch (_) {}
    }
    final p = await SharedPreferences.getInstance();
    await p.remove('rt');
    await p.remove('mode');
    reset();
  }

  // ───────── Playlist ─────────
  String get _plKey => 'playlists_${uid ?? 'guest'}';

  Future<void> loadPlaylists() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_plKey);
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
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _plKey,
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

  // ───────── Pemutar ─────────
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

  // ───────── Membership (Supabase REST + RLS) ─────────
  Future<void> refreshMember() async {
    if (isOwner) {
      member = true;
    } else if (uid != null && hasBackend) {
      try {
        final r = await http.get(
          Uri.parse('$_base/rest/v1/members').replace(
              queryParameters: {'select': 'user_id', 'user_id': 'eq.$uid'}),
          headers: await _authH(),
        );
        final d = jsonDecode(r.body);
        member = d is List && d.isNotEmpty;
      } catch (_) {}
    } else {
      member = false;
    }
    notifyListeners();
  }

  String _randCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    String part() =>
        List.generate(4, (_) => chars[r.nextInt(chars.length)]).join();
    return 'HAZI-${part()}-${part()}';
  }

  Future<void> loadCodes() async {
    if (!isOwner || !hasBackend) return;
    try {
      final r = await http.get(
        Uri.parse('$_base/rest/v1/codes').replace(queryParameters: {
          'select': 'code,used,used_by',
          'order': 'created_at.desc',
          'limit': '20',
        }),
        headers: await _authH(),
      );
      final d = jsonDecode(r.body);
      if (d is List) {
        codes = d.map((e) => Map<String, dynamic>.from(e)).toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<String?> createCode() async {
    if (!isOwner || !hasBackend) return null;
    try {
      final code = _randCode();
      final h = await _authH();
      final r = await http.post(
        Uri.parse('$_base/rest/v1/codes'),
        headers: {...h, 'Prefer': 'return=minimal'},
        body: jsonEncode({'code': code}),
      );
      if (r.statusCode != 201) return null;
      await loadCodes();
      return code;
    } catch (_) {
      return null;
    }
  }

  /// Mengembalikan 'ok' kalau berhasil, selain itu pesan error.
  Future<String> redeem(String raw) async {
    if (isGuest || uid == null) return 'Masuk dengan email dulu';
    if (!hasBackend) return 'Server belum diatur';
    final code = raw.trim().toUpperCase();
    if (code.isEmpty) return 'Masukkan kode dulu';
    try {
      final r = await http.post(
        Uri.parse('$_base/rest/v1/rpc/redeem_code'),
        headers: await _authH(),
        body: jsonEncode({'p_code': code}),
      );
      if (r.statusCode != 200) return _errMsg(r);
      switch (jsonDecode(r.body)) {
        case 'ok':
          member = true;
          notifyListeners();
          return 'ok';
        case 'sudah':
          member = true;
          notifyListeners();
          return 'Kamu sudah jadi member';
        case 'terpakai':
          return 'Kode sudah dipakai';
        case 'login':
          return 'Masuk dengan email dulu';
        default:
          return 'Kode tidak valid';
      }
    } catch (_) {
      return 'Gagal terhubung, coba lagi';
    }
  }

  // ───────── Pengguna online ─────────
  Future<String> _deviceId() async {
    if (_device != null) return _device!;
    final p = await SharedPreferences.getInstance();
    var d = p.getString('device');
    if (d == null) {
      final r = Random.secure();
      d = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
      await p.setString('device', d);
    }
    return _device = d;
  }

  void startPresence() {
    if (!hasBackend) return;
    if (_hb != null && _hb!.isActive) return;
    _beat();
    _hb = Timer.periodic(const Duration(seconds: 25), (_) => _beat());
  }

  Future<void> _beat() async {
    try {
      final id = await _deviceId();
      final now = DateTime.now().toUtc();
      await http.post(
        Uri.parse('$_base/rest/v1/presence'),
        headers: {..._h(), 'Prefer': 'resolution=merge-duplicates,return=minimal'},
        body: jsonEncode({'id': id, 't': now.toIso8601String()}),
      );
      final since = now.subtract(const Duration(seconds: 70)).toIso8601String();
      final res = await http.get(
        Uri.parse('$_base/rest/v1/presence')
            .replace(queryParameters: {'select': 'id', 't': 'gte.$since'}),
        headers: _h(),
      );
      final d = jsonDecode(res.body);
      if (d is List) {
        online = d.length;
        notifyListeners();
      }
    } catch (_) {}
  }

  void reset() {
    _hb?.cancel();
    _hb = null;
    ctrl?.removeListener(_onValue);
    ctrl?.dispose();
    ctrl = null;
    queue = [];
    index = -1;
    playlists = {};
    online = null;
    member = false;
    codes = [];
    uid = email = accessToken = refreshToken = null;
    expiresAt = null;
    isGuest = false;
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

  @override
  void initState() {
    super.initState();
    () async {
      try {
        await app.restore();
        if (app.ready) await app.afterLogin();
      } catch (_) {}
      if (mounted) setState(() => _checking = false);
    }();
  }

  Future<void> _logout() async {
    await app.logout();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!app.ready) {
      return LoginPage(onDone: () => setState(() {}));
    }
    return Shell(onLogout: _logout);
  }
}

class LoginPage extends StatefulWidget {
  final VoidCallback onDone;
  const LoginPage({super.key, required this.onDone});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _otp = TextEditingController();
  bool _sent = false, _busy = false;
  String? _error;
  int _cool = 0;
  Timer? _t;

  void _startCooldown() {
    _cool = 60;
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (_cool <= 1) {
        t.cancel();
        setState(() => _cool = 0);
      } else {
        setState(() => _cool--);
      }
    });
  }

  Future<void> _send() async {
    final e = _email.text.trim();
    if (!e.contains('@') || !e.contains('.')) {
      setState(() => _error = 'Masukkan email yang valid');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await app.sendOtp(e);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err == null) {
        _sent = true;
        _otp.clear();
        _startCooldown();
      } else {
        _error = err;
      }
    });
  }

  Future<void> _verify() async {
    if (_otp.text.trim().length < 4) {
      setState(() => _error = 'Masukkan kode dari email');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await app.verifyOtp(_email.text, _otp.text);
    if (err == null) {
      await app.afterLogin();
      if (mounted) widget.onDone();
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  Future<void> _guest() async {
    setState(() => _busy = true);
    await app.enterGuest();
    if (mounted) widget.onDone();
  }

  @override
  void dispose() {
    _t?.cancel();
    _email.dispose();
    _otp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(32),
                  child: Image.asset('icon.png', width: 140, height: 140),
                ),
                const SizedBox(height: 20),
                const Text('Dengarkan musik favoritmu',
                    style: TextStyle(fontSize: 18)),
                const SizedBox(height: 28),
                if (!_sent) ...[
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: 'Email kamu',
                      prefixIcon: const Icon(Icons.email_outlined),
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: kPurple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _busy ? null : _send,
                      child: Text(_busy ? 'Mengirim...' : 'Kirim Kode OTP'),
                    ),
                  ),
                ] else ...[
                  Text('Kode dikirim ke ${_email.text.trim()}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _otp,
                    keyboardType: TextInputType.number,
                    maxLength: 10,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 24, letterSpacing: 6),
                    onSubmitted: (_) => _verify(),
                    decoration: InputDecoration(
                      hintText: 'Kode OTP',
                      counterText: '',
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: kPurple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: _busy ? null : _verify,
                      child: Text(_busy ? 'Memeriksa...' : 'Masuk'),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: _busy ? null : () => setState(() {
                          _sent = false;
                          _error = null;
                        }),
                        child: const Text('Ganti email'),
                      ),
                      TextButton(
                        onPressed: (_busy || _cool > 0) ? null : _send,
                        child: Text(_cool > 0 ? 'Kirim ulang (${_cool}s)' : 'Kirim ulang'),
                      ),
                    ],
                  ),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.redAccent)),
                  ),
                const SizedBox(height: 20),
                Row(children: const [
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('atau', style: TextStyle(color: Colors.white54)),
                  ),
                  Expanded(child: Divider()),
                ]),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: kPurple),
                    ),
                    onPressed: _busy ? null : _guest,
                    child: const Text('Lanjut tanpa akun'),
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
      if (kYtApiKey.isEmpty) throw 'API key YouTube belum diisi (config.dart)';
      final uri = Uri.https('www.googleapis.com', '/youtube/v3/search', {
        'part': 'snippet',
        'q': q,
        'type': 'video',
        'videoCategoryId': '10',
        'videoEmbeddable': 'true',
        'maxResults': '25',
        'key': kYtApiKey,
      });
      final res = await http.get(uri);
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
                    Text('Halo, ${app.displayName}',
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
                      if (!app.hasBackend)
                        const Text('Belum dihubungkan ke server',
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

class AccountPage extends StatefulWidget {
  final Future<void> Function() onLogout;
  const AccountPage({super.key, required this.onLogout});
  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _code = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    setState(() => _busy = true);
    final res = await app.redeem(_code.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res == 'ok') {
      _code.clear();
      toast(context, 'Selamat! Kamu sekarang Member');
    } else {
      toast(context, res);
    }
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    final c = await app.createCode();
    if (!mounted) return;
    setState(() => _busy = false);
    if (c == null) {
      toast(context, 'Gagal membuat kode. Cek koneksi dan setup server.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: c));
    if (mounted) toast(context, 'Kode $c dibuat dan disalin');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final total = app.playlists.values.fold<int>(0, (a, l) => a + l.length);
        final name = app.displayName;
        final initial = name.isEmpty ? '?' : name[0].toUpperCase();
        final badgeText = app.isGuest
            ? 'Mode Tamu'
            : app.isOwner
                ? 'Owner Hazi Music'
                : (app.member ? 'Member Hazi Music' : 'Belum Member');
        final badgeIcon = app.isGuest
            ? Icons.person_outline
            : app.isOwner
                ? Icons.verified
                : (app.member ? Icons.workspace_premium : Icons.lock_outline);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 12),
            Center(
              child: CircleAvatar(
                radius: 52,
                backgroundColor: kPurpleSoft,
                child: Text(initial,
                    style: const TextStyle(fontSize: 44, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(name,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(app.isGuest ? 'Belum masuk' : (app.email ?? ''),
                  style: const TextStyle(color: Colors.white70)),
            ),
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    colors: app.member
                        ? const [Color(0xFF5B1FD1), Color(0xFFB04DFF)]
                        : const [Color(0xFF3A3A3A), Color(0xFF555555)],
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(badgeIcon, size: 18, color: app.member ? Colors.amber : Colors.white70),
                    const SizedBox(width: 6),
                    Text(badgeText, style: const TextStyle(fontWeight: FontWeight.bold)),
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
            const SizedBox(height: 20),
            if (app.isGuest) _guestPanel(),
            if (app.isOwner) _ownerPanel(context),
            if (!app.isGuest && !app.member) _redeemPanel(),
            const SizedBox(height: 8),
            Card(
              color: kCard,
              child: ListTile(
                leading: Icon(app.isGuest ? Icons.login : Icons.logout,
                    color: app.isGuest ? kPurple : Colors.redAccent),
                title: Text(app.isGuest ? 'Masuk dengan Email' : 'Keluar'),
                onTap: widget.onLogout,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _guestPanel() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16)),
        child: const Text(
          'Kamu sedang memakai mode tamu. Masuk dengan email untuk bisa menukar kode membership.',
          style: TextStyle(color: Colors.white70),
        ),
      );

  Widget _redeemPanel() => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Punya kode membership?',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                hintText: 'HAZI-XXXX-XXXX',
                filled: true,
                fillColor: kBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: kPurple, foregroundColor: Colors.white),
                onPressed: _busy ? null : _redeem,
                child: Text(_busy ? 'Memproses...' : 'Tukar Kode'),
              ),
            ),
          ],
        ),
      );

  Widget _ownerPanel(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Kode Membership',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 4),
            Text(
              app.hasBackend
                  ? 'Buat kode lalu kirim ke orang yang mau dijadikan member. Satu kode untuk satu orang.'
                  : 'Isi kSupabaseUrl dan kSupabaseAnonKey di config.dart agar bisa membuat kode.',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: kPurple, foregroundColor: Colors.white),
                onPressed: (_busy || !app.hasBackend) ? null : _create,
                icon: const Icon(Icons.vpn_key),
                label: const Text('Buat Kode Baru'),
              ),
            ),
            for (final c in app.codes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('${c['code']}',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      decoration: c['used'] == true ? TextDecoration.lineThrough : null,
                      color: c['used'] == true ? Colors.white38 : Colors.white,
                    )),
                subtitle: Text(
                    c['used'] == true ? 'Dipakai: ${c['used_by'] ?? ''}' : 'Belum dipakai',
                    style: TextStyle(
                        color: c['used'] == true ? Colors.white38 : Colors.greenAccent)),
                trailing: c['used'] == true
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: '${c['code']}'));
                          if (context.mounted) toast(context, 'Kode disalin');
                        },
                      ),
              ),
          ],
        ),
      );

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
