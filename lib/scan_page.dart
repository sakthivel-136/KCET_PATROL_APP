// scan_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';

class ScanningPage extends StatefulWidget {
  final String guardName;
  final String factoryCode;
  final bool isMaster;

  const ScanningPage({
    super.key,
    required this.guardName,
    required this.factoryCode,
    required this.isMaster,
  });

  @override
  State<ScanningPage> createState() => _ScanningPageState();
}

class _ScanningPageState extends State<ScanningPage> {
  final MobileScannerController scannerController =
      MobileScannerController();

  List<Map<String, dynamic>> _checkpoints = [];

  bool _loading = true;
  bool _isProcessing = false;

  String? _activeQrId;

  int _overlayTimer = 0;
  int _totalTime = 0;

  bool _torchOn = false;
  bool _torchReady = false;

  late DateTime _currentRound;

  Timer? _syncTimer;

  DateTime? _lastScanTime; // cooldown

  // ================= INIT =================

  @override
  void initState() {
    super.initState();

    _currentRound = _getRoundStart();

    final h = DateTime.now().hour;
    _torchOn = (h >= 18 || h < 6);

    _initScanner();
    _fetchCheckpoints();

    _syncTimer =
        Timer.periodic(const Duration(seconds: 20), (_) {
      _fetchCheckpoints();
    });
  }

  // ================= SLOT =================

  DateTime _getRoundStart() {
    final now = DateTime.now();

    if (now.minute < 30) {
      return DateTime(
          now.year, now.month, now.day, now.hour, 0);
    } else {
      return DateTime(
          now.year, now.month, now.day, now.hour, 30);
    }
  }

  bool _isValidTime() {
    final now = DateTime.now();

    final start = _currentRound;
    final end = start.add(const Duration(minutes: 25));

    return now.isAfter(start) && now.isBefore(end);
  }

  // ================= SCANNER =================

  void _initScanner() async {
    await Future.delayed(const Duration(milliseconds: 800));

    try {
      _torchReady = true;

      if (_torchOn) {
        await scannerController.toggleTorch();
      }
    } catch (_) {}
  }

  String _norm(dynamic v) {
    if (v == null) return '';
    return v.toString().trim().replaceAll(' ', '');
  }

  // ================= FETCH =================

  Future<void> _fetchCheckpoints() async {
    try {
      final client = Supabase.instance.client;

      final qrData = await client
          .from('qr')
          .select()
          .eq('factory_code', widget.factoryCode)
          .eq('status', 'active');

      final scanData = await client
          .from('scanning_details')
          .select('qr_id,status')
          .eq('factory_code', widget.factoryCode)
          .eq('round_slot', _currentRound.toIso8601String());

      final Set<String> success = {};

      for (var e in scanData) {
        if (e['status'] == 'SUCCESS') {
          success.add(_norm(e['qr_id']));
        }
      }

      if (!mounted) return;

      setState(() {
        _checkpoints = qrData.map((e) {
          final id = _norm(e['qr_id']);

          return {
            ...e,
            'completed': success.contains(id),
            'scanned_once': false,
            'waiting_done': false,
            'timer': 0,
            'waiting_time': e['waiting_time'] ?? 15,
          };
        }).toList();

        _loading = false;
      });

      _checkAutoLogout();
    } catch (e) {
      debugPrint("Fetch error: $e");
    }
  }

  // ================= DB CHECK =================

  Future<bool> _existsSuccess(String qr) async {
    final res = await Supabase.instance.client
        .from('scanning_details')
        .select('id')
        .eq('factory_code', widget.factoryCode)
        .eq('qr_id', qr)
        .eq('round_slot', _currentRound.toIso8601String())
        .eq('status', 'SUCCESS')
        .maybeSingle();

    return res != null;
  }

  // ================= MESSAGE =================

  void _msg(String m, Color c) {
    HapticFeedback.vibrate();

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: c,
        content: Text(
          m,
          style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.white),
        ),
      ),
    );
  }

  // ================= AUTO LOGOUT =================

  void _checkAutoLogout() {
    if (_checkpoints.isEmpty) return;

    final done =
        _checkpoints.every((e) => e['completed'] == true);

    if (done) {
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        Navigator.of(context).pop();
      });
    }
  }

  // ================= SCAN =================

  Future<void> _onScan(BarcodeCapture capture) async {
    // Cooldown (prevents spam)
    final now = DateTime.now();

    if (_lastScanTime != null &&
        now.difference(_lastScanTime!).inSeconds < 2) {
      return;
    }

    _lastScanTime = now;

    if (_isProcessing) return;

    final raw = capture.barcodes.first.rawValue ?? '';
    final qrId = _norm(raw);

    if (qrId.isEmpty) return;

    final index = _checkpoints.indexWhere(
        (p) => _norm(p['qr_id']) == qrId);

    if (index == -1) {
      _msg("UNKNOWN QR", Colors.orange);
      return;
    }

    final p = _checkpoints[index];

    // Already finished
    if (p['completed'] == true) {
      _msg("ALREADY SCANNED", Colors.green);
      return;
    }

    // One at a time lock
    if (_activeQrId != null && _activeQrId != qrId) {
      _msg("FINISH CURRENT QR", Colors.red);
      return;
    }

    final valid =
        widget.isMaster || _isValidTime();

    // ---------- MISSED ----------
    if (!valid) {
      await _saveMissed(p);
      return;
    }

    // ---------- FIRST SCAN ----------
    if (!p['scanned_once'] && p['waiting_done'] == false) {
      if (await _existsSuccess(qrId)) {
        _msg("ALREADY SCANNED", Colors.green);
        _fetchCheckpoints();
        return;
      }

      _startTimer(index);
      return;
    }

    // ---------- SECOND SCAN ----------
    if (p['waiting_done'] == true) {
      if (await _existsSuccess(qrId)) {
        _msg("ALREADY SCANNED", Colors.green);
        _fetchCheckpoints();
        return;
      }

      await _saveSuccess(p);
    }
  }

  // ================= SAVE SUCCESS =================

  Future<void> _saveSuccess(Map p) async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final pos =
          await Geolocator.getCurrentPosition();

      await Supabase.instance.client
          .from('scanning_details')
          .insert({
        'guard_name': widget.guardName,
        'qr_id': p['qr_id'],
        'qr_name': p['qr_name'],
        'lat': pos.latitude,
        'log': pos.longitude,
        'factory_code': widget.factoryCode,
        'scan_time': DateTime.now().toIso8601String(),
        'round_slot': _currentRound.toIso8601String(),
        'status': 'SUCCESS',
      });

      _activeQrId = null;

      _fetchCheckpoints();
      _checkAutoLogout();
    } catch (e) {
      final msg = e.toString();

      if (msg.contains('23505')) {
        _msg("ALREADY SCANNED", Colors.green);
        _fetchCheckpoints();
      } else {
        debugPrint("Save error: $e");
        _msg("UPLOAD FAILED", Colors.red);
      }
    }

    _isProcessing = false;
  }

  // ================= SAVE MISSED =================

  Future<void> _saveMissed(Map p) async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      final pos =
          await Geolocator.getCurrentPosition();

      await Supabase.instance.client
          .from('scanning_details')
          .insert({
        'guard_name': widget.guardName,
        'qr_id': p['qr_id'],
        'qr_name': p['qr_name'],
        'lat': pos.latitude,
        'log': pos.longitude,
        'factory_code': widget.factoryCode,
        'scan_time': DateTime.now().toIso8601String(),
        'round_slot': _currentRound.toIso8601String(),
        'status': 'MISSED',
      });

      _fetchCheckpoints();

      _msg("MARKED MISSED", Colors.red);
    } catch (e) {
      debugPrint("Missed error: $e");
      _msg("UPLOAD FAILED", Colors.red);
    }

    _isProcessing = false;
  }

  // ================= TIMER =================

  void _startTimer(int index) {
    final p = _checkpoints[index];

    setState(() {
      _activeQrId = _norm(p['qr_id']);

      p['scanned_once'] = true;
      p['waiting_done'] = false;

      p['start_time'] = DateTime.now();

      p['timer'] = p['waiting_time'];

      _totalTime = p['waiting_time'];
      _overlayTimer = p['waiting_time'];
    });

    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();

      final remain = p['waiting_time'] -
          DateTime.now()
              .difference(p['start_time'])
              .inSeconds;

      if (remain <= 0) {
        t.cancel();

        setState(() {
          p['timer'] = 0;
          _overlayTimer = 0;

          p['waiting_done'] = true;

          // ❗ DO NOT CLEAR activeQrId HERE
        });

        HapticFeedback.vibrate();
      } else {
        setState(() {
          p['timer'] = remain;
          _overlayTimer = remain;
        });
      }
    });
  }

  // ================= FLASH =================

  void _toggleFlash() async {
    if (!_torchReady) return;

    try {
      await scannerController.toggleTorch();
      setState(() => _torchOn = !_torchOn);
    } catch (_) {}
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF005C97),

      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("QR Patrol Scan"),
        centerTitle: true,
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: _toggleFlash,
        backgroundColor:
            _torchOn ? Colors.yellow : Colors.white24,
        child: Icon(
          _torchOn ? Icons.flash_on : Icons.flash_off,
          color: _torchOn ? Colors.black : Colors.white,
        ),
      ),

      body: _loading
          ? const Center(
              child:
                  CircularProgressIndicator(color: Colors.white))
          : Column(
              children: [
                const SizedBox(height: 20),

                // CAMERA
                SizedBox(
                  height: 200,
                  width: 200,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Stack(
                      children: [
                        MobileScanner(
                          controller: scannerController,
                          onDetect: _onScan,
                        ),

                        if (_overlayTimer > 0)
                          Positioned.fill(
                            child: Column(
                              mainAxisAlignment:
                                  MainAxisAlignment.end,
                              children: [
                                Text(
                                  "$_overlayTimer",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 36,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Padding(
                                  padding:
                                      const EdgeInsets.all(10),
                                  child: LinearProgressIndicator(
                                    value: _overlayTimer /
                                        _totalTime,
                                    backgroundColor:
                                        Colors.white24,
                                    valueColor:
                                        const AlwaysStoppedAnimation(
                                            Colors.yellow),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // LIST
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 15),
                    itemCount: _checkpoints.length,
                    itemBuilder: (_, i) {
                      final p = _checkpoints[i];

                      Color bg = Colors.white;
                      Color txt = Colors.black;

                      if (p['completed'] == true) {
                        bg = Colors.green.shade600;
                        txt = Colors.white;
                      } else if (p['waiting_done'] == true) {
                        bg = Colors.orange.shade600;
                        txt = Colors.white;
                      } else if (p['scanned_once'] == true) {
                        bg = Colors.yellow.shade600;
                        txt = Colors.white;
                      }

                      return Container(
                        margin:
                            const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius:
                              BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                p['qr_name'] ??
                                    "POINT ${i + 1}",
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: txt,
                                ),
                              ),
                            ),

                            if (p['timer'] > 0)
                              Text(
                                "WAIT ${p['timer']}s",
                                style: TextStyle(
                                    color: txt,
                                    fontWeight:
                                        FontWeight.bold),
                              )
                            else if (p['completed'] == true)
                              const Icon(Icons.check_circle,
                                  color: Colors.white)
                            else if (p['waiting_done'] == true)
                              const Icon(Icons.play_arrow,
                                  color: Colors.white)
                            else
                              Icon(
                                Icons.radio_button_unchecked,
                                color: Colors.grey.shade400,
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  // ================= DISPOSE =================

  @override
  void dispose() {
    _syncTimer?.cancel();
    scannerController.dispose();
    super.dispose();
  }
}
