// scan_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'round_utils.dart';

class ScanningPage extends StatefulWidget {
  final String guardName;
  final String campusCode;
  final bool isMaster;

  const ScanningPage({
    super.key,
    required this.guardName,
    required this.campusCode,
    required this.isMaster,
  });

  @override
  State<ScanningPage> createState() => _ScanningPageState();
}

class _ScanningPageState extends State<ScanningPage> with TickerProviderStateMixin {
  final MobileScannerController scannerController = MobileScannerController();

  List<Map<String, dynamic>> _checkpoints = [];

  bool _loading = true;
  bool _isProcessing = false;

  String? _activeQrId;

  int _overlayTimer = 0;
  int _totalTime = 0;

  bool _torchOn = false;
  bool _torchReady = false;

  late DateTime _currentRound;
  String _currentRoundLabel = '';
  DateTime? _currentWindowStart;
  DateTime? _currentWindowEnd;
  bool _scanAvailable = false;
  bool _showingCompleteDialog = false;

  Timer? _syncTimer;

  DateTime? _lastScanTime; // cooldown

  // ── Animation ──
  late AnimationController _scanLineCtrl;
  late Animation<double> _scanLineAnim;

  // ================= INIT =================

  @override
  void initState() {
    super.initState();

    _currentRound = _getRoundStart();

    final h = DateTime.now().hour;
    _torchOn = (h >= 18 || h < 6);

    // Scan line sweep animation
    _scanLineCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _scanLineAnim = CurvedAnimation(parent: _scanLineCtrl, curve: Curves.easeInOut);

    _initScanner();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestRequiredPermissions();
    });
    _fetchCheckpoints();

    _syncTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _fetchCheckpoints();
    });
  }

  // ================= SLOT =================

  DateTime _getRoundStart() {
    return getNearestPatrolRoundStart(DateTime.now());
  }

  bool _isValidTime() {
    final now = DateTime.now();

    final start = _currentRound;
    return isWithinPatrolScanWindow(now, start);
  }

  String _windowLabel() {
    if (_currentWindowStart == null || _currentWindowEnd == null) {
      return '';
    }
    return "${DateFormat('hh:mm a').format(_currentWindowStart!)} - ${DateFormat('hh:mm a').format(_currentWindowEnd!)}";
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
      final now = DateTime.now();
      final roundInfo = getCurrentPatrolRound(now);
      _currentRound = roundInfo['currentRoundTime'] as DateTime;
      _currentRoundLabel = roundInfo['currentRoundLabel'] as String;
      _currentWindowStart = roundInfo['scanWindowOpen'] as DateTime;
      _currentWindowEnd = roundInfo['scanWindowClose'] as DateTime;
      _scanAvailable = roundInfo['isActive'] as bool;
      final client = Supabase.instance.client;

      final qrData = await client
          .from('qr')
          .select()
          .eq('campus_code', widget.campusCode)
          .eq('status', 'active');

      final scanData = await client
          .from('scanning_details')
          .select('qr_id,status')
          .eq('campus_code', widget.campusCode)
          .eq('round_slot', _currentRound.toUtc().toIso8601String());

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
          
          // Find matching existing checkpoint in current state
          final existing = _checkpoints.cast<Map<String, dynamic>?>().firstWhere(
            (old) => old != null && _norm(old['qr_id']) == id,
            orElse: () => null,
          );

          final hasBeenScanned = existing != null &&
              ((existing['scanned_once'] == true) || (existing['waiting_done'] == true));

          return {
            ...e,
            'completed': success.contains(id),
            'scanned_once': hasBeenScanned
                ? (existing['scanned_once'] ?? false)
                : false,
            'waiting_done': hasBeenScanned
                ? (existing['waiting_done'] ?? false)
                : false,
            'timer': hasBeenScanned
                ? (existing['timer'] ?? 0)
                : 0,
            'start_time': existing != null ? existing['start_time'] : null,
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
    try {
      final res = await Supabase.instance.client
          .from('scanning_details')
          .select('id')
          .eq('campus_code', widget.campusCode)
          .eq('qr_id', qr)
          .eq('round_slot', _currentRound.toUtc().toIso8601String())
          .eq('status', 'SUCCESS')
          .maybeSingle();

      if (res != null) {
        debugPrint("ExistsSuccess true: ${res['id']}");
      }
      return res != null;
    } catch (e) {
      debugPrint("ExistsSuccess error: $e");
      return false;
    }
  }

  Future<bool> _isOnline() async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  Future<Position?> _getCurrentPosition() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 10),
      );
      return position;
    } catch (e) {
      debugPrint('High accuracy location failed, trying low accuracy: $e');
      try {
        final position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.low,
          timeLimit: const Duration(seconds: 5),
        );
        return position;
      } catch (e2) {
        debugPrint('Location fetch failed: $e2, using fallback');
        return null;
      }
    }
  }

  Future<void> _requestRequiredPermissions() async {
    final cameraGranted = await _requestPermission(
      Permission.camera,
      'Camera',
    );

    final locationGranted = await _requestPermission(
      Permission.locationWhenInUse,
      'Location',
    );

    final notificationGranted = await _requestPermission(
      Permission.notification,
      'Notifications',
    );

    if (!cameraGranted) {
      _msg('Camera permission required for scanning.', Colors.red);
    }

    if (!locationGranted) {
      _msg('Location permission required for scan upload.', Colors.red);
    }

    if (!notificationGranted) {
      _msg('Notification permission required for alerts.', Colors.orange);
    }
  }

  Future<bool> _requestPermission(
    Permission permission,
    String permissionName,
  ) async {
    var status = await permission.status;
    if (status.isGranted) return true;

    if (status.isDenied || status.isRestricted) {
      status = await permission.request();
    }

    if (status.isGranted) return true;

    if (status.isPermanentlyDenied) {
      _msg(
          '$permissionName permission blocked. Open app settings.', Colors.red);
    } else {
      _msg('$permissionName permission denied.', Colors.red);
    }

    return status.isGranted;
  }

  // ================= MESSAGE =================

  void _msg(String m, Color c) {
    HapticFeedback.vibrate();

    if (!mounted) return;

    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        backgroundColor: c,
        elevation: 8,
        content: Row(children: [
          Icon(
            c == Colors.green ? Icons.check_circle_rounded
              : c == Colors.orange ? Icons.warning_rounded
              : Icons.error_rounded,
            color: Colors.white, size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(m, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white))),
        ]),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // ================= AUTO LOGOUT =================

  void _checkAutoLogout() {
    if (_checkpoints.isEmpty) return;

    final done = _checkpoints.every((e) => e['completed'] == true);

    if (done) {
      if (!_showingCompleteDialog) {
        _showingCompleteDialog = true;
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            return AlertDialog(
              title: const Text("Scan Completed"),
              content: const Text(
                  "All checkpoints are complete. Returning to home..."),
            );
          },
        );
        Future.delayed(const Duration(seconds: 4), () {
          if (!mounted) return;
          Navigator.of(context).pop();
          Navigator.of(context).pop();
          _showingCompleteDialog = false;
        });
      }
    }
  }

  // ================= SCAN =================

  Future<void> _onScan(BarcodeCapture capture) async {
    // Cooldown (prevents spam)
    final now = DateTime.now();
    _currentRound = _getRoundStart();

    if (_lastScanTime != null && now.difference(_lastScanTime!).inSeconds < 2) {
      return;
    }

    _lastScanTime = now;

    if (_isProcessing) return;

    final raw = capture.barcodes.first.rawValue ?? '';
    final qrId = _norm(raw);

    if (qrId.isEmpty) return;

    final index = _checkpoints.indexWhere((p) => _norm(p['qr_id']) == qrId);

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

    final valid = _isValidTime();

    if (!valid) {
      _msg("OUTSIDE SCAN WINDOW", Colors.red);
      return;
    }

    // ---------- FIRST SCAN ----------
    if (p['scanned_once'] == true && p['waiting_done'] == false) {
      final remaining = p['timer'] ?? 0;
      _msg("WAIT ${remaining}s", Colors.orange);
      return;
    }

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
      if (!await _isOnline()) {
        _msg('NO INTERNET', Colors.red);
        return;
      }

      var pos = await _getCurrentPosition();
      if (pos == null) {
        _msg('CANNOT GET LOCATION - SCAN FAILED', Colors.red);
        return;
      }

      // Delete any previous status record (like MISSED) for this checkpoint and round slot to allow overwriting/updating
      await Supabase.instance.client
          .from('scanning_details')
          .delete()
          .eq('qr_id', p['qr_id'])
          .eq('round_slot', _currentRound.toUtc().toIso8601String());

      await Supabase.instance.client.from('scanning_details').insert({
        'guard_name': widget.guardName,
        'qr_id': p['qr_id'],
        'qr_name': p['qr_name'],
        'lat': pos.latitude,
        'log': pos.longitude,
        'campus_code': widget.campusCode,
        'scan_time': DateTime.now().toUtc().toIso8601String(),
        'round_slot': _currentRound.toUtc().toIso8601String(),
        'status': 'SUCCESS',
      });

      _activeQrId = null;
      _msg('SCAN UPLOADED', Colors.green);

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
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      } else {
        _isProcessing = false;
      }
    }
  }

  // ================= SAVE MISSED =================

  Future<void> _saveMissed(Map p) async {
    if (_isProcessing) return;

    setState(() => _isProcessing = true);

    try {
      if (!await _isOnline()) {
        _msg('NO INTERNET', Colors.red);
        return;
      }

      var pos = await _getCurrentPosition();
      if (pos == null) {
        _msg('CANNOT GET LOCATION - SCAN FAILED', Colors.red);
        return;
      }

      await Supabase.instance.client.from('scanning_details').insert({
        'guard_name': widget.guardName,
        'qr_id': p['qr_id'],
        'qr_name': p['qr_name'],
        'lat': pos.latitude,
        'log': pos.longitude,
        'campus_code': widget.campusCode,
        'scan_time': DateTime.now().toUtc().toIso8601String(),
        'round_slot': _currentRound.toUtc().toIso8601String(),
        'status': 'MISSED',
      });

      _fetchCheckpoints();
      _msg("MARKED MISSED", Colors.red);
    } catch (e) {
      debugPrint("Missed error: $e");
      _msg("UPLOAD FAILED", Colors.red);
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      } else {
        _isProcessing = false;
      }
    }
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

      final cp = _checkpoints[index];
      if (cp['start_time'] == null) {
        t.cancel();
        return;
      }

      final remain = cp['waiting_time'] -
          DateTime.now().difference(cp['start_time'] as DateTime).inSeconds;

      if (remain <= 0) {
        t.cancel();

        setState(() {
          cp['timer'] = 0;
          _overlayTimer = 0;
          cp['waiting_done'] = true;
        });

        HapticFeedback.vibrate();
      } else {
        setState(() {
          cp['timer'] = remain;
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
    const bg1 = Color(0xFF0D47A1);
    const bg2 = Color(0xFF001E62);
    const primary = Color(0xFF0A74DA);

    final scannedCount = _checkpoints.where((p) => p['completed'] == true).length;
    final totalCount = _checkpoints.length;
    final progress = totalCount > 0 ? scannedCount / totalCount : 0.0;

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: bg2,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        title: const Text("QR Patrol Scan",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Icon(
                _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                key: ValueKey(_torchOn),
                color: _torchOn ? Colors.yellow : Colors.white70,
              ),
            ),
            onPressed: _toggleFlash,
            tooltip: "Toggle Flashlight",
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [bg1, bg2]),
              ),
              child: const Center(child: CircularProgressIndicator(color: Colors.white)),
            )
          : Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [bg1, bg2]),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 10),

                    // ── Info Card ──────────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.09),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: Colors.white.withOpacity(0.15)),
                        ),
                        child: Row(children: [
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(
                              _currentRoundLabel.isEmpty ? 'Current Scan' : _currentRoundLabel,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                            const SizedBox(height: 4),
                            Text(_windowLabel(),
                              style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.6))),
                          ])),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: _scanAvailable
                                  ? const Color(0xFF00C853).withOpacity(0.2)
                                  : Colors.red.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _scanAvailable ? const Color(0xFF00C853) : Colors.red, width: 1),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(
                                _scanAvailable ? Icons.lock_open_rounded : Icons.lock_rounded,
                                size: 13,
                                color: _scanAvailable ? const Color(0xFF00C853) : Colors.redAccent,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _scanAvailable ? 'OPEN' : 'CLOSED',
                                style: TextStyle(
                                  fontSize: 11, fontWeight: FontWeight.bold,
                                  color: _scanAvailable ? const Color(0xFF00C853) : Colors.redAccent,
                                ),
                              ),
                            ]),
                          ),
                        ]),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // ── Camera Frame ───────────────────────────────────────
                    Center(
                      child: Container(
                        width: 220, height: 220,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(color: primary.withOpacity(0.35), blurRadius: 30, spreadRadius: 4),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Stack(
                            children: [
                              // Camera feed
                              MobileScanner(controller: scannerController, onDetect: _onScan),

                              // Scan line sweep
                              if (_overlayTimer == 0)
                                AnimatedBuilder(
                                  animation: _scanLineAnim,
                                  builder: (_, __) => Positioned(
                                    top: _scanLineAnim.value * 200,
                                    left: 0, right: 0,
                                    child: Container(
                                      height: 2,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(colors: [
                                          Colors.transparent,
                                          const Color(0xFF00C6FF).withOpacity(0.8),
                                          Colors.transparent,
                                        ]),
                                      ),
                                    ),
                                  ),
                                ),

                              // Countdown overlay
                              if (_overlayTimer > 0)
                                Positioned.fill(
                                  child: Container(
                                    color: Colors.black.withOpacity(0.65),
                                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                      SizedBox(
                                        width: 90, height: 90,
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            CircularProgressIndicator(
                                              value: _totalTime > 0 ? _overlayTimer / _totalTime : 0,
                                              strokeWidth: 6,
                                              backgroundColor: Colors.white12,
                                              valueColor: const AlwaysStoppedAnimation(Color(0xFFFFAB00)),
                                            ),
                                            Text("$_overlayTimer",
                                              style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      const Text("Hold position...",
                                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                                    ]),
                                  ),
                                ),

                              // Corner brackets
                              Positioned(top: 12, left: 12, child: _corner(topLeft: true)),
                              Positioned(top: 12, right: 12, child: _corner(topRight: true)),
                              Positioned(bottom: 12, left: 12, child: _corner(bottomLeft: true)),
                              Positioned(bottom: 12, right: 12, child: _corner(bottomRight: true)),
                            ],
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // ── Progress Bar ───────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 7,
                              backgroundColor: Colors.white12,
                              valueColor: const AlwaysStoppedAnimation(Color(0xFF00C853)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text("$scannedCount/$totalCount",
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                      ]),
                    ),

                    const SizedBox(height: 14),

                    // ── Checkpoint Grid ────────────────────────────────────
                    Expanded(
                      child: GridView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 1.05,
                        ),
                        itemCount: _checkpoints.length,
                        itemBuilder: (_, i) {
                          final p = _checkpoints[i];
                          final bool completed  = p['completed']   == true;
                          final bool waitingDone = p['waiting_done'] == true;
                          final bool scannedOnce = p['scanned_once'] == true;

                          Color  bg; Color txt; Widget icon; String label;
                          List<Color> grad;

                          if (completed) {
                            grad = [const Color(0xFF1B5E20), const Color(0xFF2E7D32)];
                            txt  = Colors.white;
                            icon = const Icon(Icons.check_circle_rounded, color: Colors.white, size: 26);
                            label = "Done";
                          } else if (waitingDone) {
                            grad = [const Color(0xFFE65100), const Color(0xFFEF6C00)];
                            txt  = Colors.white;
                            icon = const Icon(Icons.play_circle_fill, color: Colors.white, size: 26);
                            label = "Scan Now!";
                          } else if (scannedOnce) {
                            grad = [const Color(0xFFB71C1C), const Color(0xFFC62828)];
                            txt  = Colors.white;
                            icon = Text("${p['timer']}s",
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18));
                            label = "Waiting";
                          } else {
                            grad = [const Color(0xFF1A237E), const Color(0xFF283593)];
                            txt  = Colors.white60;
                            icon = Icon(Icons.qr_code_rounded, color: Colors.white38, size: 26);
                            label = "Pending";
                          }
                          bg = grad.first;

                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 350),
                            curve: Curves.easeInOut,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft, end: Alignment.bottomRight, colors: grad),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.white.withOpacity(completed ? 0.25 : 0.08), width: 1),
                              boxShadow: [
                                BoxShadow(
                                  color: (completed ? const Color(0xFF00C853) : bg).withOpacity(0.3),
                                  blurRadius: completed ? 12 : 4,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  Text(
                                    p['qr_name'] ?? "PT ${i + 1}",
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: txt),
                                  ),
                                  icon,
                                  Text(label,
                                    style: TextStyle(
                                      fontSize: 9, fontWeight: FontWeight.w600,
                                      color: txt.withOpacity(0.75), letterSpacing: 0.4)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _corner({bool topLeft=false, bool topRight=false, bool bottomLeft=false, bool bottomRight=false}) {
    return SizedBox(
      width: 22, height: 22,
      child: CustomPaint(
        painter: _CornerPainter(
          topLeft: topLeft, topRight: topRight,
          bottomLeft: bottomLeft, bottomRight: bottomRight,
        ),
      ),
    );
  }

  // ================= DISPOSE =================

  @override
  void dispose() {
    _syncTimer?.cancel();
    _scanLineCtrl.dispose();
    scannerController.dispose();
    super.dispose();
  }
}

// ── Corner bracket painter ──────────────────────────────────────────────────
class _CornerPainter extends CustomPainter {
  final bool topLeft, topRight, bottomLeft, bottomRight;
  _CornerPainter({this.topLeft=false, this.topRight=false, this.bottomLeft=false, this.bottomRight=false});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF00C6FF)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const len = 18.0;
    final w = size.width; final h = size.height;

    if (topLeft)     { canvas.drawLine(Offset(0,len), Offset.zero, paint); canvas.drawLine(Offset.zero, Offset(len,0), paint); }
    if (topRight)    { canvas.drawLine(Offset(w-len,0), Offset(w,0), paint); canvas.drawLine(Offset(w,0), Offset(w,len), paint); }
    if (bottomLeft)  { canvas.drawLine(Offset(0,h-len), Offset(0,h), paint); canvas.drawLine(Offset(0,h), Offset(len,h), paint); }
    if (bottomRight) { canvas.drawLine(Offset(w-len,h), Offset(w,h), paint); canvas.drawLine(Offset(w,h), Offset(w,h-len), paint); }
  }

  @override
  bool shouldRepaint(_) => false;
}
