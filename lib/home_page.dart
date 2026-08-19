import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:math' as math;
import 'round_utils.dart';
import 'scan_page.dart';

// ─── Palette ─────────────────────────────────────────────────────────────────
const _kBg1    = Color(0xFF070B1F);
const _kBg2    = Color(0xFF0D1B4B);
const _kCard   = Color(0xFF111836);
const _kAccent = Color(0xFF2979FF);
const _kCyan   = Color(0xFF00E5FF);
const _kGreen  = Color(0xFF00E676);
const _kOrange = Color(0xFFFFAB00);
const _kRed    = Color(0xFFFF1744);

class HomePage extends StatefulWidget {
  final String guardName;
  final String campusCode;
  final bool isMaster;
  final bool canScan;
  const HomePage({super.key, required this.guardName, required this.campusCode,
      required this.isMaster, required this.canScan});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  // ── Data ──────────────────────────────────────────────────────────────────
  String _campusName = "Loading...";
  String _selectedCampusCode = "";
  int    _totalQrCount  = 0;
  int    _scannedCount  = 0;
  bool   _isLoadingStatus = true;
  String _currentRound  = "Calculating...";
  String _nextRoundTime = "";
  List<Map<String,dynamic>> _campuses   = [];
  List<Map<String,dynamic>> _roundSlots = [];
  String    _patrolStatus    = "In Progress";
  DateTime? _currentRoundStart;
  DateTime? _scanWindowOpen;
  DateTime? _scanWindowClose;
  bool _isRefreshing = false;
  Timer? _refreshDebouncer;
  String _selectedLang = "EN"; // 'EN' or 'TA'

  // ── Translations ─────────────────────────────────────────────────────────────
  static const Map<String, Map<String, String>> _i10n = {
    'Security Rounds': {'EN': 'Security Rounds', 'TA': 'பாதுகாப்பு சுற்றுகள்'},
    'Select Campus': {'EN': 'Select Campus', 'TA': 'கேம்பஸ் தேர்வு செய்'},
    'Shifts': {'EN': 'Shifts', 'TA': 'ஷிப்டுகள்'},
    'Total QR': {'EN': 'Total QR', 'TA': 'மொத்த QR'},
    'Scanned': {'EN': 'Scanned', 'TA': 'ஸ்கேன் செய்யப்பட்டது'},
    'Left': {'EN': 'Left', 'TA': 'மீதமுள்ளது'},
    'Patrol Progress': {'EN': 'Patrol Progress', 'TA': 'ரோந்து முன்னேற்றம்'},
    'checkpoints': {'EN': 'checkpoints', 'TA': 'சோதனை புள்ளிகள்'},
    'Tap to Start Patrol Scan': {'EN': 'Tap to Start Patrol Scan', 'TA': 'ரோந்து ஸ்கேன் தொடங்க தட்டவும்'},
    'Scan Not Available': {'EN': 'Scan Not Available', 'TA': 'ஸ்கேன் செய்ய முடியாது'},
    'SCAN': {'EN': 'SCAN', 'TA': 'ஸ்கேன்'},
    'LOCKED': {'EN': 'LOCKED', 'TA': 'பூட்டப்பட்டது'},
    'In Progress': {'EN': 'In Progress', 'TA': 'நடைபெறுகிறது'},
    'Completed': {'EN': 'Completed', 'TA': 'முடிந்தது'},
    'Overdue': {'EN': 'Overdue', 'TA': 'காலாவதியானது'},
    'No QR codes to scan.': {'EN': 'No QR codes to scan.', 'TA': 'ஸ்கேன் செய்ய QR குறியீடு இல்லை.'},
    'SCAN WINDOW': {'EN': 'SCAN WINDOW', 'TA': 'ஸ்கேன் நேரம்'},
  };

  String _t(String key) {
    return _i10n[key]?[_selectedLang] ?? key;
  }

  // ── Animations ─────────────────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late AnimationController _fadeCtrl;
  late AnimationController _progressCtrl;
  late AnimationController _ringCtrl;
  late Animation<double>   _pulseAnim;
  late Animation<double>   _fadeAnim;
  late Animation<double>   _progressAnim;
  late Animation<double>   _ringAnim;
  double _targetProgress = 0;

  @override
  void initState() {
    super.initState();
    _selectedCampusCode = widget.campusCode == "ADMIN" ? "KCET01" : widget.campusCode;

    _loadSavedLanguage();

    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.10).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();

    _progressCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _progressAnim = const AlwaysStoppedAnimation(0);

    _ringCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 20))..repeat();
    _ringAnim = Tween<double>(begin: 0, end: 2 * math.pi).animate(_ringCtrl);

    _fetchInitialData();
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

  @override
  void dispose() {
    _pulseCtrl.dispose(); _fadeCtrl.dispose();
    _progressCtrl.dispose(); _ringCtrl.dispose();
    _refreshDebouncer?.cancel();
    super.dispose();
  }

  void _animateProgress(double v) {
    final old = _targetProgress; _targetProgress = v;
    _progressAnim = Tween<double>(begin: old, end: v).animate(
      CurvedAnimation(parent: _progressCtrl, curve: Curves.easeInOutCubic));
    _progressCtrl..reset()..forward();
  }

  // ── Data Fetching ──────────────────────────────────────────────────────────
  Future<void> _fetchInitialData() async {
    try {
      await Future.wait([
        _fetchCampuses().timeout(const Duration(seconds: 10), onTimeout: () {}),
        _fetchCampusName().timeout(const Duration(seconds: 10), onTimeout: () {}),
        _refreshPatrolStatus().timeout(const Duration(seconds: 10), onTimeout: () {}),
      ], eagerError: false);
    } catch (_) {}
    _updateRoundInfo();
    Timer.periodic(const Duration(minutes: 1), (t) { if (mounted) _updateRoundInfo(); });
  }

  Future<void> _fetchCampuses() async {
    try {
      final d = await Supabase.instance.client.from('campuses').select('campus_code, campus_name');
      if (mounted) setState(() => _campuses = List<Map<String,dynamic>>.from(d));
    } catch (_) {}
  }

  Future<void> _fetchCampusName() async {
    try {
      if (_selectedCampusCode == "ADMIN") { if (mounted) setState(() => _campusName = "Administrator"); return; }
      final d = await Supabase.instance.client.from('campuses')
          .select('campus_name').eq('campus_code', _selectedCampusCode).single();
      if (mounted) setState(() => _campusName = d['campus_name']);
    } catch (_) { if (mounted) setState(() => _campusName = "Unknown Campus"); }
  }

  void _updateRoundInfo() {
    final info = getCurrentPatrolRound(DateTime.now());
    final cur  = info['current'] as PatrolRound;
    final nxt  = info['next']    as PatrolRound;
    if (mounted) setState(() {
      _currentRound     = "Round ${cur.round}";
      _nextRoundTime    = "Next: ${nxt.label}";
      _currentRoundStart = info['currentRoundTime'] as DateTime;
      _scanWindowOpen   = info['scanWindowOpen']    as DateTime;
      _scanWindowClose  = info['scanWindowClose']   as DateTime;
    });
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
    try {
      final info       = getCurrentPatrolRound(DateTime.now());
      final roundStart = info['currentRoundTime'] as DateTime;
      final roundEnd   = info['scanWindowClose']  as DateTime;
      final closed     = DateTime.now().isAfter(roundEnd);
      final totalRes   = await Supabase.instance.client.from('qr').select('qr_id')
          .eq('campus_code', _selectedCampusCode).eq('status', 'active');
      final scannedRes = await Supabase.instance.client.from('scanning_details')
          .select('qr_id, status').eq('campus_code', _selectedCampusCode)
          .eq('round_slot', roundStart.toUtc().toIso8601String());
      final unique = <String>{};
      for (var s in scannedRes) {
        if (_isSuccessStatus(s['status'])) unique.add(s['qr_id'].toString());
      }
      String status = "In Progress";
      if (unique.length >= totalRes.length && totalRes.length > 0) status = "Success";
      else if (closed) status = "Missed";
      if (mounted) {
        final prog = totalRes.length > 0 ? unique.length / totalRes.length : 0.0;
        setState(() {
          _totalQrCount    = totalRes.length;
          _scannedCount    = unique.length;
          _patrolStatus    = status;
          _isLoadingStatus = false;
          _currentRoundStart = roundStart;
        });
        _animateProgress(prog);
      }
    } catch (_) { if (mounted) setState(() => _isLoadingStatus = false); }
    finally { _isRefreshing = false; }
  }

  // ── Report Data ───────────────────────────────────────────────────────────
  Future<void> _generateRoundSlots() async {
    setState(() => _isLoadingStatus = true);
    try {
      final now   = DateTime.now();
      final info  = getCurrentPatrolRound(now);
      final cur   = info['current'] as PatrolRound;
      final rounds = buildPatrolRounds(now);
      final curIdx = rounds.indexWhere((r) => r.round == cur.round);
      final qrData = await Supabase.instance.client.from('qr').select('qr_id')
          .eq('campus_code', _selectedCampusCode).eq('status', 'active');
      final total = qrData.length;
      List<Map<String,dynamic>> slots = [];
      for (var i = 0; i < rounds.length; i++) {
        final r = rounds[i];
        String status; int scanned = 0; String guard = '';
        List<dynamic> scannedData = [];
        if (total == 0) {
          status = 'no_qr';
        } else if (i < curIdx) {
          scannedData = await Supabase.instance.client.from('scanning_details')
              .select('qr_id, status, guard_name, scan_time')
              .eq('campus_code', _selectedCampusCode)
              .eq('round_slot', r.time.toUtc().toIso8601String());
          final seen = <String>{};
          for (var s in scannedData) {
            if (_isSuccessStatus(s['status'])) seen.add(s['qr_id'].toString());
          }
          scanned = seen.length;
          status  = seen.length >= total ? 'success' : 'missed';
          guard   = scannedData.isNotEmpty ? (scannedData.first['guard_name'] ?? '') : '';
        } else if (i == curIdx) {
          status = 'current';
          scanned = _scannedCount;
          guard   = widget.guardName;
        } else {
          status = 'future';
        }
        slots.add({
          'time': r.time, 'label': r.label,
          'round': 'Round ${r.round}', 'status': status,
          'scanned': scanned, 'total': total,
          'guard': guard.isNotEmpty ? guard : (status == 'future' ? 'Upcoming' : 'No record'),
          'scanData': scannedData,
        });
      }
      if (mounted) setState(() { _roundSlots = slots; _isLoadingStatus = false; });
    } catch (_) { if (mounted) setState(() => _isLoadingStatus = false); }
  }

  // ── Campus Dialog ─────────────────────────────────────────────────────────
  void _showCampusPicker() {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _GlassSheet(
        title: "Select Campus",
        icon: Icons.location_city_rounded,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _campuses.map((c) {
            final sel = _selectedCampusCode == c['campus_code'];
            return ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              tileColor: sel ? _kAccent.withOpacity(0.12) : null,
              leading: CircleAvatar(
                backgroundColor: _kAccent.withOpacity(0.15),
                child: Icon(Icons.business_rounded, color: _kAccent, size: 18),
              ),
              title: Text(c['campus_name'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: Text(c['campus_code'], style: const TextStyle(color: Colors.white38, fontSize: 12)),
              trailing: sel ? Icon(Icons.check_circle_rounded, color: _kGreen) : null,
              onTap: () {
                setState(() {
                  _selectedCampusCode = c['campus_code'];
                  _campusName = c['campus_name'];
                  _totalQrCount = 0; _scannedCount = 0; _patrolStatus = "In Progress";
                });
                Navigator.pop(context);
                _refreshPatrolStatus();
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  // ── Extraordinary Report ──────────────────────────────────────────────────
  void _showReport() {
    _generateRoundSlots().then((_) {
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _ReportSheet(
          roundSlots: _roundSlots,
          campusName: _campusName,
          totalQr: _totalQrCount,
          scanned: _scannedCount,
          isLoading: _isLoadingStatus,
        ),
      );
    });
  }

  // ── Shift Management ──────────────────────────────────────────────────────
  Future<void> _showShiftManagement() async {
    final client = Supabase.instance.client;
    showDialog(context: context, barrierDismissible: false,
      builder: (_) => const _LoadingDialog(message: "Loading shift data..."));
    try {
      final users  = await client.from('security_users').select('security_id, security_name, role').eq('role', 'Guard');
      final shifts = await client.from('shifts').select('shift_id, shift_name, start_time, end_time');
      final allocs = await client.from('shift_allocations').select('security_id, shift_id');
      if (!mounted) return;
      Navigator.pop(context);
      final guards    = List<Map<String,dynamic>>.from(users);
      final shiftList = List<Map<String,dynamic>>.from(shifts);
      final allocList = List<Map<String,dynamic>>.from(allocs);
      showModalBottomSheet(
        context: context, isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _ShiftSheet(
          guards: guards, shifts: shiftList, allocs: allocList,
          onSave: _editGuardShifts,
        ),
      );
    } catch (_) {
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _editGuardShifts(String sid, List<String> shiftIds) async {
    try {
      await Supabase.instance.client.from('shift_allocations').delete().eq('security_id', sid);
      if (shiftIds.isNotEmpty) {
        await Supabase.instance.client.from('shift_allocations').insert(
          shiftIds.map((s) => {'security_id': sid, 'shift_id': s, 'allocation_date': '2099-12-31'}).toList());
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Shifts updated!"), backgroundColor: _kGreen,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 1),
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Failed: $e"), backgroundColor: _kRed,
        behavior: SnackBarBehavior.floating));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isAvailable = _isWithinScanWindow() || (_totalQrCount == 0 && widget.isMaster);
    final double prog  = _totalQrCount > 0 ? _scannedCount / _totalQrCount : 0.0;

    Color statusColor; IconData statusIcon;
    switch (_patrolStatus) {
      case "Success": statusColor = _kGreen;  statusIcon = Icons.check_circle_rounded; break;
      case "Missed":  statusColor = _kRed;    statusIcon = Icons.cancel_rounded; break;
      default:        statusColor = _kOrange; statusIcon = Icons.timelapse_rounded;
    }

    String windowText = "";
    if (_scanWindowOpen != null && _scanWindowClose != null) {
      final now = DateTime.now();
      if (now.isBefore(_scanWindowOpen!))
        windowText = "Opens ${DateFormat('hh:mm a').format(_scanWindowOpen!)}";
      else if (now.isAfter(_scanWindowClose!))
        windowText = "Closed ${DateFormat('hh:mm a').format(_scanWindowClose!)}";
      else
        windowText = "Closes ${DateFormat('hh:mm a').format(_scanWindowClose!)}";
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: _kBg1,
      appBar: AppBar(
        backgroundColor: Colors.transparent, elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        automaticallyImplyLeading: false,
        title: Row(children: [
          AnimatedBuilder(
            animation: _ringAnim,
            builder: (_, __) => Transform.rotate(
              angle: _ringAnim.value,
              child: const Icon(Icons.radar_rounded, color: _kCyan, size: 20),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _t("Security Rounds"),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        actions: [
          GestureDetector(
            onTap: _toggleLanguage,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _kAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _kAccent.withOpacity(0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.translate_rounded, color: _kCyan, size: 14),
                  const SizedBox(width: 4),
                  Text(_selectedLang == 'EN' ? 'தமிழ்' : 'English',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          if (widget.isMaster) _topBtn(Icons.assessment_rounded, _showReport),
          _topBtn(Icons.refresh_rounded, () {
            _refreshDebouncer?.cancel();
            _refreshDebouncer = Timer(const Duration(milliseconds: 400), () {
              HapticFeedback.lightImpact();
              _refreshPatrolStatus();
            });
          }),
          _topBtn(Icons.logout_rounded, () => Navigator.pushReplacementNamed(context, '/')),
        ],
      ),
      body: FadeTransition(
        opacity: _fadeAnim,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [_kBg2, _kBg1],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              child: Column(children: [

                // ── Header Card ────────────────────────────────────────────
                _glassCard(child: Row(children: [
                  GestureDetector(
                    onTap: widget.isMaster ? _showCampusPicker : null,
                    child: Container(
                      width: 52, height: 52,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1565C0), _kCyan],
                          begin: Alignment.topLeft, end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [BoxShadow(color: _kAccent.withOpacity(0.4), blurRadius: 12)],
                      ),
                      child: const Icon(Icons.shield_rounded, color: Colors.white, size: 28),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_campusName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Row(children: [
                      const Icon(Icons.person_rounded, size: 13, color: Colors.white38),
                      const SizedBox(width: 4),
                      Text(widget.guardName, style: const TextStyle(fontSize: 12, color: Colors.white38)),
                    ]),
                  ])),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    if (widget.isMaster)
                      _statusChip("ADMIN", Colors.purpleAccent, Icons.admin_panel_settings_rounded)
                    else if (windowText.isNotEmpty)
                      _statusChip(windowText,
                        _isWithinScanWindow() ? _kGreen : _kOrange,
                        _isWithinScanWindow() ? Icons.lock_open_rounded : Icons.lock_clock_rounded),
                    if (widget.isMaster) ...[
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: _showShiftManagement,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.group_rounded, size: 12, color: Colors.white54),
                            const SizedBox(width: 4),
                            Text(_t("Shifts"), style: const TextStyle(fontSize: 11, color: Colors.white54)),
                          ]),
                        ),
                      ),
                    ],
                  ]),
                ])),

                const SizedBox(height: 12),

                // ── Clock + Round Card ─────────────────────────────────────
                _glassCard(child: Column(children: [
                  StreamBuilder(
                    stream: Stream.periodic(const Duration(seconds: 1)),
                    builder: (_, __) => Text(
                      DateFormat('hh:mm:ss a').format(DateTime.now()),
                      style: const TextStyle(
                        fontSize: 40, fontWeight: FontWeight.w200,
                        letterSpacing: 3, color: Colors.white,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  StreamBuilder(
                    stream: Stream.periodic(const Duration(seconds: 1)),
                    builder: (_, __) => Text(
                      DateFormat('EEEE, d MMM yyyy').format(DateTime.now()),
                      style: const TextStyle(fontSize: 12, color: Colors.white38),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    _roundPill(_currentRound, _kAccent),
                    const SizedBox(width: 8),
                    if (_scanWindowOpen != null && _scanWindowClose != null)
                      _roundPill(
                        "${DateFormat('hh:mm a').format(_scanWindowOpen!)} – ${DateFormat('hh:mm a').format(_scanWindowClose!)}",
                        Colors.white24,
                      ),
                  ]),
                  const SizedBox(height: 6),
                  Text(_nextRoundTime,
                    style: const TextStyle(fontSize: 11, color: Colors.white24)),
                ])),

                const SizedBox(height: 12),

                // ── Stats Row ──────────────────────────────────────────────
                Row(children: [
                  _statBox(_t("Total QR"), "$_totalQrCount", Icons.qr_code_rounded, Colors.white24),
                  const SizedBox(width: 10),
                  _statBox(_t("Scanned"), "$_scannedCount", Icons.check_circle_rounded, _kGreen),
                  const SizedBox(width: 10),
                  _statBox(_t("Left"), "${_totalQrCount - _scannedCount}", Icons.pending_rounded, _kOrange),
                ]),

                const SizedBox(height: 12),

                // ── Scan Button ───────────────────────────────────────────
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
                      _refreshDebouncer = Timer(const Duration(milliseconds: 400), _refreshPatrolStatus);
                    } else {
                      HapticFeedback.heavyImpact();
                      ScaffoldMessenger.of(context)
                        ..clearSnackBars()
                        ..showSnackBar(SnackBar(
                          behavior: SnackBarBehavior.floating,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          backgroundColor: _kRed,
                          margin: const EdgeInsets.all(16),
                          content: Row(children: [
                            const Icon(Icons.lock_clock_rounded, color: Colors.white),
                            const SizedBox(width: 10),
                            Expanded(child: Text(
                              widget.isMaster ? _t("No QR codes to scan.") : "${_t('SCAN WINDOW')} $windowText",
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                            )),
                          ]),
                          duration: const Duration(seconds: 3),
                        ));
                    }
                  },
                  child: isAvailable
                    ? ScaleTransition(scale: _pulseAnim, child: _buildScanBtn(true))
                    : _buildScanBtn(false),
                ),
                const SizedBox(height: 10),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 300),
                  style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 0.5,
                    color: isAvailable ? Colors.white : Colors.white24,
                  ),
                  child: Text(isAvailable ? _t("Tap to Start Patrol Scan") : _t("Scan Not Available")),
                ),

                const SizedBox(height: 20),

                // ── Progress Card (Below Scan Button) ─────────────────────
                _glassCard(child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text(_t("Patrol Progress"), style: const TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w500)),
                    _isLoadingStatus
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: _kCyan))
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(statusIcon, color: statusColor, size: 14),
                          const SizedBox(width: 5),
                          Text(_t(_patrolStatus), style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 12)),
                        ]),
                  ]),
                  const SizedBox(height: 16),
                  if (!_isLoadingStatus)
                    Row(children: [
                      // Radial gauge
                      AnimatedBuilder(
                        animation: _progressAnim,
                        builder: (_, __) => SizedBox(
                          width: 68, height: 68,
                          child: CustomPaint(
                            painter: _RadialGaugePainter(
                              progress: _progressAnim.value,
                              color: statusColor,
                            ),
                            child: Center(
                              child: Text(
                                "${(_progressAnim.value * 100).toInt()}%",
                                style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text("$_scannedCount of $_totalQrCount ${_t('checkpoints')}",
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 8),
                        AnimatedBuilder(
                          animation: _progressAnim,
                          builder: (_, __) => ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: LinearProgressIndicator(
                              value: _progressAnim.value,
                              minHeight: 8,
                              backgroundColor: Colors.white10,
                              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                            ),
                          ),
                        ),
                      ])),
                    ])
                  else
                    const Padding(padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(color: _kCyan, strokeWidth: 3)),
                ])),

                const SizedBox(height: 16),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScanBtn(bool active) {
    return Stack(alignment: Alignment.center, children: [
      if (active)
        AnimatedBuilder(animation: _pulseCtrl, builder: (_, __) => Container(
          width: 148 + (_pulseCtrl.value * 12),
          height: 148 + (_pulseCtrl.value * 12),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _kAccent.withOpacity(0.06 * (1 - _pulseCtrl.value)),
          ),
        )),
      Container(
        width: 140, height: 140,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: active
              ? [const Color(0xFF1565C0), const Color(0xFF0D47A1)]
              : [const Color(0xFF2D2D2D), const Color(0xFF1A1A1A)],
          ),
          boxShadow: [
            BoxShadow(
              color: (active ? _kAccent : Colors.black).withOpacity(0.5),
              blurRadius: 36, spreadRadius: 4, offset: const Offset(0, 8),
            ),
            if (active) BoxShadow(color: _kCyan.withOpacity(0.15), blurRadius: 60, spreadRadius: 8),
          ],
          border: Border.all(
            color: active ? _kAccent.withOpacity(0.4) : Colors.white10, width: 2),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(
            active ? Icons.qr_code_scanner_rounded : Icons.lock_rounded,
            size: 50, color: Colors.white,
          ),
          const SizedBox(height: 4),
          Text(active ? _t("SCAN") : _t("LOCKED"),
            style: TextStyle(
              fontSize: 10, fontWeight: FontWeight.bold,
              color: Colors.white.withOpacity(active ? 0.8 : 0.3),
              letterSpacing: 1.5,
            )),
        ]),
      ),
    ]);
  }

  Widget _glassCard({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: _kCard.withOpacity(0.9),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withOpacity(0.08)),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 20, offset: const Offset(0, 6))],
    ),
    child: child,
  );

  Widget _topBtn(IconData icon, VoidCallback cb) => IconButton(
    icon: Icon(icon, color: Colors.white70), onPressed: cb, splashRadius: 22);

  Widget _statusChip(String label, Color color, IconData icon) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withOpacity(0.15),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.4)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 11, color: color),
      const SizedBox(width: 4),
      Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
    ]),
  );

  Widget _roundPill(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    decoration: BoxDecoration(
      color: color.withOpacity(0.15),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Text(label, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
  );

  Widget _statBox(String label, String value, IconData icon, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: _kCard.withOpacity(0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 20)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ]),
    ),
  );

  PageRoute _slideRoute(Widget page) => PageRouteBuilder(
    pageBuilder: (_, a, __) => page,
    transitionsBuilder: (_, a, __, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
    transitionDuration: const Duration(milliseconds: 380),
  );
}

// ─── Radial Gauge Painter ─────────────────────────────────────────────────────
class _RadialGaugePainter extends CustomPainter {
  final double progress;
  final Color  color;
  _RadialGaugePainter({required this.progress, required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 6;
    // Track
    canvas.drawCircle(c, r, Paint()..color = Colors.white10..style = PaintingStyle.stroke..strokeWidth = 7);
    // Arc
    final arcPaint = Paint()
      ..color = color ..style = PaintingStyle.stroke ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r),
      -math.pi / 2, 2 * math.pi * progress, false, arcPaint);
  }
  @override bool shouldRepaint(_RadialGaugePainter old) => old.progress != progress;
}

// ─── Glass Sheet ──────────────────────────────────────────────────────────────
class _GlassSheet extends StatelessWidget {
  final String title; final IconData icon; final Widget child;
  const _GlassSheet({required this.title, required this.icon, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xFF111836),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: Colors.white.withOpacity(0.08)),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 8),
      Container(width: 40, height: 4,
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
        child: Row(children: [
          Icon(icon, color: _kAccent, size: 22),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
        ]),
      ),
      const Divider(color: Colors.white10, height: 1),
      Flexible(child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        child: child,
      )),
    ]),
  );
}

// ─── Loading Dialog ───────────────────────────────────────────────────────────
class _LoadingDialog extends StatelessWidget {
  final String message;
  const _LoadingDialog({required this.message});
  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: const Color(0xFF111836),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    content: Row(children: [
      const CircularProgressIndicator(color: _kAccent, strokeWidth: 3),
      const SizedBox(width: 16),
      Text(message, style: const TextStyle(color: Colors.white70)),
    ]),
  );
}

// ─── Shift Sheet ──────────────────────────────────────────────────────────────
class _ShiftSheet extends StatefulWidget {
  final List<Map<String,dynamic>> guards, shifts, allocs;
  final Future<void> Function(String, List<String>) onSave;
  const _ShiftSheet({required this.guards, required this.shifts, required this.allocs, required this.onSave});
  @override
  State<_ShiftSheet> createState() => _ShiftSheetState();
}

class _ShiftSheetState extends State<_ShiftSheet> {
  late List<Map<String,dynamic>> _allocs;
  @override
  void initState() { super.initState(); _allocs = List.from(widget.allocs); }
  @override
  Widget build(BuildContext context) => _GlassSheet(
    title: "Guard Shifts", icon: Icons.manage_accounts_rounded,
    child: Column(
      children: widget.guards.map((g) {
        final gid = g['security_id'];
        final assigned = _allocs.where((a) => a['security_id'] == gid)
            .map((a) => a['shift_id'].toString()).toSet();
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CircleAvatar(radius: 20, backgroundColor: _kAccent.withOpacity(0.15),
                child: const Icon(Icons.person_rounded, color: _kAccent, size: 20)),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(g['security_name'] ?? 'Guard', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                Text("ID: $gid", style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (assigned.isEmpty ? _kRed : _kGreen).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(assigned.isEmpty ? "No shift" : "${assigned.length} shift(s)",
                  style: TextStyle(color: assigned.isEmpty ? _kRed : _kGreen,
                    fontWeight: FontWeight.bold, fontSize: 11)),
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 4,
              children: widget.shifts.map((s) {
                final sid = s['shift_id'].toString();
                final on  = assigned.contains(sid);
                return FilterChip(
                  label: Text("${s['shift_name']} (${s['start_time']}–${s['end_time']})",
                    style: const TextStyle(fontSize: 11)),
                  selected: on,
                  selectedColor: _kAccent.withOpacity(0.2),
                  checkmarkColor: _kAccent,
                  onSelected: (val) async {
                    final upd = Set<String>.from(assigned);
                    val ? upd.add(sid) : upd.remove(sid);
                    await widget.onSave(gid, upd.toList());
                    _allocs.removeWhere((a) => a['security_id'] == gid);
                    for (var id in upd) _allocs.add({'security_id': gid, 'shift_id': id});
                    setState(() {});
                  },
                );
              }).toList(),
            ),
          ]),
        );
      }).toList(),
    ),
  );
}

// ─── Extraordinary Report Sheet ───────────────────────────────────────────────
class _ReportSheet extends StatefulWidget {
  final List<Map<String,dynamic>> roundSlots;
  final String campusName;
  final int totalQr, scanned;
  final bool isLoading;
  const _ReportSheet({required this.roundSlots, required this.campusName,
      required this.totalQr, required this.scanned, required this.isLoading});
  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..forward();
  }
  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final success = widget.roundSlots.where((s) => s['status'] == 'success').length;
    final missed  = widget.roundSlots.where((s) => s['status'] == 'missed').length;
    final active  = widget.roundSlots.where((s) => s['status'] == 'current').length;
    final future  = widget.roundSlots.where((s) => s['status'] == 'future').length;
    final total   = widget.roundSlots.length;
    final rate    = total > 0 ? (success / total * 100) : 0.0;

    return DraggableScrollableSheet(
      initialChildSize: 0.92, minChildSize: 0.5, maxChildSize: 0.97,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0A0E27),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: Colors.white10)),
        ),
        child: Column(children: [
          // Handle
          const SizedBox(height: 8),
          Container(width: 44, height: 4,
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 4),

          // Header Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [_kAccent, _kCyan]),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.analytics_rounded, color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text("Patrol Report", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                Text(widget.campusName, style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ])),
              IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white54),
                onPressed: () => Navigator.pop(context)),
            ]),
          ),

          Expanded(child: ListView(
            controller: scrollCtrl,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [

              // ── Summary Cards ─────────────────────────────────────────
              Row(children: [
                _summaryCard("Success", "$success", _kGreen, Icons.check_circle_rounded),
                const SizedBox(width: 8),
                _summaryCard("Missed", "$missed", _kRed, Icons.cancel_rounded),
                const SizedBox(width: 8),
                _summaryCard("Active", "$active", _kAccent, Icons.play_circle_rounded),
                const SizedBox(width: 8),
                _summaryCard("Future", "$future", Colors.white24, Icons.schedule_rounded),
              ]),

              const SizedBox(height: 14),

              // ── Completion Rate Card ───────────────────────────────────
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_kAccent.withOpacity(0.15), _kCyan.withOpacity(0.08)],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _kAccent.withOpacity(0.2)),
                ),
                child: Row(children: [
                  SizedBox(width: 80, height: 80,
                    child: CustomPaint(
                      painter: _RadialGaugePainter(progress: rate / 100, color: _kGreen),
                      child: Center(child: Text("${rate.toInt()}%",
                        style: const TextStyle(color: _kGreen, fontWeight: FontWeight.bold, fontSize: 16))),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text("Completion Rate", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text("$success of $total rounds completed",
                      style: const TextStyle(color: Colors.white54, fontSize: 13)),
                    const SizedBox(height: 10),
                    Row(children: [
                      _miniStat("QR Total", "${widget.totalQr}"),
                      const SizedBox(width: 16),
                      _miniStat("Scanned", "${widget.scanned}"),
                    ]),
                  ])),
                ]),
              ),

              const SizedBox(height: 18),

              const Row(children: [
                Icon(Icons.timeline_rounded, color: _kAccent, size: 18),
                SizedBox(width: 8),
                Text("Timeline", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              ]),

              const SizedBox(height: 12),

              // ── Timeline ──────────────────────────────────────────────
              widget.isLoading
                ? const Center(child: Padding(padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(color: _kAccent)))
                : widget.roundSlots.isEmpty
                  ? Center(child: Padding(padding: const EdgeInsets.all(32),
                      child: Column(children: [
                        const Icon(Icons.inbox_rounded, color: Colors.white24, size: 48),
                        const SizedBox(height: 12),
                        Text("No round data", style: const TextStyle(color: Colors.white38)),
                      ])))
                  : Column(
                      children: widget.roundSlots.asMap().entries.map((entry) {
                        final i    = entry.key;
                        final slot = entry.value;
                        final anim = Tween<double>(begin: 0, end: 1).animate(
                          CurvedAnimation(
                            parent: _ctrl,
                            curve: Interval(
                              math.min(i * 0.04, 0.9), math.min(i * 0.04 + 0.2, 1.0),
                              curve: Curves.easeOutCubic,
                            ),
                          ),
                        );
                        return AnimatedBuilder(
                          animation: anim,
                          builder: (_, child) => Opacity(
                            opacity: anim.value,
                            child: Transform.translate(offset: Offset(0, 20 * (1 - anim.value)), child: child),
                          ),
                          child: _TimelineItem(slot: slot, isLast: i == widget.roundSlots.length - 1),
                        );
                      }).toList(),
                    ),
            ],
          )),
        ]),
      ),
    );
  }

  Widget _summaryCard(String label, String val, Color color, IconData icon) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(val, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18)),
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
      ]),
    ),
  );

  Widget _miniStat(String label, String val) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
    Text(val, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
  ]);
}

// ─── Timeline Item ────────────────────────────────────────────────────────────
class _TimelineItem extends StatefulWidget {
  final Map<String,dynamic> slot;
  final bool isLast;
  const _TimelineItem({required this.slot, required this.isLast});
  @override
  State<_TimelineItem> createState() => _TimelineItemState();
}

class _TimelineItemState extends State<_TimelineItem> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final slot   = widget.slot;
    final status = slot['status'] as String;
    final scanned = (slot['scanned'] ?? 0) as int;
    final total   = (slot['total']   ?? 0) as int;
    final prog    = total > 0 ? scanned / total : 0.0;

    Color dotColor; IconData dotIcon; String badgeText;
    switch (status) {
      case 'success': dotColor = _kGreen;  dotIcon = Icons.check_circle_rounded; badgeText = 'DONE'; break;
      case 'missed':  dotColor = _kRed;    dotIcon = Icons.cancel_rounded;       badgeText = 'MISSED'; break;
      case 'current': dotColor = _kAccent; dotIcon = Icons.play_circle_rounded;  badgeText = 'ACTIVE'; break;
      case 'no_qr':   dotColor = Colors.grey; dotIcon = Icons.remove_circle_rounded; badgeText = 'NO QR'; break;
      default:        dotColor = Colors.white24; dotIcon = Icons.schedule_rounded; badgeText = 'UPCOMING';
    }

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Timeline line + dot
      SizedBox(width: 28, child: Column(children: [
        Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: dotColor.withOpacity(0.15),
            shape: BoxShape.circle,
            border: Border.all(color: dotColor.withOpacity(0.5), width: 1.5),
            boxShadow: status == 'current' ? [BoxShadow(color: dotColor.withOpacity(0.4), blurRadius: 8)] : null,
          ),
          child: Icon(dotIcon, color: dotColor, size: 14),
        ),
        if (!widget.isLast)
          Container(width: 1.5, height: 52, color: Colors.white10),
      ])),

      const SizedBox(width: 12),

      // Content
      Expanded(child: GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: dotColor.withOpacity(status == 'current' ? 0.08 : 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: dotColor.withOpacity(0.2)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(slot['round'], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                Text(slot['label'], style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ])),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: dotColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(badgeText,
                  style: TextStyle(color: dotColor, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 6),
              Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                color: Colors.white24, size: 18),
            ]),

            // Progress mini bar
            if (status != 'future' && status != 'no_qr') ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: prog, minHeight: 4,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(dotColor),
                  ),
                )),
                const SizedBox(width: 8),
                Text("$scanned/$total", style: TextStyle(color: dotColor, fontSize: 11, fontWeight: FontWeight.bold)),
              ]),
            ],

            // Expanded detail
            if (_expanded) ...[
              const SizedBox(height: 10),
              const Divider(color: Colors.white10, height: 1),
              const SizedBox(height: 10),
              _detailRow(Icons.person_rounded, "Guard", slot['guard'] ?? '—'),
              const SizedBox(height: 4),
              _detailRow(Icons.access_time_rounded, "Window",
                "${slot['label']} (+45 min to +90 min)"),
              if (status == 'success')
                _detailRow(Icons.done_all_rounded, "Result", "All $total checkpoints scanned"),
              if (status == 'missed')
                _detailRow(Icons.warning_rounded, "Result", "$scanned of $total scanned — Round missed"),
            ],
          ]),
        ),
      )),
    ]);
  }

  Widget _detailRow(IconData icon, String label, String val) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      Icon(icon, size: 14, color: Colors.white38),
      const SizedBox(width: 8),
      Text("$label: ", style: const TextStyle(color: Colors.white38, fontSize: 12)),
      Expanded(child: Text(val, style: const TextStyle(color: Colors.white70, fontSize: 12))),
    ]),
  );
}