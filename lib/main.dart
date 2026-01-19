import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:intl/intl.dart';
import 'package:mailer/mailer.dart' as mailer;
import 'package:mailer/smtp_server.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VeriPatrolApp());
}

// --- 🛠️ DATABASE & SYNC ENGINE ---
class DBHelper {
  static Database? _db;
  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await openDatabase(
      p.join(await getDatabasesPath(), 'veripatrol_v7.db'),
      onCreate: (db, version) => db.execute(
          "CREATE TABLE logs(id INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, qr_id TEXT, lat REAL, lon REAL, time TEXT, status TEXT)"),
      version: 1,
    );
    return _db!;
  }

  static Future<void> saveLog(String type, String qr, double lat, double lon, String status) async {
    final db = await database;
    await db.insert('logs', {
      'type': type, 'qr_id': qr, 'lat': lat, 'lon': lon,
      'time': DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
      'status': status,
    });
  }

  static Future<void> syncOfflineLogs() async {
    final db = await database;
    List<Map<String, dynamic>> pending = await db.query('logs', where: 'status = ?', whereArgs: ['PENDING_SYNC']);
    if (pending.isEmpty) return;

    final smtpServer = gmail("c.sakthivel1.3.2006@gmail.com", "nukmunhdqskltnze");
    
    for (var log in pending) {
      try {
        final message = mailer.Message()
          ..from = const mailer.Address("c.sakthivel1.3.2006@gmail.com", 'VeriPatrol Sync')
          ..recipients.add("godwinsamraj16@gmail.com")
          ..subject = '📊 Offline Log Synced: ${log['type']}'
          ..text = 'Recovered Log:\nType: ${log['type']}\nTime: ${log['time']}\nMap: http://google.com/maps?q=${log['lat']},${log['lon']}';

        await mailer.send(message, smtpServer);
        await db.update('logs', {'status': 'SENT_AFTER_SYNC'}, where: 'id = ?', whereArgs: [log['id']]);
      } catch (e) {
        debugPrint("Sync failed for ID ${log['id']}");
      }
    }
  }
}

class AppConfig {
  static bool isTamil = false;
  static String t(String en, String ta) => isTamil ? ta : en;
}

class VeriPatrolApp extends StatefulWidget {
  const VeriPatrolApp({super.key});
  @override
  State<VeriPatrolApp> createState() => _VeriPatrolAppState();
}

class _VeriPatrolAppState extends State<VeriPatrolApp> {
  @override
  void initState() {
    super.initState();
    _handleStartup();
  }

  Future<void> _handleStartup() async {
    await Geolocator.requestPermission();
    await DBHelper.syncOfflineLogs();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: Colors.black, fontFamily: 'monospace'),
      home: LoginScreen(onLangToggle: () => setState(() => AppConfig.isTamil = !AppConfig.isTamil)),
    );
  }
}

// --- 1. LOGIN SCREEN WITH LOGO ---
class LoginScreen extends StatelessWidget {
  final VoidCallback onLangToggle;
  LoginScreen({super.key, required this.onLangToggle});
  final TextEditingController _pin = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, actions: [
        TextButton(onPressed: onLangToggle, child: Text(AppConfig.t("English", "தமிழ்")))
      ]),
      body: Center(
        child: SingleChildScrollView(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            // APP LOGO DISPLAY
            Image.asset('assets/logo.png', height: 150, width: 150, errorBuilder: (c, e, s) => const Icon(Icons.security, size: 100, color: Colors.blueAccent)),
            const SizedBox(height: 30),
            Text(AppConfig.t("VERIPATROL CORE", "வெரிபெட்ரோல் கோர்"), style: const TextStyle(fontSize: 18, letterSpacing: 2, fontWeight: FontWeight.bold)),
            const SizedBox(height: 50),
            SizedBox(width: 220, child: TextField(
              controller: _pin, obscureText: true, keyboardType: TextInputType.number, maxLength: 4, textAlign: TextAlign.center,
              onChanged: (v) {
                if (v == "1111" || v == "1234") {
                  DBHelper.syncOfflineLogs();
                  Navigator.pushReplacement(context, MaterialPageRoute(builder: (c) => HomePage(guardName: v == "1111" ? "CHANDRU" : "SARAN")));
                }
              },
              decoration: InputDecoration(hintText: "****", fillColor: Colors.grey[900], filled: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(15))),
            )),
          ]),
        ),
      ),
    );
  }
}

// --- 2. HOME PAGE ---
class HomePage extends StatefulWidget {
  final String guardName;
  const HomePage({super.key, required this.guardName});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _time = "";
  late Timer _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (t) {
      if (mounted) setState(() => _time = DateFormat('HH:mm:ss').format(DateTime.now()));
    });
  }

  @override
  void dispose() { _t.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.guardName), centerTitle: true),
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const ScanningPage())),
            child: Container(
              padding: const EdgeInsets.all(30),
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.blueAccent, width: 2)),
              child: const Icon(Icons.qr_code_scanner, size: 80, color: Colors.blueAccent),
            ),
          ),
          const SizedBox(height: 40),
          Text(_time, style: const TextStyle(fontSize: 50, fontWeight: FontWeight.bold, color: Colors.white)),
        ]),
      ),
    );
  }
}

// --- 3. SCANNING PAGE ---
class ScanningPage extends StatefulWidget {
  const ScanningPage({super.key});
  @override
  State<ScanningPage> createState() => _ScanningPageState();
}

class _ScanningPageState extends State<ScanningPage> {
  final MobileScannerController ctrl = MobileScannerController();
  final ScreenshotController screenshotController = ScreenshotController();
  final Map<String, String> _status = {"loc1": "PENDING", "loc2": "PENDING", "loc3": "PENDING"};
  bool _isSosBusy = false;
  int _wait = 0;
  String? _activeQr;

  Future<void> _triggerSos() async {
    if (_isSosBusy) return;
    setState(() => _isSosBusy = true);
    HapticFeedback.vibrate();

    double lat = 0.0; double lon = 0.0;
    Uint8List? image = await screenshotController.capture();

    try {
      Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high).timeout(const Duration(seconds: 8));
      lat = pos.latitude; lon = pos.longitude;

      final smtpServer = gmail("c.sakthivel1.3.2006@gmail.com", "nukmunhdqskltnze");
      final message = mailer.Message()
        ..from = const mailer.Address("c.sakthivel1.3.2006@gmail.com", 'VeriPatrol SOS')
        ..recipients.add("godwinsamraj16@gmail.com")
        ..subject = '🚨 SOS EMERGENCY ALERT'
        ..text = 'Guard in Distress!\nLocation: http://google.com/maps?q=$lat,$lon';

      if (image != null) {
        final temp = await getTemporaryDirectory();
        final file = await File('${temp.path}/sos_snap.png').writeAsBytes(image);
        message.attachments.add(mailer.FileAttachment(file));
      }

      await mailer.send(message, smtpServer);
      await DBHelper.saveLog("SOS", "EMERGENCY", lat, lon, "SENT_LIVE");
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("🚀 SOS SENT LIVE"), backgroundColor: Colors.green));

    } catch (e) {
      await DBHelper.saveLog("SOS", "EMERGENCY", lat, lon, "PENDING_SYNC");
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("📁 OFFLINE: Saved for Sync"), backgroundColor: Colors.orange));
    } finally {
      if (mounted) setState(() => _isSosBusy = false);
    }
  }

  void _onDetect(BarcodeCapture capture) async {
    final String? qr = capture.barcodes.first.rawValue;
    if (qr == null || _wait > 0 || !_status.containsKey(qr)) return;

    try {
      Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.low);
      if (_status[qr] == "PENDING" && _activeQr == null) {
        setState(() { _activeQr = qr; _status[qr] = "WAITING..."; _wait = 60; });
        Timer.periodic(const Duration(seconds: 1), (t) {
          if (_wait > 0) { if (mounted) setState(() => _wait--); } 
          else { t.cancel(); if (mounted) setState(() => _status[qr] = "RE-SCAN"); }
        });
      } else if (_status[qr] == "RE-SCAN" && _activeQr == qr) {
        await DBHelper.saveLog("SCAN", qr, pos.latitude, pos.longitude, "COMPLETED");
        setState(() { _status[qr] = "COMPLETED"; _activeQr = null; });
        if (_status.values.every((v) => v == "COMPLETED") && mounted) Navigator.pop(context, true);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("GUARD ROUNDS")),
      floatingActionButton: FloatingActionButton(onPressed: _triggerSos, backgroundColor: Colors.red, child: const Icon(Icons.warning, color: Colors.white)),
      body: Column(children: [
        Screenshot(
          controller: screenshotController,
          child: Container(
            height: 300, margin: const EdgeInsets.all(20),
            decoration: BoxDecoration(border: Border.all(color: Colors.blueAccent), borderRadius: BorderRadius.circular(20)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(children: [
                MobileScanner(controller: ctrl, onDetect: _onDetect),
                if (_wait > 0) Container(color: Colors.black54, child: Center(child: Text("$_wait", style: const TextStyle(fontSize: 100, color: Colors.orange, fontWeight: FontWeight.bold)))),
              ]),
            ),
          ),
        ),
        Expanded(child: ListView(children: _status.keys.map((k) => ListTile(
          leading: Icon(_status[k] == "COMPLETED" ? Icons.check_circle : Icons.radio_button_unchecked, color: _status[k] == "COMPLETED" ? Colors.green : Colors.grey),
          title: Text("POINT: ${k.toUpperCase()}"),
          subtitle: Text("STATUS: ${_status[k]}"),
        )).toList())),
      ]),
    );
  }
}