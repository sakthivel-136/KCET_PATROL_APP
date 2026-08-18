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

class _ScanningPageState extends State<ScanningPage> {
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

  // ================= INIT =================

  @override
  void initState() {
    super.initState();

    _currentRound = _getRoundStart();

    final h = DateTime.now().hour;
    _torchOn = (h >= 18 || h < 6);

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
          final sQr = _norm(e['qr_id']);
          final sPrefix = sQr.contains(':') ? sQr.split(':').first : sQr;
          success.add(sPrefix);
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
      final prefix = qr.contains(':') ? qr.split(':').first : qr;
      final res = await Supabase.instance.client
          .from('scanning_details')
          .select('id')
          .eq('campus_code', widget.campusCode)
          .or('qr_id.eq.$qr,qr_id.eq.$prefix')
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
        backgroundColor: c,
        content: Text(
          m,
          style:
              const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
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

    // The backend uses cryptographically signed QR codes (e.g., "1:a8b7c6d59f32e1").
    // We match checkpoints by extracting the prefix before the colon (the integer ID).
    final matchedId = qrId.contains(':') ? qrId.split(':').first : qrId;

    final index = _checkpoints.indexWhere((p) => _norm(p['qr_id']) == matchedId);

    if (index == -1) {
      _msg("UNKNOWN QR", Colors.orange);
      return;
    }

    final p = _checkpoints[index];
    final matchedPrefix = _norm(p['qr_id']);

    // Already finished
    if (p['completed'] == true) {
      _msg("ALREADY SCANNED", Colors.green);
      return;
    }

    // One at a time lock
    if (_activeQrId != null && _activeQrId != matchedPrefix) {
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

      // Lock current checkpoint using the prefix/ID
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

      await _saveSuccess(p, qrId);
    }
  }

  // ================= SAVE SUCCESS =================

  Future<void> _saveSuccess(Map p, String rawQrId) async {
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

      // Delete any previous status record (like MISSED) for this checkpoint to allow overwriting/updating
      final prefix = rawQrId.contains(':') ? rawQrId.split(':').first : rawQrId;
      await Supabase.instance.client
          .from('scanning_details')
          .delete()
          .eq('campus_code', widget.campusCode)
          .or('qr_id.eq.$rawQrId,qr_id.eq.$prefix')
          .eq('round_slot', _currentRound.toUtc().toIso8601String());

      await Supabase.instance.client.from('scanning_details').insert({
        'guard_name': widget.guardName,
        'qr_id': rawQrId,
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
        backgroundColor: _torchOn ? Colors.yellow : Colors.white24,
        child: Icon(
          _torchOn ? Icons.flash_on : Icons.flash_off,
          color: _torchOn ? Colors.black : Colors.white,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : Column(
              children: [
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 6,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _currentRoundLabel.isEmpty
                              ? 'Current Scan'
                              : _currentRoundLabel,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF005C97),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _windowLabel(),
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _scanAvailable
                              ? 'SCAN WINDOW OPEN'
                              : 'WAITING FOR SCAN WINDOW',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: _scanAvailable ? Colors.green : Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

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
                            child: Container(
                              color: Colors.black.withOpacity(0.5),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    "$_overlayTimer",
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 48,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 20),
                                    child: LinearProgressIndicator(
                                      value: _overlayTimer / _totalTime,
                                      backgroundColor: Colors.white24,
                                      valueColor: const AlwaysStoppedAnimation(
                                          Colors.yellow),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 20),

                // GRID
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 1.05,
                    ),
                    itemCount: _checkpoints.length,
                    itemBuilder: (_, i) {
                      final p = _checkpoints[i];
                      final bool completed = p['completed'] == true;
                      final bool waitingDone = p['waiting_done'] == true;
                      final bool scannedOnce = p['scanned_once'] == true;
                      
                      Color bg;
                      Color txt;
                      Widget icon;
                      String statusText;

                      if (completed) {
                        bg = const Color(0xFF2E7D32); // Deep premium green
                        txt = Colors.white;
                        icon = const Icon(Icons.check_circle, color: Colors.white, size: 24);
                        statusText = "Done";
                      } else if (waitingDone) {
                        bg = const Color(0xFFEF6C00); // Darker amber
                        txt = Colors.white;
                        icon = const Icon(Icons.play_circle_fill, color: Colors.white, size: 24);
                        statusText = "Ready";
                      } else if (scannedOnce) {
                        bg = const Color(0xFFC62828); // Deep red
                        txt = Colors.white;
                        icon = Text(
                          "${p['timer']}s",
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                        );
                        statusText = "Waiting";
                      } else {
                        bg = const Color(0xFF1E293B); // Dark slate grey for battery saving
                        txt = Colors.white70;
                        icon = Icon(Icons.radio_button_unchecked, color: Colors.grey.shade500, size: 24);
                        statusText = "Pending";
                      }

                      return Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white12,
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            )
                          ],
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              p['qr_name'] ?? "POINT ${i + 1}",
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: txt,
                              ),
                            ),
                            icon,
                            Text(
                              statusText,
                              style: TextStyle(
                                fontSize: 10,
                                color: txt.withOpacity(0.8),
                                fontWeight: FontWeight.w500,
                              ),
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
