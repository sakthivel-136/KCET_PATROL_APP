import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
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

class _LoginScreenState extends State<LoginScreen> {
  final List<String> _pin = [];
  bool _loading = false;
  bool _shakeError = false;
  String _selectedLang = "EN"; // 'EN' or 'TA'

  static const Map<String, Map<String, String>> _i10n = {
    'KCET Security': {'EN': 'KCET Security', 'TA': 'கேசிஇடி பாதுகாப்பு'},
    'Patrol Monitoring System': {'EN': 'Patrol Monitoring System', 'TA': 'ரோந்து கண்காணிப்பு அமைப்பு'},
    'Enter your 4-digit Security PIN': {'EN': 'Enter your 4-digit Security PIN', 'TA': 'உங்கள் 4 இலக்க பாதுகாப்பு பின்னை உள்ளிடவும்'},
    'Verifying...': {'EN': 'Verifying...', 'TA': 'சரிபார்க்கிறது...'},
    'Powered by KCET • v2.0': {'EN': 'Powered by KCET • v2.0', 'TA': 'கேசிஇடி பெருமையுடன் வழங்கும் • பதிப்பு 2.0'},
    'No Internet Connection': {'EN': 'No Internet Connection', 'TA': 'இணைய இணைப்பு இல்லை'},
    'Invalid PIN — try again': {'EN': 'Invalid PIN — try again', 'TA': 'தவறான பின் — மீண்டும் முயற்சிக்கவும்'},
    'Server error. Check connection.': {'EN': 'Server error. Check connection.', 'TA': 'சேவையக பிழை. இணைப்பைச் சரிபார்க்கவும்.'},
    'Access Denied': {'EN': 'Access Denied', 'TA': 'அனுமதி மறுக்கப்பட்டது'},
    'OK': {'EN': 'OK', 'TA': 'சரி'},
  };

  String _t(String key) {
    return _i10n[key]?[_selectedLang] ?? key;
  }

  @override
  void initState() {
    super.initState();
    _loadSavedLanguage();
    Future.delayed(const Duration(milliseconds: 500), () async {
      await _requestNotificationPermission();
      await _scheduleNotifications();
    });
  }

  Future<void> _loadSavedLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lang = prefs.getString('user_lang') ?? 'EN';
      if (mounted) setState(() => _selectedLang = lang);
    } catch (_) {}
  }

  Future<void> _toggleLanguage() async {
    final nextLang = _selectedLang == 'EN' ? 'TA' : 'EN';
    HapticFeedback.lightImpact();
    setState(() => _selectedLang = nextLang);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_lang', nextLang);
    } catch (_) {}
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
    if (mounted) {
      setState(() {
        _pin.clear();
        _shakeError = false;
      });
    }
  }

  Future<bool> _isOnline() async {
    final r = await Connectivity().checkConnectivity();
    return !r.contains(ConnectivityResult.none);
  }

  Future<void> _login(String pin) async {
    if (pin.length != 4) return;
    if (!await _isOnline()) { _showError("No Internet Connection"); return; }
    setState(() => _loading = true);
    final apiUrl = 'https://kcet-patrol-api.kcet-patrol-hq.workers.dev/api';
    try {
      
      final res = await http.post(
        Uri.parse('$apiUrl/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'pin': pin})
      );
      
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['role'] == 'ADMIN') {
          await _goHome(data['name'] ?? 'Admin', 'ADMIN', true, true);
          return;
        } else {
          await _goHome(data['security_name'] ?? 'Guard', data['campus'] ?? 'KCET01', false, true);
          return;
        }
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: _kError,
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        content: Row(children: [
          const Icon(Icons.error_outline_rounded, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Text(msg, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        ]),
      ));
  }

  void _showShiftError(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: const Color(0xFF121A3E),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: _kError.withOpacity(0.1), shape: BoxShape.circle),
              child: const Icon(Icons.block_rounded, color: _kError, size: 36),
            ),
            const SizedBox(height: 16),
            const Text("Access Denied",
              style: TextStyle(color: _kError, fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 12),
            Text(msg, textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4)),
            const SizedBox(height: 20),
            SizedBox(width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAccent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
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

  Future<void> _goHome(String name, String campus, bool isAdmin, bool canScan) async {
    try {
      final apiUrl = 'https://kcet-patrol-api.kcet-patrol-hq.workers.dev/api';
      
      final roundsRes = await http.get(Uri.parse('$apiUrl/rounds'));
      final roundsData = jsonDecode(roundsRes.body);
      final qrRes = await http.get(Uri.parse('$apiUrl/qrs/$campus'));
      final qrData = jsonDecode(qrRes.body);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cached_rounds', jsonEncode(roundsData));
      await prefs.setString('cached_qrs', jsonEncode(qrData));
    } catch (e) {
      debugPrint('Error caching data: $e');
    }
    
    await loadCachedRounds();

    if (!mounted) return;
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
      body: SafeArea(
        child: Column(
          children: [
            // Top Bar with Translate Button
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: _toggleLanguage,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _kAccent.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _kAccent.withOpacity(0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.translate_rounded, color: _kAccent2, size: 14),
                        const SizedBox(width: 6),
                        Text(_selectedLang == 'EN' ? 'தமிழ்' : 'English',
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  children: [
                    const SizedBox(height: 20),

                    // Clean & Simple Logo Icon
                    Container(
                      width: 80, height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _kAccent.withOpacity(0.12),
                        border: Border.all(color: _kAccent.withOpacity(0.3), width: 1.5),
                      ),
                      child: Center(
                        child: Image.asset('assets/logo.png', width: 44, height: 44,
                          errorBuilder: (_, __, ___) =>
                            const Icon(Icons.shield_rounded, size: 40, color: _kAccent)),
                      ),
                    ),

                    const SizedBox(height: 18),

                    Text(_t("KCET Security"), style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.bold,
                      color: Colors.white, letterSpacing: 0.5,
                    )),
                    const SizedBox(height: 4),
                    Text(_t("Patrol Monitoring System"),
                      style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.5), letterSpacing: 1)),

                    const SizedBox(height: 24),

                    // Live Clock
                    StreamBuilder(
                      stream: Stream.periodic(const Duration(seconds: 1)),
                      builder: (_, __) => Column(children: [
                        Text(DateFormat('hh:mm:ss a').format(DateTime.now()),
                          style: const TextStyle(
                            fontSize: 18, color: Colors.white70,
                            fontWeight: FontWeight.w400, letterSpacing: 1,
                            fontFeatures: [FontFeature.tabularFigures()],
                          )),
                        const SizedBox(height: 2),
                        Text(DateFormat('EEEE, d MMMM yyyy').format(DateTime.now()),
                          style: const TextStyle(fontSize: 12, color: Colors.white38)),
                      ]),
                    ),

                    const SizedBox(height: 28),

                    // PIN Dots
                    _buildPinDisplay(),
                    const SizedBox(height: 12),
                    Text(
                      _t(_loading ? "Verifying..." : "Enter your 4-digit Security PIN"),
                      style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.5)),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),

            // Numeric Keypad
            _buildPinPad(),
            const SizedBox(height: 12),
            Text(_t("Powered by KCET • v2.0"),
              style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.3))),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildPinDisplay() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (i) {
        final filled = i < _pin.length;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? (_shakeError ? _kError : _kAccent) : Colors.white.withOpacity(0.15),
            border: Border.all(
              color: filled ? Colors.transparent : Colors.white24, width: 1.5),
          ),
        );
      }),
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
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: rows.map((row) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: row.map((k) {
              final isAction = k == '⌫' || k == 'C';
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: _loading ? null : () {
                        if (k == '⌫') _onDelete();
                        else if (k == 'C') _onClear();
                        else _onKey(k);
                      },
                      child: Container(
                        height: 56,
                        decoration: BoxDecoration(
                          color: isAction
                            ? Colors.white.withOpacity(0.04)
                            : Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white.withOpacity(0.06)),
                        ),
                        child: Center(
                          child: Text(k, style: TextStyle(
                            fontSize: k == '⌫' ? 18 : 20,
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
