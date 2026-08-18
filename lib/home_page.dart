import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'dart:math' as math;
import 'round_utils.dart';
import 'scan_page.dart';

// ─── Theme Constants ────────────────────────────────────────────────────────
const _kPrimary   = Color(0xFF0A74DA);
const _kPrimaryDk = Color(0xFF003A8C);
const _kAccent    = Color(0xFF00C6FF);
const _kSurface   = Colors.white;
const _kBg1       = Color(0xFF0D47A1);
const _kBg2       = Color(0xFF001E62);

class HomePage extends StatefulWidget {
  final String guardName;
  final String campusCode;
  final bool isMaster;
  final bool canScan;
  const HomePage({
    super.key,
    required this.guardName,
    required this.campusCode,
    required this.isMaster,
    required this.canScan,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  String _campusName = "Loading...";
  String _selectedCampusCode = "";
  int _totalQrCount = 0;
  int _scannedCount = 0;
  bool _isLoadingStatus = true;
  String _currentRound = "Calculating...";
  String _nextRoundTime = "";
  List<Map<String, dynamic>> _campuses = [];
  List<Map<String, dynamic>> _roundSlots = [];
  String _patrolStatus = "In Progress";
  DateTime? _currentRoundStart;
  DateTime? _scanWindowOpen;
  DateTime? _scanWindowClose;

  bool _isRefreshing = false;
  Timer? _refreshDebouncer;

  // ── Animation controllers ──────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late AnimationController _fadeCtrl;
  late AnimationController _progressCtrl;
  late Animation<double> _pulseAnim;
  late Animation<double> _fadeAnim;
  late Animation<double> _progressAnim;

  double _targetProgress = 0;

  @override
  void initState() {
    super.initState();
    _selectedCampusCode = widget.campusCode == "ADMIN" ? "KCET01" : widget.campusCode;

    // Pulse (scan button breathing)
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    // Fade-in for page
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _fadeAnim  = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();

    // Animated progress bar
    _progressCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _progressAnim = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _progressCtrl, curve: Curves.easeInOut),
    );

    _fetchInitialData();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _fadeCtrl.dispose();
    _progressCtrl.dispose();
    _refreshDebouncer?.cancel();
    super.dispose();
  }

  void _animateProgress(double newTarget) {
    final oldTarget = _targetProgress;
    _targetProgress = newTarget;
    _progressAnim = Tween<double>(begin: oldTarget, end: newTarget).animate(
      CurvedAnimation(parent: _progressCtrl, curve: Curves.easeInOut),
    );
    _progressCtrl
      ..reset()
      ..forward();
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _fetchInitialData() async {
    try {
      await Future.wait([
        _fetchCampuses().timeout(const Duration(seconds: 10), onTimeout: () {}),
        _fetchCampusName().timeout(const Duration(seconds: 10), onTimeout: () {}),
        _refreshPatrolStatus().timeout(const Duration(seconds: 10), onTimeout: () {}),
      ], eagerError: false);
    } catch (e) {
      debugPrint('Initial data fetch error: $e');
    }
    _updateRoundInfo();
    Timer.periodic(const Duration(minutes: 1), (t) { if (mounted) _updateRoundInfo(); });
  }

  Future<void> _fetchCampuses() async {
    try {
      final data = await Supabase.instance.client.from('campuses').select('campus_code, campus_name');
      if (mounted) setState(() => _campuses = List<Map<String, dynamic>>.from(data));
    } catch (e) { debugPrint("Error fetching campuses: $e"); }
  }

  Future<void> _fetchCampusName() async {
    try {
      if (_selectedCampusCode == "ADMIN") {
        if (mounted) setState(() => _campusName = "Administrator");
        return;
      }
      final data = await Supabase.instance.client
          .from('campuses').select('campus_name')
          .eq('campus_code', _selectedCampusCode).single();
      if (mounted) setState(() => _campusName = data['campus_name']);
    } catch (e) {
      if (mounted) setState(() => _campusName = "Unknown Campus");
    }
  }

  Map<String, dynamic> _getCurrentRoundSlot() => getCurrentPatrolRound(DateTime.now());

  void _updateRoundInfo() {
    final roundInfo = _getCurrentRoundSlot();
    final currentSlot = roundInfo['current'] as PatrolRound;
    final nextSlot    = roundInfo['next']    as PatrolRound;
    final roundTime   = roundInfo['currentRoundTime'] as DateTime;
    if (mounted) {
      setState(() {
        _currentRound    = "Round ${currentSlot.round}";
        _nextRoundTime   = "Next: ${nextSlot.label}";
        _currentRoundStart = roundTime;
        _scanWindowOpen  = roundInfo['scanWindowOpen']  as DateTime;
        _scanWindowClose = roundInfo['scanWindowClose'] as DateTime;
      });
    }
  }

  bool _isWithinScanWindow() {
    final now = DateTime.now();
    if (_scanWindowOpen == null || _scanWindowClose == null) return false;
    return !now.isBefore(_scanWindowOpen!) && now.isBefore(_scanWindowClose!);
  }

  bool _isSuccessStatus(String? s) {
    if (s == null) return false;
    final l = s.toLowerCase();
    return l == 'success' || l == 'complete' || l == 'done' || l == 'ok';
  }

  Future<void> _refreshPatrolStatus() async {
    if (_isRefreshing) return;
    _isRefreshing = true;
    if (!mounted) { _isRefreshing = false; return; }
    setState(() => _isLoadingStatus = true);

    final client  = Supabase.instance.client;
    final now     = DateTime.now();
    final info    = _getCurrentRoundSlot();
    final roundStart = info['currentRoundTime'] as DateTime;
    final roundEnd   = info['scanWindowClose']  as DateTime;
    final windowClosed = now.isAfter(roundEnd);

    try {
      final totalRes = await client.from('qr').select('qr_id')
          .eq('campus_code', _selectedCampusCode).eq('status', 'active');
      final scannedRes = await client.from('scanning_details').select('qr_id, status')
          .eq('campus_code', _selectedCampusCode)
          .eq('round_slot', roundStart.toUtc().toIso8601String());

      final uniqueScans = <String>{};
      for (var s in scannedRes) {
        if (_isSuccessStatus(s['status'])) uniqueScans.add(s['qr_id'].toString());
      }

      String status = "In Progress";
      if (uniqueScans.length >= totalRes.length && totalRes.length > 0) {
        status = "Success";
      } else if (windowClosed) {
        status = "Missed";
      }

      if (mounted) {
        final newProgress = totalRes.length > 0 ? uniqueScans.length / totalRes.length : 0.0;
        setState(() {
          _totalQrCount    = totalRes.length;
          _scannedCount    = uniqueScans.length;
          _patrolStatus    = status;
          _isLoadingStatus = false;
          _currentRoundStart = roundStart;
        });
        _animateProgress(newProgress);
      }
    } catch (e) {
      debugPrint("Error in _refreshPatrolStatus: $e");
      if (mounted) setState(() => _isLoadingStatus = false);
    } finally {
      _isRefreshing = false;
    }
  }

  // ── Round Report ─────────────────────────────────────────────────────────

  Future<void> _generateRoundSlots() async {
    setState(() => _isLoadingStatus = true);
    try {
      final now    = DateTime.now();
      final client = Supabase.instance.client;
      final rounds = buildPatrolRounds(now);
      final currentInfo  = getCurrentPatrolRound(now);
      final currentRound = currentInfo['current'] as PatrolRound;
      final currentIndex = rounds.indexWhere((r) => r.time == currentRound.time);

      final qrData = await client.from('qr').select('qr_id')
          .eq('campus_code', _selectedCampusCode).eq('status', 'active');
      final int totalQrCount = qrData.length;

      List<Map<String, dynamic>> slots = [];
      if (totalQrCount == 0) {
        for (var r in rounds) {
          slots.add({'time': r.time, 'label': r.label, 'round': 'Round ${r.round}', 'status': 'no_qr'});
        }
      } else {
        for (var i = 0; i < rounds.length; i++) {
          final round    = rounds[i];
          final slotTime = round.time;
          String status;
          List<dynamic> scannedData = [];

          if (i < currentIndex) {
            scannedData = await client.from('scanning_details').select('qr_id, status, guard_name')
                .eq('campus_code', _selectedCampusCode)
                .eq('round_slot', slotTime.toUtc().toIso8601String());
            final seenQrIds = <String>{};
            for (var scan in scannedData) {
              if (_isSuccessStatus(scan['status'])) seenQrIds.add(scan['qr_id'].toString());
            }
            status = seenQrIds.length >= totalQrCount ? 'success' : 'missed';
          } else if (i == currentIndex) {
            status = 'current';
          } else {
            status = 'future';
          }

          slots.add({
            'time':   slotTime,
            'label':  round.label,
            'round':  'Round ${round.round}',
            'status': status,
            'guard_name': status == 'success'
                ? (scannedData.isNotEmpty && scannedData.first['guard_name'] != null)
                    ? scannedData.first['guard_name'] : "Completed"
                : (status == 'missed')
                    ? (scannedData.isNotEmpty && scannedData.first['guard_name'] != null)
                        ? scannedData.first['guard_name'] : "No guard"
                    : (status == 'current') ? "In progress" : "Not started",
          });
        }
      }

      if (mounted) setState(() { _roundSlots = slots; _isLoadingStatus = false; });
    } catch (e) {
      debugPrint("Error generating round slots: $e");
      if (mounted) setState(() => _isLoadingStatus = false);
    }
  }

  void _showRoundDetails(Map<String, dynamic> slot) {
    final status = slot['status'] as String;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(slot['round'], style: const TextStyle(fontWeight: FontWeight.bold)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _detailRow(Icons.access_time, "Time", slot['label']),
          _detailRow(Icons.flag, "Status", status.toUpperCase()),
          _detailRow(Icons.person, "Guard", slot['guard_name'] ?? '—'),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close"))],
      ),
    );
  }

  Widget _detailRow(IconData icon, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [
      Icon(icon, size: 18, color: _kPrimary),
      const SizedBox(width: 8),
      Text("$label: ", style: const TextStyle(fontWeight: FontWeight.w600)),
      Expanded(child: Text(value, style: const TextStyle(color: Colors.black54))),
    ]),
  );

  void _showRoundReportDialog() {
    _generateRoundSlots().then((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: _kPrimary.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.assessment, color: _kPrimary),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text("Patrol Report — $_campusName",
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ]),
              const Divider(height: 20),
              SizedBox(
                height: 380,
                child: _isLoadingStatus
                  ? const Center(child: CircularProgressIndicator())
                  : _roundSlots.isEmpty
                    ? const Center(child: Text("No rounds available"))
                    : ListView.separated(
                        itemCount: _roundSlots.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, index) {
                          final slot = _roundSlots[index];
                          final status = slot['status'] as String;
                          Color badge; IconData badgeIcon; String badgeText;
                          switch (status) {
                            case 'success': badge = Colors.green; badgeIcon = Icons.check_circle; badgeText = 'Done'; break;
                            case 'missed':  badge = Colors.red;   badgeIcon = Icons.cancel;       badgeText = 'Missed'; break;
                            case 'current': badge = _kPrimary;   badgeIcon = Icons.play_circle;  badgeText = 'Active'; break;
                            case 'no_qr':   badge = Colors.grey; badgeIcon = Icons.remove_circle; badgeText = 'No QR'; break;
                            default:        badge = Colors.grey.shade400; badgeIcon = Icons.schedule; badgeText = 'Future';
                          }
                          return GestureDetector(
                            onTap: () => _showRoundDetails(slot),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: badge.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: badge.withOpacity(0.25)),
                              ),
                              child: Row(children: [
                                Icon(badgeIcon, color: badge, size: 22),
                                const SizedBox(width: 12),
                                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(slot['round'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                                  Text(slot['label'], style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                                ])),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(color: badge.withOpacity(0.15), borderRadius: BorderRadius.circular(20)),
                                  child: Text(badgeText, style: TextStyle(color: badge, fontWeight: FontWeight.bold, fontSize: 11)),
                                ),
                              ]),
                            ),
                          );
                        },
                      ),
              ),
            ]),
          ),
        ),
      );
    });
  }

  void _showCampusSelectionDialog() {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text("Select Campus", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ..._campuses.map((c) => ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              tileColor: _selectedCampusCode == c['campus_code'] ? _kPrimary.withOpacity(0.08) : null,
              leading: CircleAvatar(
                backgroundColor: _kPrimary.withOpacity(0.1),
                child: const Icon(Icons.location_city, color: _kPrimary, size: 20),
              ),
              title: Text(c['campus_name'], style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text("Code: ${c['campus_code']}", style: const TextStyle(fontSize: 12)),
              trailing: _selectedCampusCode == c['campus_code']
                  ? const Icon(Icons.check_circle, color: _kPrimary) : null,
              onTap: () {
                setState(() {
                  _selectedCampusCode = c['campus_code'];
                  _campusName = c['campus_name'];
                  _totalQrCount = 0; _scannedCount = 0; _patrolStatus = "In Progress";
                });
                Navigator.pop(context);
                _refreshPatrolStatus();
              },
            )).toList(),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          ]),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isAvailable = _isWithinScanWindow() || _totalQrCount == 0;

    Color statusColor;
    IconData statusIcon;
    switch (_patrolStatus) {
      case "Success": statusColor = const Color(0xFF00C853); statusIcon = Icons.check_circle; break;
      case "Missed":  statusColor = const Color(0xFFFF1744); statusIcon = Icons.cancel; break;
      default:        statusColor = const Color(0xFFFFAB00); statusIcon = Icons.timelapse;
    }

    String scanWindowStatus = "";
    if (_scanWindowOpen != null && _scanWindowClose != null) {
      final now = DateTime.now();
      if (now.isBefore(_scanWindowOpen!)) {
        scanWindowStatus = "Opens ${DateFormat('hh:mm a').format(_scanWindowOpen!)}";
      } else if (now.isAfter(_scanWindowClose!)) {
        scanWindowStatus = "Closed ${DateFormat('hh:mm a').format(_scanWindowClose!)}";
      } else {
        scanWindowStatus = "Closes ${DateFormat('hh:mm a').format(_scanWindowClose!)}";
      }
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        title: const Text("Security Rounds",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
        automaticallyImplyLeading: false,
        centerTitle: true,
        actions: [
          if (widget.isMaster)
            _appBarBtn(Icons.assessment_rounded, _showRoundReportDialog),
          _appBarBtn(Icons.refresh_rounded, () {
            _refreshDebouncer?.cancel();
            _refreshDebouncer = Timer(const Duration(milliseconds: 500), () {
              HapticFeedback.lightImpact();
              _refreshPatrolStatus();
            });
          }),
          _appBarBtn(Icons.logout_rounded, () => Navigator.pushReplacementNamed(context, '/')),
        ],
      ),
      body: FadeTransition(
        opacity: _fadeAnim,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_kBg1, _kBg2],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                children: [
                  const SizedBox(height: 4),

                  // ── Header Card ──────────────────────────────────────────
                  _glassCard(
                    child: Row(children: [
                      GestureDetector(
                        onTap: widget.isMaster ? _showCampusSelectionDialog : null,
                        child: Container(
                          width: 48, height: 48,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [_kPrimary, _kAccent],
                              begin: Alignment.topLeft, end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.shield_rounded, color: Colors.white, size: 26),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_campusName,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text("Guard: ${widget.guardName}",
                          style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.65))),
                      ])),
                      if (widget.isMaster) ...[
                        _chipBadge("ADMIN", Colors.purple, Icons.admin_panel_settings),
                        IconButton(
                          icon: const Icon(Icons.group_rounded, color: Colors.white70),
                          onPressed: _showShiftManagementDialog,
                          tooltip: "Manage Shifts",
                        ),
                      ] else if (scanWindowStatus.isNotEmpty)
                        _chipBadge(
                          scanWindowStatus,
                          _isWithinScanWindow() ? const Color(0xFF00C853) : Colors.orange,
                          _isWithinScanWindow() ? Icons.lock_open : Icons.lock_clock,
                        ),
                    ]),
                  ),

                  const SizedBox(height: 14),

                  // ── Clock Card ───────────────────────────────────────────
                  _glassCard(
                    child: Column(children: [
                      StreamBuilder(
                        stream: Stream.periodic(const Duration(seconds: 1)),
                        builder: (_, __) => Text(
                          DateFormat('hh:mm:ss a').format(DateTime.now()),
                          style: const TextStyle(
                            fontSize: 38, fontWeight: FontWeight.w200,
                            letterSpacing: 3, color: Colors.white,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [_kPrimary.withOpacity(0.6), _kAccent.withOpacity(0.4)]),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Text(_currentRound,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                        ),
                      ]),
                      const SizedBox(height: 8),
                      if (_scanWindowOpen != null && _scanWindowClose != null)
                        Text(
                          "${DateFormat('hh:mm a').format(_scanWindowOpen!)}  →  ${DateFormat('hh:mm a').format(_scanWindowClose!)}",
                          style: TextStyle(fontSize: 13, color: Colors.white.withOpacity(0.7)),
                        ),
                      const SizedBox(height: 4),
                      Text(_nextRoundTime,
                        style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.45))),
                    ]),
                  ),

                  const SizedBox(height: 14),

                  // ── Progress Card ────────────────────────────────────────
                  _glassCard(
                    child: Column(children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text("Current Patrol",
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
                        _isLoadingStatus
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Row(children: [
                              Icon(statusIcon, color: statusColor, size: 14),
                              const SizedBox(width: 4),
                              Text(_patrolStatus,
                                style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 12)),
                            ]),
                      ]),
                      const SizedBox(height: 14),
                      if (!_isLoadingStatus) ...[
                        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text("$_scannedCount",
                            style: const TextStyle(fontSize: 42, fontWeight: FontWeight.bold, color: Colors.white, height: 1)),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6, left: 4),
                            child: Text("/$_totalQrCount scans",
                              style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 14)),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        AnimatedBuilder(
                          animation: _progressAnim,
                          builder: (_, __) => Column(children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: LinearProgressIndicator(
                                value: _progressAnim.value,
                                minHeight: 8,
                                backgroundColor: Colors.white12,
                                valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                "${(_progressAnim.value * 100).toInt()}%",
                                style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ]),
                        ),
                      ] else
                        const Center(child: Padding(padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(color: Colors.white70))),
                    ]),
                  ),

                  const SizedBox(height: 32),

                  // ── Scan Button ──────────────────────────────────────────
                  GestureDetector(
                    onTap: () async {
                      HapticFeedback.mediumImpact();
                      if (isAvailable) {
                        await Navigator.push(context, _slideRoute(ScanningPage(
                          guardName: widget.guardName,
                          campusCode: _selectedCampusCode,
                          isMaster: widget.isMaster,
                        )));
                        _refreshDebouncer?.cancel();
                        _refreshDebouncer = Timer(const Duration(milliseconds: 500), _refreshPatrolStatus);
                      } else {
                        HapticFeedback.heavyImpact();
                        ScaffoldMessenger.of(context)
                          ..clearSnackBars()
                          ..showSnackBar(SnackBar(
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            backgroundColor: const Color(0xFFD32F2F),
                            content: Row(children: [
                              const Icon(Icons.lock_clock, color: Colors.white),
                              const SizedBox(width: 10),
                              Expanded(child: Text(
                                widget.isMaster ? "No QR codes to scan." : "SCAN WINDOW $scanWindowStatus",
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                              )),
                            ]),
                            duration: const Duration(seconds: 3),
                          ));
                      }
                    },
                    child: isAvailable
                      ? ScaleTransition(
                          scale: _pulseAnim,
                          child: _buildScanBtn(isAvailable),
                        )
                      : _buildScanBtn(isAvailable),
                  ),

                  const SizedBox(height: 14),

                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 300),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isAvailable ? Colors.white : Colors.white38,
                      letterSpacing: 0.5,
                    ),
                    child: Text(isAvailable ? "Tap to Scan QR Codes" : "Scanning Not Available"),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScanBtn(bool available) {
    return Container(
      width: 130, height: 130,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: available
            ? [const Color(0xFF1E88E5), const Color(0xFF00C6FF)]
            : [const Color(0xFF424242), const Color(0xFF616161)],
        ),
        boxShadow: [
          BoxShadow(
            color: (available ? _kPrimary : Colors.black).withOpacity(0.45),
            blurRadius: 28, spreadRadius: 2, offset: const Offset(0, 8),
          ),
          if (available)
            BoxShadow(
              color: _kAccent.withOpacity(0.25),
              blurRadius: 50, spreadRadius: 5,
            ),
        ],
      ),
      child: Icon(
        available ? Icons.qr_code_scanner_rounded : Icons.lock_rounded,
        size: 58, color: Colors.white,
      ),
    );
  }

  Widget _glassCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 20, offset: const Offset(0, 6)),
        ],
      ),
      child: child,
    );
  }

  Widget _appBarBtn(IconData icon, VoidCallback onTap) => IconButton(
    icon: Icon(icon, color: Colors.white),
    onPressed: onTap,
    splashRadius: 22,
  );

  Widget _chipBadge(String label, Color color, IconData icon) => Container(
    margin: const EdgeInsets.only(right: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withOpacity(0.2),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.5)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 11, color: color),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    ]),
  );

  PageRoute _slideRoute(Widget page) => PageRouteBuilder(
    pageBuilder: (_, anim, __) => page,
    transitionsBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
    transitionDuration: const Duration(milliseconds: 350),
  );

  // ── Shift Management ───────────────────────────────────────────────────────

  Future<void> _showShiftManagementDialog() async {
    final client = Supabase.instance.client;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const AlertDialog(
      content: Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Text("Loading...")]),
    ));
    try {
      final usersRes  = await client.from('security_users').select('security_id, security_name, role').eq('role', 'Guard');
      final shiftsRes = await client.from('shifts').select('shift_id, shift_name, start_time, end_time');
      final allocsRes = await client.from('shift_allocations').select('security_id, shift_id');
      if (!mounted) return;
      Navigator.of(context).pop();

      final guards = List<Map<String, dynamic>>.from(usersRes);
      final shifts = List<Map<String, dynamic>>.from(shiftsRes);
      final allocs = List<Map<String, dynamic>>.from(allocsRes);

      showDialog(
        context: context,
        builder: (_) => StatefulBuilder(builder: (ctx, setDlg) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(children: [
            Icon(Icons.manage_accounts, color: _kPrimary),
            SizedBox(width: 8),
            Text("Guard Shifts", style: TextStyle(fontSize: 17)),
          ]),
          content: SizedBox(width: double.maxFinite, child: ListView.builder(
            shrinkWrap: true, itemCount: guards.length,
            itemBuilder: (_, i) {
              final guard = guards[i];
              final gId = guard['security_id'];
              final assigned = allocs.where((a) => a['security_id'] == gId)
                  .map((a) => a['shift_id'].toString()).toSet();
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      CircleAvatar(radius: 18, backgroundColor: _kPrimary.withOpacity(0.1),
                        child: const Icon(Icons.person, color: _kPrimary, size: 18)),
                      const SizedBox(width: 10),
                      Expanded(child: Text(guard['security_name'] ?? 'Guard',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: assigned.isEmpty ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(assigned.isEmpty ? "No shift" : "${assigned.length} shift(s)",
                          style: TextStyle(color: assigned.isEmpty ? Colors.red : Colors.green, fontSize: 11, fontWeight: FontWeight.bold)),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Wrap(spacing: 6, runSpacing: 4,
                      children: shifts.map((s) {
                        final sId = s['shift_id'].toString();
                        final checked = assigned.contains(sId);
                        return FilterChip(
                          label: Text("${s['shift_name']} (${s['start_time']}–${s['end_time']})", style: const TextStyle(fontSize: 11)),
                          selected: checked,
                          selectedColor: _kPrimary.withOpacity(0.15),
                          checkmarkColor: _kPrimary,
                          onSelected: (val) async {
                            final updated = Set<String>.from(assigned);
                            val ? updated.add(sId) : updated.remove(sId);
                            await _editGuardShifts(gId, updated.toList());
                            allocs.removeWhere((a) => a['security_id'] == gId);
                            for (var id in updated) allocs.add({'security_id': gId, 'shift_id': id});
                            setDlg(() {});
                          },
                        );
                      }).toList(),
                    ),
                  ]),
                ),
              );
            },
          )),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Done"))],
        )),
      );
    } catch (e) {
      if (mounted) { Navigator.of(context).pop(); }
    }
  }

  Future<void> _editGuardShifts(String securityId, List<String> shiftIds) async {
    final client = Supabase.instance.client;
    try {
      await client.from('shift_allocations').delete().eq('security_id', securityId);
      if (shiftIds.isNotEmpty) {
        await client.from('shift_allocations').insert(shiftIds.map((sId) => {
          'security_id': securityId, 'shift_id': sId, 'allocation_date': '2099-12-31',
        }).toList());
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Shifts updated!"), backgroundColor: Colors.green, duration: Duration(seconds: 1)));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed: $e"), backgroundColor: Colors.red));
    }
  }
}