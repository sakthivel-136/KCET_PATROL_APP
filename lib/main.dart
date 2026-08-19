import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'home_page.dart';
import 'round_utils.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// ─── Palette ─────────────────────────────────────────────────────────────────
const _kC1 = Color(0xFF0A0E27);
const _kC2 = Color(0xFF0D1B4B);
const _kC3 = Color(0xFF0A2472);
const _kAccent  = Color(0xFF2979FF);
const _kAccent2 = Color(0xFF00E5FF);
const _kError   = Color(0xFFFF1744);

// ─── Main ─────────────────────────────────────────────────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  try { tz.initializeTimeZones(); } catch (_) {}
  _initializeNotifications();
  try {
    await Future.any([
      Supabase.initialize(
        url: 'https://jnzvystfghhhvvnmkygj.supabase.co',
        anonKey: 'sb_publishable_3UHiK7knPpgBjBviPLN0jQ_kMc7p1ci',
      ),
      Future.delayed(const Duration(seconds: 10), () => throw TimeoutException('timeout')),
    ]);
  } catch (_) {}
  runApp(const KcetSecurityRoundsApp());
}

Future<void> _initializeNotifications() async {
  try {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await flutterLocalNotificationsPlugin.initialize(
      const InitializationSettings(android: androidInit));
    final android = flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      'patrol_channel_id', 'Patrol Alerts',
      importance: Importance.max, playSound: true,
      sound: RawResourceAndroidNotificationSound('alert'),
      enableVibration: true,
    ));
  } catch (_) {}
}

// ─── App ──────────────────────────────────────────────────────────────────────
class KcetSecurityRoundsApp extends StatelessWidget {
  const KcetSecurityRoundsApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'KCET Security Rounds',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Roboto',
        primaryColor: _kAccent,
        scaffoldBackgroundColor: _kC1,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _kAccent,
          brightness: Brightness.dark,
          surface: const Color(0xFF121A3E),
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const LoginScreen(),
        '/home': (context) {
          final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
          return HomePage(
            guardName: args?['guardName'] ?? '',
            campusCode: args?['campusCode'] ?? '',
            isMaster: args?['isMaster'] ?? false,
            canScan: args?['canScan'] ?? false,
          );
        },
      },
    );
  }
}

// ─── Login Screen ─────────────────────────────────────────────────────────────
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  final List<String> _pin = [];
  bool _loading = false;
  bool _shakeError = false;

  late AnimationController _bgCtrl;
  late AnimationController _logoCtrl;
  late AnimationController _shakeCtrl;
  late AnimationController _fadeCtrl;
  late Animation<double> _bgAnim;
  late Animation<double> _logoRotate;
  late Animation<double> _shakeAnim;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _bgCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat(reverse: true);
    _bgAnim = CurvedAnimation(parent: _bgCtrl, curve: Curves.easeInOut);
    _logoCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();
    _logoRotate = Tween<double>(begin: 0, end: 2 * math.pi).animate(_logoCtrl);
    _shakeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _shakeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _shakeCtrl, curve: Curves.elasticIn));
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();
    Future.delayed(const Duration(milliseconds: 500), () async {
      await _requestNotificationPermission();
      await _scheduleNotifications();
    });
  }

  @override
  void dispose() {
    _bgCtrl.dispose(); _logoCtrl.dispose();
    _shakeCtrl.dispose(); _fadeCtrl.dispose();
    super.dispose();
  }

  void _onKey(String val) {
    if (_loading) return;
    HapticFeedback.lightImpact();
    if (_pin.length < 4) {
      setState(() => _pin.add(val));
      if (_pin.length == 4) {
        Future.delayed(const Duration(milliseconds: 150), () => _login(_pin.join()));
      }
    }
  }

  void _onDelete() {
    if (_loading || _pin.isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() => _pin.removeLast());
  }

  void _onClear() {
    HapticFeedback.mediumImpact();
    setState(() => _pin.clear());
  }

  Future<void> _triggerShake() async {
    _shakeCtrl.reset();
    await _shakeCtrl.forward();
    if (mounted) setState(() { _pin.clear(); _shakeError = false; });
  }

  Future<bool> _isOnline() async {
    final r = await Connectivity().checkConnectivity();
    return !r.contains(ConnectivityResult.none);
  }

  Future<void> _login(String pin) async {
    if (pin.length != 4) return;
    if (!await _isOnline()) { _showError("No Internet Connection"); return; }
    setState(() => _loading = true);
    final db = Supabase.instance.client;
    try {
      Map<String, dynamic>? admin;
      try {
        admin = await db.from('login_info').select('name,role')
            .eq('user_pin', pin).eq('is_active', true).maybeSingle();
      } catch (_) {}
      if (admin != null) { _goHome(admin['name'], 'ADMIN', true, true); return; }

      final guard = await db.from('security_users')
          .select('security_id,security_name,campus,role')
          .eq('security_password', pin).maybeSingle();

      if (guard != null) {
        if (guard['role'] != 'ADMIN') {
          try {
            final allocations = await db.from('shift_allocations')
                .select('shift_id, shifts(start_time, end_time)')
                .eq('security_id', guard['security_id']);
            if (allocations != null && allocations.isNotEmpty) {
              bool anyActive = false;
              String hoursMsg = "";
              for (var a in allocations) {
                final s = a['shifts'];
                if (s != null) {
                  final st = s['start_time'] as String?;
                  final en = s['end_time'] as String?;
                  if (st != null && en != null) {
                    final now = DateTime.now();
                    final cur = now.hour * 60 + now.minute;
                    final sP = st.split(':'); final eP = en.split(':');
                    if (sP.length >= 2 && eP.length >= 2) {
                      final sm = int.parse(sP[0]) * 60 + int.parse(sP[1]);
                      final em = int.parse(eP[0]) * 60 + int.parse(eP[1]);
                      final within = sm <= em ? (cur >= sm && cur <= em) : (cur >= sm || cur <= em);
                      if (within) { anyActive = true; break; }
                      if (hoursMsg.isNotEmpty) hoursMsg += '\n';
                      hoursMsg += '• $st to $en';
                    }
                  }
                }
              }
              if (!anyActive) { _showShiftError("Outside your shift hours!\n\nAllowed:\n$hoursMsg"); return; }
            } else {
              _showShiftError("No shifts allocated for today."); return;
            }
          } catch (_) {}
        }
        _goHome(guard['security_name'], guard['campus'] ?? 'KCET01', guard['role'] == 'ADMIN', true);
        return;
      }
      HapticFeedback.heavyImpact();
      setState(() => _shakeError = true);
      _triggerShake();
      _showError("Invalid PIN — try again");
    } catch (e) {
      _showError("Server error. Check connection.");
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        backgroundColor: _kError,
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        content: Row(children: [
          const Icon(Icons.error_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ]),
      ));
  }

  void _showShiftError(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: const Color(0xFF121A3E),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: _kError.withOpacity(0.1), shape: BoxShape.circle),
              child: const Icon(Icons.block_rounded, color: _kError, size: 40),
            ),
            const SizedBox(height: 16),
            const Text("Access Denied",
              style: TextStyle(color: _kError, fontWeight: FontWeight.bold, fontSize: 20)),
            const SizedBox(height: 12),
            Text(msg, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5)),
            const SizedBox(height: 20),
            SizedBox(width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text("OK", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ]),
        ),
      ),
    );
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && Navigator.of(context, rootNavigator: true).canPop())
        Navigator.of(context, rootNavigator: true).pop();
    });
  }

  void _goHome(String name, String campus, bool isAdmin, bool canScan) {
    Navigator.pushReplacementNamed(context, '/home', arguments: {
      'guardName': name, 'campusCode': campus, 'isMaster': isAdmin, 'canScan': canScan,
    });
  }

  Future<void> _requestNotificationPermission() async {
    if (!(await Permission.notification.status).isGranted) await Permission.notification.request();
    if (!(await Permission.camera.status).isGranted) await Permission.camera.request();
    if (!(await Permission.location.status).isGranted) await Permission.location.request();
  }

  Future<void> _scheduleNotifications() async {
    await flutterLocalNotificationsPlugin.cancelAll();
    final now = tz.TZDateTime.now(tz.local);
    final rounds = buildPatrolRounds(DateTime.now());
    for (int i = 0; i < rounds.length && i < 24; i++) {
      final windowStart = getScanWindowStart(rounds[i].time);
      final time = tz.TZDateTime.from(windowStart.toUtc().subtract(const Duration(minutes: 15)), tz.local);
      if (time.isBefore(now)) continue;
      await flutterLocalNotificationsPlugin.zonedSchedule(
        i, "PATROL ROUND INCOMING", "Patrol scan starts in 15 minutes!", time,
        const NotificationDetails(android: AndroidNotificationDetails(
          'patrol_channel_id', 'Patrol Alerts',
          importance: Importance.max, priority: Priority.high, playSound: true,
          sound: RawResourceAndroidNotificationSound('alert'),
          enableVibration: true, fullScreenIntent: false,
        )),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kC1,
      body: AnimatedBuilder(
        animation: _bgAnim,
        builder: (_, child) {
          final t = _bgAnim.value;
          return Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(math.sin(t * math.pi) * 0.5, math.cos(t * math.pi) * 0.5 - 0.3),
                radius: 1.5,
                colors: [
                  Color.lerp(_kC3, _kC2, t)!,
                  Color.lerp(_kC2, _kC1, t)!,
                  _kC1,
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
            child: child,
          );
        },
        child: FadeTransition(
          opacity: _fadeAnim,
          child: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      children: [
                        const SizedBox(height: 32),

                        // Animated Logo
                        AnimatedBuilder(
                          animation: _logoRotate,
                          builder: (_, __) => Stack(
                            alignment: Alignment.center,
                            children: [
                              Transform.rotate(
                                angle: _logoRotate.value,
                                child: CustomPaint(
                                  size: const Size(130, 130),
                                  painter: _DashedRingPainter(color: _kAccent.withOpacity(0.5)),
                                ),
                              ),
                              Container(
                                width: 96, height: 96,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                                    colors: [Color(0xFF1565C0), Color(0xFF0D47A1)],
                                  ),
                                  boxShadow: [BoxShadow(color: _kAccent.withOpacity(0.4), blurRadius: 24, spreadRadius: 2)],
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Image.asset('assets/logo.png', fit: BoxFit.contain,
                                    errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.shield_rounded, size: 44, color: Colors.white)),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 20),

                        const Text("KCET Security", style: TextStyle(
                          fontSize: 26, fontWeight: FontWeight.w900,
                          color: Colors.white, letterSpacing: 1.5,
                        )),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                          decoration: BoxDecoration(
                            color: _kAccent.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: _kAccent.withOpacity(0.3)),
                          ),
                          child: const Text("PATROL MONITORING SYSTEM",
                            style: TextStyle(fontSize: 10, color: _kAccent2,
                              fontWeight: FontWeight.bold, letterSpacing: 2)),
                        ),

                        const SizedBox(height: 28),

                        // Live Clock
                        StreamBuilder(
                          stream: Stream.periodic(const Duration(seconds: 1)),
                          builder: (_, __) => Column(children: [
                            Text(DateFormat('hh:mm:ss a').format(DateTime.now()),
                              style: const TextStyle(
                                fontSize: 20, color: Colors.white70,
                                fontWeight: FontWeight.w300, letterSpacing: 2,
                                fontFeatures: [FontFeature.tabularFigures()],
                              )),
                            const SizedBox(height: 2),
                            Text(DateFormat('EEEE, d MMMM yyyy').format(DateTime.now()),
                              style: const TextStyle(fontSize: 12, color: Colors.white38)),
                          ]),
                        ),

                        const SizedBox(height: 32),

                        // PIN Dots
                        _buildPinDisplay(),
                        const SizedBox(height: 10),
                        Text(
                          _loading ? "Verifying..." : "Enter your 4-digit security PIN",
                          style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.4)),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),

                // Numeric Keypad
                _buildPinPad(),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text("Powered by KCET • v2.0",
                    style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.2))),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPinDisplay() {
    return AnimatedBuilder(
      animation: _shakeAnim,
      builder: (_, child) => Transform.translate(
        offset: Offset(math.sin(_shakeAnim.value * math.pi * 6) * 12, 0),
        child: child,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(4, (i) {
          final filled = i < _pin.length;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutBack,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            width: filled ? 22 : 16,
            height: filled ? 22 : 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled ? (_shakeError ? _kError : _kAccent) : Colors.white.withOpacity(0.15),
              boxShadow: filled ? [BoxShadow(
                color: (_shakeError ? _kError : _kAccent).withOpacity(0.6),
                blurRadius: 14, spreadRadius: 2,
              )] : null,
              border: Border.all(
                color: filled ? Colors.transparent : Colors.white24, width: 1.5),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildPinPad() {
    final rows = [
      ['1','2','3'],
      ['4','5','6'],
      ['7','8','9'],
      ['C','0','⌫'],
    ];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Column(
        children: rows.map((row) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: row.map((k) {
              final isAction = k == '⌫' || k == 'C';
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: _loading ? null : () {
                        if (k == '⌫') _onDelete();
                        else if (k == 'C') _onClear();
                        else _onKey(k);
                      },
                      child: Container(
                        height: 60,
                        decoration: BoxDecoration(
                          color: isAction
                            ? Colors.white.withOpacity(0.05)
                            : Colors.white.withOpacity(0.09),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withOpacity(0.07)),
                        ),
                        child: Center(
                          child: Text(k, style: TextStyle(
                            fontSize: k == '⌫' ? 20 : 22,
                            fontWeight: FontWeight.w600,
                            color: isAction ? Colors.white54 : Colors.white,
                          )),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        )).toList(),
      ),
    );
  }
}

// ─── Dashed Ring Painter ──────────────────────────────────────────────────────
class _DashedRingPainter extends CustomPainter {
  final Color color;
  const _DashedRingPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = 1.5..style = PaintingStyle.stroke;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    const dashCount = 24;
    const dashAngle = (2 * math.pi) / dashCount;
    for (int i = 0; i < dashCount; i++) {
      if (i % 2 == 0) {
        final start = i * dashAngle;
        canvas.drawArc(Rect.fromCircle(center: center, radius: radius),
          start, dashAngle * 0.6, false, paint);
      }
    }
  }
  @override
  bool shouldRepaint(_) => false;
}
