import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'home_page.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();

  await Supabase.initialize(
    url: 'https://iztwxujppgavovmbgkrm.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Iml6dHd4dWpwcGdhdm92bWJna3JtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njg0MTY4ODMsImV4cCI6MjA4Mzk5Mjg4M30.EXtWPyOb7NXoP9s1lXorv_jxfVmB8SWUlb8MgMmLtT0',
  );

  // Initialize Notifications
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  await flutterLocalNotificationsPlugin.initialize(const InitializationSettings(android: initializationSettingsAndroid));

  // Create Notification Channel for Android 8+
  final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
      flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  await androidImplementation?.createNotificationChannel(const AndroidNotificationChannel(
    'patrol_channel_id', 
    'Patrol Alerts',
    importance: Importance.max,
    sound: RawResourceAndroidNotificationSound('alert'),
  ));

  runApp(const VeriPatrolApp());
}

class VeriPatrolApp extends StatelessWidget {
  const VeriPatrolApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const LoginScreen(),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _passCtrl = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _scheduleBackgroundAlarms();
  }

  // LOGIC: Determine current "Lot" based on 5-min early rule and fixed 9PM slots
  DateTime _getCurrentLotStart() {
    final now = DateTime.now();
    final h = now.hour;
    final m = now.minute;

    // 1. Fixed Special Lot: 9:31 PM to 9:50 PM
    if (h == 21 && m >= 31 && m <= 54) {
      return DateTime(now.year, now.month, now.day, 21, 31);
    }
    
    // 2. Fixed Special Lot: 9:00 PM to 9:30 PM (Starts at 8:55 PM)
    if ((h == 20 && m >= 55) || (h == 21 && m <= 30)) {
      return DateTime(now.year, now.month, now.day, 21, 0);
    }

    // 3. Night Lots: 10 PM - 6 AM (30-min intervals with 5-min buffer)
    if (h >= 22 || h < 6) {
      int effectiveMinute = m + 5; 
      int startMin = (effectiveMinute < 30) ? 0 : (effectiveMinute < 60 ? 30 : 0);
      int effectiveHour = (effectiveMinute >= 60) ? h + 1 : h;
      return DateTime(now.year, now.month, now.day, effectiveHour, startMin);
    } 

    // 4. Day Lots: 6 AM - 8:59 PM (1-hour intervals with 5-min buffer)
    int effectiveHourDay = (m >= 55) ? h + 1 : h;
    return DateTime(now.year, now.month, now.day, effectiveHourDay, 0);
  }

  Future<void> _scheduleBackgroundAlarms() async {
    await flutterLocalNotificationsPlugin.cancelAll();
    final now = tz.TZDateTime.now(tz.local);
    
    // Schedule for the next 5 hours (5 mins before each hour/half-hour)
    for (int i = 1; i <= 5; i++) {
      final scheduledTime = now.add(Duration(hours: i)).subtract(const Duration(minutes: 5));
      await flutterLocalNotificationsPlugin.zonedSchedule(
        i, 'PATROL ALERT', 'Patrol starts in 5 minutes!', scheduledTime,
        const NotificationDetails(android: AndroidNotificationDetails('patrol_channel_id', 'Patrol Alerts', sound: RawResourceAndroidNotificationSound('alert'))),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

  Future<void> _handlePinEntry(String value) async {
    if (value.length == 4) {
      setState(() => _isLoading = true);
      final client = Supabase.instance.client;
      try {
        final userData = await client.from('security_users').select('security_name, factory').eq('security_password', value).maybeSingle();

        if (userData != null) {
          String name = userData['security_name'];
          String fCode = userData['factory'];
          
          if (name.toUpperCase() == "MASTER") {
            _goToHome(name, fCode, true);
            return;
          }

          // Check if this LOT is already done
          final lotStart = _getCurrentLotStart();
          final existing = await client.from('scanning_details').select('id')
              .eq('factory_code', fCode)
              .gte('scan_time', lotStart.toIso8601String())
              .limit(1);

          if (existing.isNotEmpty) {
            _passCtrl.clear();
            if (mounted) _showLockDialog();
          } else {
            _goToHome(name, fCode, false);
          }
        } else {
          _passCtrl.clear();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("INVALID PIN")));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  void _goToHome(String n, String f, bool m) {
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (c) => HomePage(guardName: n, factoryCode: f, isMaster: m)));
  }

  void _showLockDialog() {
    showDialog(context: context, builder: (c) => AlertDialog(
      title: const Icon(Icons.lock, color: Colors.red, size: 50),
      content: const Text("THIS LOT IS COMPLETED\nPlease wait for the next patrol window.", textAlign: TextAlign.center),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text("OK"))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/logo.png', height: 130, errorBuilder: (c,e,s) => const Icon(Icons.security, size: 80)),
            const SizedBox(height: 20),
            const Text("VERIPATROL", style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            const SizedBox(height: 40),
            if (_isLoading) const CircularProgressIndicator()
            else SizedBox(
              width: 180,
              child: TextField(
                controller: _passCtrl,
                obscureText: true,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                maxLength: 4,
                style: const TextStyle(fontSize: 28, letterSpacing: 10),
                decoration: InputDecoration(hintText: "PIN", counterText: "", border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                onChanged: _handlePinEntry,
              ),
            ),
          ],
        ),
      ),
    );
  }
}