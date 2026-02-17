import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// IMPORTANT:
// This file assumes you ran:
//   flutterfire configure
// and you have lib/firebase_options.dart generated.
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Portrait lock
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  runApp(const GozenApp());
}

/// Normalize flight codes so that:
/// - Case-insensitive (BA679 == ba679)
/// - Leading zeros before the numeric part are ignored:
///   BA0679, BA00679, BA000679 all normalize to BA679
///
/// Examples:
///   normalizeFlightCode(" BA00679 ") -> "BA679"
///   normalizeFlightCode("TK0001234") -> "TK1234"
String normalizeFlightCode(String raw) {
  var s = raw.trim().toUpperCase().replaceAll(' ', '');

  // Keep only A-Z and 0-9 (defensive for barcode noise)
  s = s.replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (s.isEmpty) return '';

  final m = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(s);
  if (m == null) {
    // If it doesn't match expected pattern, return the cleaned string as-is.
    return s;
  }

  final prefix = m.group(1)!;
  final digits = m.group(2)!;
  final stripped = digits.replaceFirst(RegExp(r'^0+'), '');
  return '$prefix${stripped.isEmpty ? '0' : stripped}';
}

/// Username/password WITHOUT email:
/// Firebase Auth does not support username+password directly.
/// We map a username to a synthetic email internally, but UI never shows email.
String _usernameToSyntheticEmail(String username) {
  final u = username.trim().toLowerCase().replaceAll(' ', '');
  // Keep it stable & valid as email local-part.
  final safe = u.replaceAll(RegExp(r'[^a-z0-9._-]'), '_');
  return '$safe@gozen.local';
}

class GozenApp extends StatefulWidget {
  const GozenApp({super.key});

  @override
  State<GozenApp> createState() => _GozenAppState();
}

class _GozenAppState extends State<GozenApp> {
  ThemeMode _themeMode = ThemeMode.light;
  StreamSubscription<User?>? _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = FirebaseAuth.instance.authStateChanges().listen((u) async {
      if (u == null) return;
      // Load user preference for night mode (from Firestore).
      try {
        final snap = await FirebaseFirestore.instance.collection('users').doc(u.uid).get();
        final night = (snap.data()?['nightMode'] as bool?) ?? false;
        if (mounted) {
          setState(() => _themeMode = night ? ThemeMode.dark : ThemeMode.light);
        }
      } catch (_) {
        // ignore
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _toggleNightMode() async {
    final newMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    setState(() => _themeMode = newMode);

    final u = FirebaseAuth.instance.currentUser;
    if (u != null) {
      await FirebaseFirestore.instance.collection('users').doc(u.uid).set(
        {'nightMode': newMode == ThemeMode.dark},
        SetOptions(merge: true),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gozen Pre-Boarding',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        // CardThemeData (NOT CardTheme) to avoid analyzer type errors.
        cardTheme: const CardThemeData(
          margin: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        cardTheme: const CardThemeData(
          margin: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF90CAF9),
          brightness: Brightness.dark,
        ),
      ),
      home: RootShell(onToggleNightMode: _toggleNightMode, themeMode: _themeMode),
    );
  }
}

class RootShell extends StatelessWidget {
  const RootShell({super.key, required this.onToggleNightMode, required this.themeMode});

  final Future<void> Function() onToggleNightMode;
  final ThemeMode themeMode;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _Splash();
        }
        final user = snap.data;
        if (user == null) {
          return AuthPage(onToggleNightMode: onToggleNightMode, themeMode: themeMode);
        }
        return HomePage(onToggleNightMode: onToggleNightMode, themeMode: themeMode);
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, required this.onToggleNightMode, required this.themeMode});

  final Future<void> Function() onToggleNightMode;
  final ThemeMode themeMode;

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _register = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final username = _username.text.trim();
      final pass = _password.text;
      if (username.isEmpty || pass.length < 4) {
        throw Exception('Kullanıcı adı boş olamaz. Şifre en az 4 karakter olmalı.');
      }

      final email = _usernameToSyntheticEmail(username);
      UserCredential cred;
      if (_register) {
        cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email, password: pass);
      } else {
        cred = await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: pass);
      }

      // Store/display username in Firestore.
      await FirebaseFirestore.instance.collection('users').doc(cred.user!.uid).set(
        {
          'username': username,
          'updatedAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } on FirebaseAuthException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.themeMode == ThemeMode.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gozen Login'),
        actions: [
          IconButton(
            onPressed: _busy ? null : widget.onToggleNightMode,
            icon: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
            tooltip: 'Night mode',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _register ? 'Kayıt Ol' : 'Giriş Yap',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Kullanıcı Adı',
                        prefixIcon: Icon(Icons.person),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      onSubmitted: (_) => _busy ? null : _submit(),
                      decoration: const InputDecoration(
                        labelText: 'Şifre',
                        prefixIcon: Icon(Icons.lock),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: 12),
                    ],
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_register ? 'Kayıt Ol' : 'Giriş Yap'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _register = !_register;
                                _error = null;
                              }),
                      child: Text(_register ? 'Zaten hesabım var' : 'Hesabım yok, kayıt ol'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Not: Email kullanılmaz. Firebase Auth için kullanıcı adı, arka planda sahte bir email’e çevrilir.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onToggleNightMode, required this.themeMode});

  final Future<void> Function() onToggleNightMode;
  final ThemeMode themeMode;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    final u = FirebaseAuth.instance.currentUser!;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gozen Pre-Boarding'),
        actions: [
          IconButton(
            onPressed: widget.onToggleNightMode,
            icon: Icon(widget.themeMode == ThemeMode.dark ? Icons.dark_mode : Icons.light_mode),
            tooltip: 'Night mode',
          ),
          IconButton(
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
            icon: const Icon(Icons.logout),
            tooltip: 'Çıkış',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              future: FirebaseFirestore.instance.collection('users').doc(u.uid).get(),
              builder: (context, snap) {
                final username = (snap.data?.data()?['username'] as String?) ?? 'User';
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.person),
                    title: Text('Merhaba, $username'),
                    subtitle: Text('UID: ${u.uid.substring(0, 8)}…'),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.flight_takeoff),
                title: const Text('Flight Create / Join'),
                subtitle: const Text('Uçuş oluştur, katıl ve Scan ekranına geç'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const FlightCreateJoinPage()),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FlightCreateJoinPage extends StatefulWidget {
  const FlightCreateJoinPage({super.key});

  @override
  State<FlightCreateJoinPage> createState() => _FlightCreateJoinPageState();
}

class _FlightCreateJoinPageState extends State<FlightCreateJoinPage> {
  final _flightCodeCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _flightCodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _createOrJoin({required bool create}) async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final raw = _flightCodeCtrl.text;
      final flightCode = normalizeFlightCode(raw);
      if (flightCode.isEmpty) throw Exception('Uçuş kodu boş olamaz.');

      final uid = FirebaseAuth.instance.currentUser!.uid;
      final sessions = FirebaseFirestore.instance.collection('sessions');

      DocumentReference<Map<String, dynamic>> sessionRef;

      if (create) {
        sessionRef = await sessions.add({
          'flightCode': flightCode,
          'ownerUid': uid,
          'members': [uid],
          'active': true,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } else {
        // Join latest active session with same flightCode
        final q = await sessions
            .where('flightCode', isEqualTo: flightCode)
            .where('active', isEqualTo: true)
            .orderBy('createdAt', descending: true)
            .limit(1)
            .get();

        if (q.docs.isEmpty) {
          throw Exception('Aktif uçuş bulunamadı: $flightCode');
        }

        sessionRef = q.docs.first.reference;
        await sessionRef.update({
          'members': FieldValue.arrayUnion([uid]),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ScanPage(sessionId: sessionRef.id, flightCode: flightCode),
        ),
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flight Create / Join')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Uçuş Kodu', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _flightCodeCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(
                        hintText: 'BA679',
                        prefixIcon: Icon(Icons.flight),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Not: BA0679 / BA00679 / BA000679 okutulsa bile BA679 olarak kabul edilir.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      const SizedBox(height: 12),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _busy ? null : () => _createOrJoin(create: true),
                            icon: const Icon(Icons.add),
                            label: _busy ? const Text('...') : const Text('Create'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : () => _createOrJoin(create: false),
                            icon: const Icon(Icons.login),
                            label: _busy ? const Text('...') : const Text('Join'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.list),
                title: const Text('Benim aktif uçuşlarım'),
                subtitle: const Text('Owner veya member olduğun session’lar'),
              ),
            ),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('sessions')
                  .where('active', isEqualTo: true)
                  .where('members', arrayContains: FirebaseAuth.instance.currentUser!.uid)
                  .orderBy('createdAt', descending: true)
                  .limit(20)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Aktif uçuş yok.'),
                  );
                }
                return Column(
                  children: docs.map((d) {
                    final fc = (d.data()['flightCode'] as String?) ?? '-';
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.flight),
                        title: Text(fc),
                        subtitle: Text('Session: ${d.id.substring(0, 8)}…'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (_) => ScanPage(sessionId: d.id, flightCode: fc)),
                          );
                        },
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key, required this.sessionId, required this.flightCode});

  final String sessionId;
  final String flightCode;

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _scanCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _scanCtrl.dispose();
    super.dispose();
  }

  Future<void> _manualBoard() async {
    final nameCtrl = TextEditingController();
    final seatCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Manual Board'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Ad Soyad'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: seatCtrl,
              decoration: const InputDecoration(labelText: 'Seat No (örn 12A)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Board')),
        ],
      ),
    );

    if (ok != true) {
      nameCtrl.dispose();
      seatCtrl.dispose();
      return;
    }

    final name = nameCtrl.text.trim();
    final seat = seatCtrl.text.trim().toUpperCase();
    nameCtrl.dispose();
    seatCtrl.dispose();

    if (name.isEmpty || seat.isEmpty) {
      _showFullScreenMessage(success: false, title: 'HATA', message: 'Ad Soyad ve Seat zorunlu.');
      return;
    }

    await _writeBoard(name: name, seat: seat, source: 'manual');
  }

  Future<void> _writeBoard({required String name, required String seat, required String source}) async {
    setState(() => _busy = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;

      await FirebaseFirestore.instance.collection('sessions').doc(widget.sessionId).collection('pax').add({
        'name': name,
        'seat': seat,
        'boardedBy': uid,
        'source': source,
        'createdAt': FieldValue.serverTimestamp(),
      });

      _showFullScreenMessage(success: true, title: 'OK', message: '$name • $seat');
    } catch (e) {
      _showFullScreenMessage(success: false, title: 'HATA', message: e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showFullScreenMessage({required bool success, required String title, required String message}) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => _FullScreenMessage(
          success: success,
          title: title,
          message: message,
        ),
      ),
    );
  }

  Future<void> _processScan() async {
    final scanned = normalizeFlightCode(_scanCtrl.text);
    final expected = normalizeFlightCode(widget.flightCode);

    if (scanned.isEmpty) {
      _showFullScreenMessage(success: false, title: 'HATA', message: 'Boş scan.');
      return;
    }

    if (scanned != expected) {
      _showFullScreenMessage(
        success: false,
        title: 'FLIGHT MISMATCH',
        message: 'Beklenen: $expected\nOkunan: $scanned',
      );
      return;
    }

    _showFullScreenMessage(success: true, title: 'SCAN OK', message: 'Flight: $expected');
  }

  @override
  Widget build(BuildContext context) {
    final fc = normalizeFlightCode(widget.flightCode);

    return Scaffold(
      appBar: AppBar(
        title: Text('Scan • $fc'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const FlightCreateJoinPage()),
            );
          },
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Session', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(widget.sessionId, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    Text('Flight Code', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(fc, style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _scanCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Scan input (barcode text)',
                        prefixIcon: Icon(Icons.qr_code_scanner),
                        hintText: 'BA0679 / BA00679 / ...',
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy ? null : _processScan,
                      icon: const Icon(Icons.check),
                      label: Text(_busy ? '...' : 'Process Scan'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _manualBoard,
                      icon: const Icon(Icons.edit),
                      label: const Text('Manual Board'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.people),
                title: const Text('Boarded pax (son 20)'),
              ),
            ),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('sessions')
                  .doc(widget.sessionId)
                  .collection('pax')
                  .orderBy('createdAt', descending: true)
                  .limit(20)
                  .snapshots(),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Henüz kayıt yok.'),
                  );
                }
                return Column(
                  children: docs.map((d) {
                    final data = d.data();
                    final name = (data['name'] as String?) ?? '-';
                    final seat = (data['seat'] as String?) ?? '-';
                    final source = (data['source'] as String?) ?? '-';
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.check_circle_outline),
                        title: Text('$name • $seat'),
                        subtitle: Text('source: $source'),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FullScreenMessage extends StatelessWidget {
  const _FullScreenMessage({required this.success, required this.title, required this.message});

  final bool success;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final bg = success ? Colors.green : Colors.red;
    return Scaffold(
      backgroundColor: bg.withValues(alpha: 0.92),
      body: SafeArea(
        child: InkWell(
          onTap: () => Navigator.of(context).pop(),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Kapatmak için dokun',
                    style: TextStyle(color: Colors.white70),
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

