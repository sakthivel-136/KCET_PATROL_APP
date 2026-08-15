import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'round_utils.dart';
import 'scan_page.dart';

class HomePage extends StatefulWidget {
  final String guardName;
  final String campusCode;
  final bool isMaster;
  final bool canScan;
  const HomePage(
      {super.key,
      required this.guardName,
      required this.campusCode,
      required this.isMaster,
      required this.canScan});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
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
  
  // Prevent multiple refresh calls
  bool _isRefreshing = false;
  Timer? _refreshDebouncer;

  @override
  void initState() {
    super.initState();
    _selectedCampusCode = widget.campusCode == "ADMIN" ? "KCET01" : widget.campusCode;
    _fetchInitialData();
  }

  @override
  void dispose() {
    _refreshDebouncer?.cancel();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    try {
      await Future.wait([
        _fetchCampuses().timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('Campuses fetch timeout');
          },
        ),
        _fetchCampusName().timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('Campus name fetch timeout');
          },
        ),
        _refreshPatrolStatus().timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            debugPrint('Patrol status fetch timeout');
          },
        ),
      ], eagerError: false);
    } catch (e) {
      debugPrint('Initial data fetch error: $e');
    }
    
    _updateRoundInfo();
    Timer.periodic(const Duration(minutes: 1), (timer) {
      if (mounted) _updateRoundInfo();
    });
  }

  Future<void> _fetchCampuses() async {
    try {
      final data = await Supabase.instance.client
          .from('campuses')
          .select('campus_code, campus_name');
      if (mounted) {
        setState(() {
          _campuses = List<Map<String, dynamic>>.from(data);
        });
      }
    } catch (e) {
      debugPrint("Error fetching campuses: $e");
    }
  }

  Future<void> _fetchCampusName() async {
    try {
      if (_selectedCampusCode == "ADMIN") {
        if (mounted) {
          setState(() => _campusName = "Administrator");
        }
        return;
      }

      final data = await Supabase.instance.client
          .from('campuses')
          .select('campus_name')
          .eq('campus_code', _selectedCampusCode)
          .single();
      if (mounted) {
        setState(() => _campusName = data['campus_name']);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _campusName = "Unknown Campus");
      }
    }
  }

  Map<String, dynamic> _getCurrentRoundSlot() {
    return getCurrentPatrolRound(DateTime.now());
  }

  void _updateRoundInfo() {
    final roundInfo = _getCurrentRoundSlot();
    final currentSlot = roundInfo['current'] as PatrolRound;
    final nextSlot = roundInfo['next'] as PatrolRound;
    final roundTime = roundInfo['currentRoundTime'] as DateTime;

    if (mounted) {
      setState(() {
        _currentRound = "Round ${currentSlot.round}";
        _nextRoundTime = "Next: ${nextSlot.label}";
        _currentRoundStart = roundTime;
        _scanWindowOpen = roundInfo['scanWindowOpen'] as DateTime;
        _scanWindowClose = roundInfo['scanWindowClose'] as DateTime;
      });
    }
  }

  bool _isWithinScanWindow() {
    final now = DateTime.now();

    if (_currentRoundStart == null || _scanWindowOpen == null || _scanWindowClose == null) {
      return false;
    }

    return !now.isBefore(_scanWindowOpen!) && now.isBefore(_scanWindowClose!);
  }

  bool _isSuccessStatus(String? status) {
    if (status == null) return false;
    
    final statusLower = status.toLowerCase();
    
    return statusLower == 'success' || 
           statusLower == 'complete' || 
           statusLower == 'done' || 
           statusLower == 'ok';
  }

  Future<void> _refreshPatrolStatus() async {
    // Prevent multiple simultaneous refresh calls
    if (_isRefreshing) return;
    
    _isRefreshing = true;
    
    if (!mounted) {
      _isRefreshing = false;
      return;
    }
    
    setState(() => _isLoadingStatus = true);
    final client = Supabase.instance.client;
    final now = DateTime.now();
    final roundInfo = _getCurrentRoundSlot();
    final roundStart = roundInfo['currentRoundTime'] as DateTime;
    final roundEnd = roundInfo['scanWindowClose'] as DateTime;
    bool isScanWindowClosed = now.isAfter(roundEnd);
    
    try {
      // *** CRITICAL: Always filter by campus_code for independent campus operations ***
      final totalRes = await client
          .from('qr')
          .select('qr_id')
          .eq('campus_code', _selectedCampusCode)
          .eq('status', 'active');
      
      final scannedRes = await client
          .from('scanning_details')
          .select('qr_id, status')
          .eq('campus_code', _selectedCampusCode)
          .eq('round_slot', roundStart.toUtc().toIso8601String());

      final uniqueScans = <String>{};
      for (var scan in scannedRes) {
        if (_isSuccessStatus(scan['status'])) {
          uniqueScans.add(scan['qr_id'].toString());
        }
      }
          
      String status = "In Progress";
      // Only mark as success if THIS FACTORY has completed all scans
      if (uniqueScans.length >= totalRes.length && totalRes.length > 0) {
        status = "Success";
      } else if (isScanWindowClosed) {
        status = "Missed";
      }
      
      if (mounted) {
        setState(() {
          _totalQrCount = totalRes.length;
          _scannedCount = uniqueScans.length;
          _patrolStatus = status;
          _isLoadingStatus = false;
          _currentRoundStart = roundStart;
        });
      }
    } catch (e) {
      debugPrint("Error in _refreshPatrolStatus: $e");
      if (mounted) {
        setState(() => _isLoadingStatus = false);
      }
    } finally {
      _isRefreshing = false;
    }
  }

  void _showCampusSelectionDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Select Campus"),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _campuses.length,
              itemBuilder: (BuildContext context, int index) {
                final campus = _campuses[index];
                return ListTile(
                  title: Text(campus['campus_name']),
                  subtitle: Text("Code: ${campus['campus_code']}"),
                  onTap: () {
                    setState(() {
                      _selectedCampusCode = campus['campus_code'];
                      _campusName = campus['campus_name'];
                      // Reset counts when switching campuses
                      _totalQrCount = 0;
                      _scannedCount = 0;
                      _patrolStatus = "In Progress";
                    });
                    Navigator.of(context).pop();
                    _refreshPatrolStatus();
                  },
                  trailing: _selectedCampusCode == campus['campus_code']
                      ? const Icon(Icons.check, color: Color(0xFF005C97))
                      : null,
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("Cancel"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _generateRoundSlots() async {
    setState(() => _isLoadingStatus = true);
    try {
      final now = DateTime.now();
      final client = Supabase.instance.client;
      List<Map<String, dynamic>> slots = [];
      final rounds = buildPatrolRounds(now);
      final currentInfo = getCurrentPatrolRound(now);
      final currentRound = currentInfo['current'] as PatrolRound;
      final currentIndex = rounds.indexWhere((round) => round.time == currentRound.time);

      final qrData = await client
          .from('qr')
          .select('qr_id')
          .eq('campus_code', _selectedCampusCode)
          .eq('status', 'active');
      int totalQrCount = qrData.length;

      if (totalQrCount == 0) {
        for (var round in rounds) {
          slots.add({
            'time': round.time,
            'label': round.label,
            'round': 'Round ${round.round}',
            'status': 'no_qr'
          });
        }
      } else {
        for (var i = 0; i < rounds.length; i++) {
          final round = rounds[i];
          final slotTime = round.time;

          String status;
          List<dynamic> scannedData = [];

          if (i < currentIndex) {
            scannedData = await client
                .from('scanning_details')
                .select('qr_id, status, guard_name')
                .eq('campus_code', _selectedCampusCode)
                .eq('round_slot', slotTime.toUtc().toIso8601String());

            final seenQrIds = <String>{};
            for (var scan in scannedData) {
              if (_isSuccessStatus(scan['status'])) {
                seenQrIds.add(scan['qr_id'].toString());
              }
            }
            
            if (seenQrIds.length >= totalQrCount) {
              status = 'success';
            } else {
              status = 'missed';
            }
          } else if (i == currentIndex) {
            status = 'current';
          } else {
            status = 'future';
          }

          slots.add({
            'time': slotTime,
            'label': round.label,
            'round': 'Round ${round.round}',
            'status': status,
            'guard_name': status == 'success'
                ? (scannedData.isNotEmpty && scannedData.first['guard_name'] != null)
                    ? scannedData.first['guard_name']
                    : "Completed"
                : (status == 'missed')
                    ? (scannedData.isNotEmpty && scannedData.first['guard_name'] != null)
                        ? scannedData.first['guard_name']
                        : "No guard"
                : (status == 'current')
                    ? "In progress"
                    : "Not started",
          });
        }
      }

      if (mounted) {
        setState(() {
          _roundSlots = slots;
          _isLoadingStatus = false;
        });
      }
    } catch (e) {
      debugPrint("Error generating round slots: $e");
      if (mounted) {
        setState(() => _isLoadingStatus = false);
      }
    }
  }

  void _showRoundDetails(Map<String, dynamic> slot) async {
    final slotTime = slot['time'] as DateTime;
    try {
      final client = Supabase.instance.client;
      final allQrData = await client
          .from('qr')
          .select('qr_id, qr_name')
          .eq('campus_code', _selectedCampusCode)
          .eq('status', 'active');
      final scanDetails = await client
          .from('scanning_details')
          .select('qr_id, qr_name, guard_name, scan_time, status')
          .eq('campus_code', _selectedCampusCode)
          .eq('round_slot', slotTime.toUtc().toIso8601String());
      Map<String, dynamic> scannedQrMap = {};
      for (var scan in scanDetails) {
        scannedQrMap[scan['qr_id'].toString()] = scan;
      }
      if (mounted) {
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text("${slot['round']} Details (${slot['label']})"),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: allQrData.isEmpty
                    ? const Center(child: Text("No QR codes assigned to this campus"))
                    : ListView.builder(
                        itemCount: allQrData.length,
                        itemBuilder: (context, index) {
                          final qr = allQrData[index];
                          final qrId = qr['qr_id'].toString();
                          final isScanned = scannedQrMap.containsKey(qrId);
                          String statusText;
                          Color statusColor;
                          String scannedBy = "Not scanned";
                          String scanTime = "";
                          if (isScanned) {
                            final scan = scannedQrMap[qrId];
                            bool isSuccess = _isSuccessStatus(scan['status']);
                            statusText = isSuccess ? "Success" : "Failed";
                            statusColor = isSuccess ? Colors.green : Colors.red;
                            scannedBy = scan['guard_name'] ?? "Unknown";
                            scanTime = _formatScanTime(scan['scan_time']);
                          } else {
                            final now = DateTime.now();
                            final scanWindowStart = getScanWindowStart(slotTime);
                            final scanWindowEnd = getScanWindowEnd(slotTime);

                            if (now.isAfter(scanWindowEnd)) {
                              statusText = "Missed";
                              statusColor = Colors.red;
                            } else if (now.isBefore(scanWindowStart)) {
                              statusText = "Pending";
                              statusColor = Colors.grey;
                            } else {
                              statusText = "Pending";
                              statusColor = Colors.orange;
                            }
                          }
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    qr['qr_name'] ?? 'Unknown QR',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    "QR ID: $qrId",
                                    style: const TextStyle(
                                        fontSize: 14, color: Colors.black54),
                                  ),
                                  if (isScanned) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      "Scanned by: $scannedBy",
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      "Time: $scanTime",
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ],
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: statusColor.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: statusColor),
                                    ),
                                    child: Text(
                                      statusText,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: statusColor,
                                      ),
                                    ),
                                  )
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text("Close"),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      debugPrint("Error fetching round details: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error loading details: $e")),
        );
      }
    }
  }

  String _formatScanTime(String? scanTime) {
    if (scanTime == null) return "Unknown";
    try {
      final utcDateTime = DateTime.parse(scanTime);
      final localDateTime = utcDateTime.toLocal();
      return DateFormat('hh:mm:ss a').format(localDateTime);
    } catch (e) {
      return "Invalid time";
    }
  }

  void _showRoundReportDialog() {
    _generateRoundSlots().then((_) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: Text("Patrol Rounds Report - $_campusName"),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: _isLoadingStatus
                    ? const Center(child: CircularProgressIndicator())
                    : _roundSlots.isEmpty
                        ? const Center(child: Text("No rounds available"))
                        : ListView.builder(
                            itemCount: _roundSlots.length,
                            itemBuilder: (context, index) {
                              final slot = _roundSlots[index];
                              final status = slot['status'];
                              Color statusColor;
                              String statusText;
                              switch (status) {
                                case 'success':
                                  statusColor = Colors.green;
                                  statusText = 'Success';
                                  break;
                                case 'missed':
                                  statusColor = Colors.red;
                                  statusText = 'Missed';
                                  break;
                                case 'current':
                                  statusColor = Colors.blue;
                                  statusText = 'In Progress';
                                  break;
                                case 'no_qr':
                                  statusColor = Colors.grey;
                                  statusText = 'No QR Available';
                                  break;
                                default:
                                  statusColor = Colors.grey;
                                  statusText = 'No Data';
                              }
                              return Card(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                child: ListTile(
                                  title: Text(slot['round']),
                                  subtitle: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(slot['label']),
                                      const SizedBox(height: 2),
                                      Text(
                                        "Guard: ${slot['guard_name'] ?? 'Unknown'}",
                                        style: const TextStyle(
                                            fontSize: 12, color: Colors.black54),
                                      ),
                                    ],
                                  ),
                                  trailing: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: statusColor.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: statusColor),
                                    ),
                                    child: Text(
                                      statusText,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: statusColor,
                                      ),
                                    ),
                                  ),
                                  onTap: () => _showRoundDetails(slot),
                                ),
                              );
                            },
                          ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text("Close"),
                ),
              ],
            );
          },
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    bool isAvailable = _isWithinScanWindow() || _totalQrCount == 0;
    double progressPercent =
        _totalQrCount > 0 ? _scannedCount / _totalQrCount : 0.0;
    Color statusColor;
    switch (_patrolStatus) {
      case "Success":
        statusColor = Colors.green;
        break;
      case "Missed":
        statusColor = Colors.red;
        break;
      default:
        statusColor = Colors.orange;
    }
    
    String scanWindowStatus = "";
    if (_scanWindowOpen != null && _scanWindowClose != null) {
      final now = DateTime.now();
      if (now.isBefore(_scanWindowOpen!)) {
        scanWindowStatus = "Opens at ${DateFormat('hh:mm a').format(_scanWindowOpen!)}";
      } else if (now.isAfter(_scanWindowClose!)) {
        scanWindowStatus = "Closed at ${DateFormat('hh:mm a').format(_scanWindowClose!)}";
      } else {
        scanWindowStatus = "Closes at ${DateFormat('hh:mm a').format(_scanWindowClose!)}";
      }
    }
    
    return Scaffold(
      backgroundColor: const Color(0xFF005C97),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text("Security Rounds",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        automaticallyImplyLeading: false,
        centerTitle: true,
        actions: [
          if (widget.isMaster)
            IconButton(
              icon: const Icon(Icons.assessment, color: Colors.white),
              onPressed: _showRoundReportDialog,
              tooltip: "View Reports",
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            onPressed: () {
              _refreshDebouncer?.cancel();
              _refreshDebouncer = Timer(const Duration(milliseconds: 500), () {
                _refreshPatrolStatus();
              });
            },
            tooltip: "Refresh Status",
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: () => Navigator.pushReplacementNamed(context, '/'),
            tooltip: "Logout",
          ),
        ],
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF005C97), Color(0xFF003366)],
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              _buildWhiteCard(
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          backgroundColor:
                              const Color(0xFF005C97).withValues(alpha: 0.1),
                          child: const Icon(Icons.person, color: Color(0xFF005C97)),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _campusName,
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "Guard: ${widget.guardName}",
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                        if (widget.isMaster)
                          IconButton(
                            icon: const Icon(Icons.settings_suggest, color: Color(0xFF005C97)),
                            onPressed: _showShiftManagementDialog,
                            tooltip: "Manage Shift Allocations",
                          ),
                      ],
                    ),
                    if (widget.isMaster)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.purple.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.purple, width: 1),
                        ),
                        child: const Text(
                          "ADMIN ACCESS",
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.purple,
                          ),
                        ),
                      ),
                    if (!widget.isMaster && scanWindowStatus.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _isWithinScanWindow() 
                              ? Colors.green.withValues(alpha: 0.1)
                              : Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _isWithinScanWindow() ? Colors.green : Colors.red, 
                            width: 1,
                          ),
                        ),
                        child: Text(
                          scanWindowStatus,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: _isWithinScanWindow() ? Colors.green : Colors.red,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _buildWhiteCard(
                child: Column(
                  children: [
                    StreamBuilder(
                      stream: Stream.periodic(
                          const Duration(seconds: 1), (count) => DateTime.now()),
                      builder: (context, snapshot) {
                        return Text(
                          DateFormat('hh:mm:ss a').format(DateTime.now()),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w300,
                            letterSpacing: 2,
                            color: Color(0xFF005C97),
                            fontFamily: 'monospace',
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    const SizedBox(height: 12),
                    Text(
                      _currentRound,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF005C97),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _scanWindowOpen != null && _scanWindowClose != null
                          ? "${DateFormat('hh:mm a').format(_scanWindowOpen!)} - ${DateFormat('hh:mm a').format(_scanWindowClose!)}"
                          : _nextRoundTime,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _nextRoundTime,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.black45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _buildWhiteCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          "Current Patrol",
                          style: TextStyle(fontSize: 14, color: Colors.black54),
                        ),
                        _isLoadingStatus
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF005C97),
                                ),
                              )
                            : Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: statusColor,
                                    width: 1,
                                  ),
                                ),
                                child: Text(
                                  _patrolStatus,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: statusColor,
                                  ),
                                ),
                              ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!_isLoadingStatus) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            "$_scannedCount/$_totalQrCount",
                            style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87),
                          ),
                          Text(
                            _patrolStatus == "Success" ? "Success" : "Scans",
                            style: const TextStyle(
                                fontSize: 14, color: Colors.black54),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          minHeight: 6,
                          value: progressPercent,
                          backgroundColor: Colors.grey[300],
                          valueColor:
                              AlwaysStoppedAnimation<Color>(statusColor),
                        ),
                      ),
                    ] else
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: CircularProgressIndicator(
                            color: Color(0xFF005C97),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
              Center(
                child: GestureDetector(
                  onTap: () async {
                    if (isAvailable) {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (c) => ScanningPage(
                            guardName: widget.guardName,
                            campusCode: _selectedCampusCode,
                            isMaster: widget.isMaster,
                          ),
                        ),
                      );
                      _refreshDebouncer?.cancel();
                      _refreshDebouncer = Timer(const Duration(milliseconds: 500), () {
                        _refreshPatrolStatus();
                      });
                    } else {
                      String message = widget.isMaster
                          ? "No more QR codes to scan."
                          : "SCAN WINDOW $scanWindowStatus";
                      ScaffoldMessenger.of(context).clearSnackBars();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Row(
                              children: [
                                const Icon(Icons.info, color: Colors.white),
                                const SizedBox(width: 8),
                                Expanded(child: Text(message)),
                              ],
                            ),
                            backgroundColor: Colors.red,
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      }
                    }
                  },
                  child: Container(
                    height: 120,
                    width: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: isAvailable
                            ? [const Color(0xFF005C97), const Color(0xFF4DA0FF)]
                            : [Colors.grey.shade700, Colors.grey.shade800],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: (isAvailable
                                  ? const Color(0xFF005C97)
                                  : Colors.grey)
                              .withValues(alpha: 0.4),
                          blurRadius: 15,
                          spreadRadius: 2,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Icon(
                      isAvailable
                          ? Icons.qr_code_scanner_rounded
                          : Icons.lock_clock,
                      size: 60,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                isAvailable ? "Tap to Scan QR" : "Scanning Not Available",
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWhiteCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFF005C97).withValues(alpha: 0.1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  // ================= SHIFT MANAGEMENT =================

  Future<void> _showShiftManagementDialog() async {
    final client = Supabase.instance.client;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text("Loading allocations..."),
            ],
          ),
        );
      },
    );

    try {
      // Fetch guards, active shifts, and existing allocations
      final usersRes = await client
          .from('security_users')
          .select('security_id, security_name, role')
          .eq('role', 'Guard');
      
      final shiftsRes = await client
          .from('shifts')
          .select('shift_id, shift_name, start_time, end_time');
          
      final allocsRes = await client
          .from('shift_allocations')
          .select('security_id, shift_id');

      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss loading

      final List<Map<String, dynamic>> guards = List<Map<String, dynamic>>.from(usersRes);
      final List<Map<String, dynamic>> shifts = List<Map<String, dynamic>>.from(shiftsRes);
      final List<Map<String, dynamic>> allocs = List<Map<String, dynamic>>.from(allocsRes);

      showDialog(
        context: context,
        builder: (BuildContext context) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: const Text("Edit Guard Shifts"),
                content: SizedBox(
                  width: double.maxFinite,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: guards.length,
                    itemBuilder: (context, index) {
                      final guard = guards[index];
                      final gId = guard['security_id'];
                      
                      // Find active allocations for this guard
                      final guardAllocations = allocs.where((a) => a['security_id'] == gId).toList();
                      final Set<String> assignedShiftIds = guardAllocations.map((a) => a['shift_id'].toString()).toSet();

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 2,
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          guard['security_name'] ?? 'Guard',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                        ),
                                        Text("ID: $gId", style: const TextStyle(color: Colors.black54, fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                  Text(
                                    assignedShiftIds.isEmpty ? "Unassigned" : "${assignedShiftIds.length} Shift(s)",
                                    style: TextStyle(
                                      color: assignedShiftIds.isEmpty ? Colors.red : Colors.green,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const Divider(height: 16),
                              const Text("Assign Shifts:", style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: shifts.map((s) {
                                  final sId = s['shift_id'].toString();
                                  final isChecked = assignedShiftIds.contains(sId);
                                  return FilterChip(
                                    label: Text("${s['shift_name']} (${s['start_time']} - ${s['end_time']})"),
                                    selected: isChecked,
                                    selectedColor: const Color(0xFF005C97).withOpacity(0.2),
                                    checkmarkColor: const Color(0xFF005C97),
                                    onSelected: (bool selected) async {
                                      final updatedShiftIds = Set<String>.from(assignedShiftIds);
                                      if (selected) {
                                        updatedShiftIds.add(sId);
                                      } else {
                                        updatedShiftIds.remove(sId);
                                      }

                                      // Update DB
                                      await _editGuardShifts(gId, updatedShiftIds.toList());

                                      // Update local state list
                                      allocs.removeWhere((a) => a['security_id'] == gId);
                                      for (var id in updatedShiftIds) {
                                        allocs.add({
                                          'security_id': gId,
                                          'shift_id': id,
                                        });
                                      }

                                      setDialogState(() {});
                                    },
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text("Done"),
                  ),
                ],
              );
            }
          );
        },
      );
    } catch (e) {
      if (mounted) Navigator.of(context).pop(); // dismiss loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error fetching shift config: $e")),
      );
    }
  }

  Future<void> _editGuardShifts(String securityId, List<String> shiftIds) async {
    final client = Supabase.instance.client;
    try {
      // First delete any previous allocations for this guard
      await client
          .from('shift_allocations')
          .delete()
          .eq('security_id', securityId);

      if (shiftIds.isNotEmpty) {
        // Insert new allocations for all checked shifts
        final List<Map<String, dynamic>> inserts = shiftIds.map((sId) => {
          'security_id': securityId,
          'shift_id': sId,
          'allocation_date': '2099-12-31',
        }).toList();

        await client.from('shift_allocations').insert(inserts);
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Shift allocations saved successfully!"),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Failed to update shifts: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}