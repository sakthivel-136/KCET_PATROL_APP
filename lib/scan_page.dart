import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  String _selectedLang = "EN";

  static const Map<String, Map<String, String>> _i10n = {
    'QR Patrol Scan': {'EN': 'QR Patrol Scan', 'TA': 'QR ரோந்து ஸ்கேன்'},
    'OPEN': {'EN': 'OPEN', 'TA': 'திறந்தது'},
    'CLOSED': {'EN': 'CLOSED', 'TA': 'மூடப்பட்டது'},
    'Done': {'EN': 'Done', 'TA': 'முடிந்தது'},
    'Scan Again': {'EN': 'Scan Again', 'TA': 'மீண்டும் ஸ்கேன் செய்'},
    'Wait...': {'EN': 'Wait...', 'TA': 'காத்திருக்கவும்...'},
    'Pending': {'EN': 'Pending', 'TA': 'நிலுவையில் உள்ளது'},
    'Checkpoint Scanned!': {'EN': 'Checkpoint Scanned!', 'TA': 'சோதனை புள்ளி ஸ்கேன் செய்யப்பட்டது!'},
  };

  String _t(String key) {
    return _i10n[key]?[_selectedLang] ?? key;
  }

  // ── Animations ──────────────────────────────────────────────────────────────
  late AnimationController _scanLineCtrl;
  late AnimationController _successCtrl;
  late AnimationController _bracketCtrl;
  late Animation<double> _scanLineAnim;
  late Animation<double> _successAnim;
  late Animation<double> _bracketAnim;
  String? _lastSuccessName;

  // ================= INIT =================

  @override
  void initState() {
    super.initState();
    _loadSavedLanguage();
    _currentRound = _getRoundStart();
    final h = DateTime.now().hour;
    _torchOn = (h >= 18 || h < 6);

    _scanLineCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _scanLineAnim = CurvedAnimation(parent: _scanLineCtrl, curve: Curves.easeInOut);

    _successCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _successAnim = CurvedAnimation(parent: _successCtrl, curve: Curves.easeOutBack);

    _bracketCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _bracketAnim = CurvedAnimation(parent: _bracketCtrl, curve: Curves.easeOutCubic);
    _bracketCtrl.forward();

    _initScanner();
    WidgetsBinding.instance.addPostFrameCallback((_) => _requestRequiredPermissions());
    _fetchCheckpoints();
    _syncTimer = Timer.periodic(const Duration(seconds: 20), (_) => _fetchCheckpoints());
  }

  Future<void> _loadSavedLanguage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lang = prefs.getString('user_lang') ?? 'EN';
      if (mounted) setState(() => _selectedLang = lang);
    } catch (_) {}
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
      _showSuccess(p['qr_name']?.toString() ?? 'Checkpoint Scanned!');

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

  Future<void> _toggleFlash() async {
    if (!_torchReady) return;
    try {
      await scannerController.toggleTorch();
      setState(() => _torchOn = !_torchOn);
    } catch (_) {}
  }

  // ================= SUCCESS BURST =================

  void _showSuccess(String name) {
    _lastSuccessName = name;
    _successCtrl.reset();
    _successCtrl.forward().then((_) {
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) _successCtrl.reverse();
      });
    });
  }

  // ================= DISPOSE =================

  @override
  void dispose() {
    _syncTimer?.cancel();
    _scanLineCtrl.dispose();
    _successCtrl.dispose();
    _bracketCtrl.dispose();
    scannerController.dispose();
    super.dispose();
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    final scanned = _checkpoints.where((p) => p['completed'] == true).length;
    final total   = _checkpoints.length;
    final prog    = total > 0 ? scanned / total : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFF070B1F),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            _currentRoundLabel.isEmpty ? _t('QR Patrol Scan') : _currentRoundLabel,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          Text(_windowLabel(), style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _scanAvailable
                  ? const Color(0xFF00E676).withOpacity(0.18)
                  : const Color(0xFFFF1744).withOpacity(0.18),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _scanAvailable ? const Color(0xFF00E676) : const Color(0xFFFF1744),
                width: 1,
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                _scanAvailable ? Icons.lock_open_rounded : Icons.lock_rounded,
                size: 12,
                color: _scanAvailable ? const Color(0xFF00E676) : const Color(0xFFFF1744),
              ),
              const SizedBox(width: 4),
              Text(
                _t(_scanAvailable ? 'OPEN' : 'CLOSED'),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: _scanAvailable ? const Color(0xFF00E676) : const Color(0xFFFF1744),
                ),
              ),
            ]),
          ),
          IconButton(
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Icon(
                _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                key: ValueKey(_torchOn),
                color: _torchOn ? Colors.yellow : Colors.white54,
                size: 22,
              ),
            ),
            onPressed: _toggleFlash,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF2979FF)))
          : Stack(
              children: [
                // Full-screen camera
                Positioned.fill(
                  child: MobileScanner(controller: scannerController, onDetect: _onScan),
                ),

                // Top gradient for AppBar readability
                Positioned(
                  top: 0, left: 0, right: 0, height: 140,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xCC000000), Colors.transparent],
                      ),
                    ),
                  ),
                ),

                // Sweep scan line
                if (_overlayTimer == 0)
                  AnimatedBuilder(
                    animation: _scanLineAnim,
                    builder: (_, __) {
                      final h = MediaQuery.of(context).size.height * 0.55;
                      return Positioned(
                        top: _scanLineAnim.value * h,
                        left: 0, right: 0,
                        child: Container(
                          height: 2,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(colors: [
                              Colors.transparent,
                              Color(0xFF00E5FF),
                              Colors.transparent,
                            ]),
                          ),
                        ),
                      );
                    },
                  ),

                // Animated corner brackets
                AnimatedBuilder(
                  animation: _bracketAnim,
                  builder: (_, __) {
                    final size = MediaQuery.of(context).size;
                    final cx = size.width / 2;
                    final cy = size.height * 0.28;
                    const boxW = 180.0;
                    const boxH = 180.0;
                    return CustomPaint(
                      size: size,
                      painter: _ScanFramePainter(
                        l: cx - boxW / 2, t: cy - boxH / 2,
                        r: cx + boxW / 2, b: cy + boxH / 2,
                        progress: _bracketAnim.value,
                      ),
                    );
                  },
                ),

                // Countdown ring overlay
                if (_overlayTimer > 0)
                  Center(
                    child: Container(
                      width: 140, height: 140,
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.75),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Stack(alignment: Alignment.center, children: [
                        CircularProgressIndicator(
                          value: _totalTime > 0 ? _overlayTimer / _totalTime : 0,
                          strokeWidth: 8,
                          backgroundColor: Colors.white12,
                          valueColor: const AlwaysStoppedAnimation(Color(0xFFFFAB00)),
                        ),
                        Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text("$_overlayTimer",
                            style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold)),
                          const Text("sec", style: TextStyle(color: Colors.white38, fontSize: 12)),
                        ]),
                      ]),
                    ),
                  ),

                // Success burst overlay
                AnimatedBuilder(
                  animation: _successAnim,
                  builder: (_, __) {
                    if (_successAnim.value == 0) return const SizedBox.shrink();
                    return Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          color: const Color(0xFF00E676).withOpacity(_successAnim.value * 0.22),
                          child: Center(
                            child: Opacity(
                              opacity: _successAnim.value,
                              child: Transform.scale(
                                scale: _successAnim.value,
                                child: Column(mainAxisSize: MainAxisSize.min, children: [
                                  Container(
                                    width: 90, height: 90,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(0xFF00E676).withOpacity(0.9),
                                      boxShadow: [BoxShadow(
                                        color: const Color(0xFF00E676).withOpacity(0.6),
                                        blurRadius: 40, spreadRadius: 10,
                                      )],
                                    ),
                                    child: const Icon(Icons.check_rounded, color: Colors.white, size: 50),
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _lastSuccessName ?? 'Scanned!',
                                    style: const TextStyle(
                                      color: Colors.white, fontSize: 18,
                                      fontWeight: FontWeight.bold, letterSpacing: 1,
                                    ),
                                  ),
                                ]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),

                // Draggable checkpoint panel
                DraggableScrollableSheet(
                  initialChildSize: 0.42,
                  minChildSize: 0.12,
                  maxChildSize: 0.75,
                  builder: (_, scrollCtrl) => Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0E27).withOpacity(0.97),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                      border: const Border(top: BorderSide(color: Colors.white10)),
                    ),
                    child: Column(children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 40, height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 8),

                      // Progress bar
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                value: prog,
                                minHeight: 6,
                                backgroundColor: Colors.white10,
                                valueColor: const AlwaysStoppedAnimation(Color(0xFF00E676)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            "$scanned / $total",
                            style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 10),

                      // Checkpoint grid
                      Expanded(
                        child: GridView.builder(
                          controller: scrollCtrl,
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 1.05,
                          ),
                          itemCount: _checkpoints.length,
                          itemBuilder: (_, i) {
                            final p         = _checkpoints[i];
                            final done      = p['completed']    == true;
                            final ready     = p['waiting_done'] == true;
                            final waiting   = p['scanned_once'] == true;
                            List<Color> grad; Widget icon; String lbl;
                            if (done) {
                              grad = [const Color(0xFF1B5E20), const Color(0xFF2E7D32)];
                              icon = const Icon(Icons.check_circle_rounded, color: Colors.white, size: 28);
                              lbl  = 'Done';
                            } else if (ready) {
                              grad = [const Color(0xFFE65100), const Color(0xFFEF6C00)];
                              icon = const Icon(Icons.play_circle_fill, color: Colors.white, size: 28);
                              lbl  = 'Scan Again';
                            } else if (waiting) {
                              grad = [const Color(0xFFB71C1C), const Color(0xFFC62828)];
                              icon = Text('${p['timer']}s',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20));
                              lbl  = 'Wait...';
                            } else {
                              grad = [const Color(0xFF1A237E), const Color(0xFF283593)];
                              icon = const Icon(Icons.qr_code_rounded, color: Colors.white38, size: 26);
                              lbl  = 'Pending';
                            }
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 400),
                              curve: Curves.easeOutBack,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: grad,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.white.withOpacity(done ? 0.25 : 0.06)),
                                boxShadow: done
                                    ? [BoxShadow(
                                        color: const Color(0xFF00E676).withOpacity(0.35),
                                        blurRadius: 14, offset: const Offset(0, 4),
                                      )]
                                    : null,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                  children: [
                                    Text(
                                      p['qr_name'] ?? 'PT ${i + 1}',
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11),
                                    ),
                                    icon,
                                    Text(_t(lbl), style: TextStyle(
                                      fontSize: 9, fontWeight: FontWeight.w600,
                                      color: Colors.white.withOpacity(0.6),
                                      letterSpacing: 0.3,
                                    )),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ]),
                  ),
                ),
              ],
            ),
    );
  }
}

// ─── Scan Frame Painter ───────────────────────────────────────────────────────
class _ScanFramePainter extends CustomPainter {
  final double l, t, r, b, progress;
  const _ScanFramePainter({
    required this.l, required this.t,
    required this.r, required this.b,
    required this.progress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Dim overlay with clear window
    final dimPaint = Paint()..color = Colors.black.withOpacity(0.45);
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(Rect.fromLTRB(l, t, r, b))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, dimPaint);

    // Cyan corner brackets
    final bp = Paint()
      ..color = const Color(0xFF00E5FF).withOpacity(progress)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const len = 26.0;
    // Top-left
    canvas.drawLine(Offset(l, t + len), Offset(l, t), bp);
    canvas.drawLine(Offset(l, t), Offset(l + len, t), bp);
    // Top-right
    canvas.drawLine(Offset(r - len, t), Offset(r, t), bp);
    canvas.drawLine(Offset(r, t), Offset(r, t + len), bp);
    // Bottom-left
    canvas.drawLine(Offset(l, b - len), Offset(l, b), bp);
    canvas.drawLine(Offset(l, b), Offset(l + len, b), bp);
    // Bottom-right
    canvas.drawLine(Offset(r - len, b), Offset(r, b), bp);
    canvas.drawLine(Offset(r, b), Offset(r, b - len), bp);
  }

  @override
  bool shouldRepaint(_ScanFramePainter old) => old.progress != progress;
}

