import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'scan_page.dart';

class HomePage extends StatefulWidget {
  final String guardName;
  final String factoryCode;
  final bool isMaster;
  final bool canScan;
  const HomePage(
      {super.key,
      required this.guardName,
      required this.factoryCode,
      required this.isMaster,
      required this.canScan});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _factoryName = "Loading...";
  String _selectedFactoryCode = "";
  int _totalQrCount = 0;
  int _scannedCount = 0;
  bool _isLoadingStatus = true;
  String _currentRound = "Calculating...";
  String _nextRoundTime = "";
  List<Map<String, dynamic>> _factories = [];
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
    _selectedFactoryCode = widget.factoryCode;
    _fetchInitialData();
  }

  @override
  void dispose() {
    _refreshDebouncer?.cancel();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    await _fetchFactories();
    await _fetchFactoryName();
    await _refreshPatrolStatus();
    _updateRoundInfo();
    Timer.periodic(const Duration(minutes: 1), (timer) {
      if (mounted) _updateRoundInfo();
    });
  }

  Future<void> _fetchFactories() async {
    try {
      final data = await Supabase.instance.client
          .from('factories')
          .select('factory_code, factory_name');
      if (mounted) {
        setState(() {
          _factories = List<Map<String, dynamic>>.from(data);
        });
      }
    } catch (e) {
      debugPrint("Error fetching factories: $e");
    }
  }

  Future<void> _fetchFactoryName() async {
    try {
      if (_selectedFactoryCode == "ADMIN") {
        if (mounted) {
          setState(() => _factoryName = "Administrator");
        }
        return;
      }

      final data = await Supabase.instance.client
          .from('factories')
          .select('factory_name')
          .eq('factory_code', _selectedFactoryCode)
          .single();
      if (mounted) {
        setState(() => _factoryName = data['factory_name']);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _factoryName = "Unknown Factory");
      }
    }
  }

  Map<String, dynamic> _getCurrentRoundSlot() {
    final now = DateTime.now();

    final List<Map<String, dynamic>> roundSlots = [
      {'hour': 0, 'minute': 0, 'round': 1, 'label': '12:00 AM'},
      {'hour': 0, 'minute': 30, 'round': 2, 'label': '12:30 AM'},
      {'hour': 1, 'minute': 0, 'round': 3, 'label': '1:00 AM'},
      {'hour': 1, 'minute': 30, 'round': 4, 'label': '1:30 AM'},
      {'hour': 2, 'minute': 0, 'round': 5, 'label': '2:00 AM'},
      {'hour': 2, 'minute': 30, 'round': 6, 'label': '2:30 AM'},
      {'hour': 3, 'minute': 0, 'round': 7, 'label': '3:00 AM'},
      {'hour': 3, 'minute': 30, 'round': 8, 'label': '3:30 AM'},
      {'hour': 4, 'minute': 0, 'round': 9, 'label': '4:00 AM'},
      {'hour': 4, 'minute': 30, 'round': 10, 'label': '4:30 AM'},
      {'hour': 5, 'minute': 0, 'round': 11, 'label': '5:00 AM'},
      {'hour': 5, 'minute': 30, 'round': 12, 'label': '5:30 AM'},
      {'hour': 6, 'minute': 0, 'round': 13, 'label': '6:00 AM'},
      {'hour': 7, 'minute': 0, 'round': 14, 'label': '7:00 AM'},
      {'hour': 8, 'minute': 0, 'round': 15, 'label': '8:00 AM'},
      {'hour': 9, 'minute': 0, 'round': 16, 'label': '9:00 AM'},
      {'hour': 10, 'minute': 0, 'round': 17, 'label': '10:00 AM'},
      {'hour': 11, 'minute': 0, 'round': 18, 'label': '11:00 AM'},
      {'hour': 12, 'minute': 0, 'round': 19, 'label': '12:00 PM'},
      {'hour': 13, 'minute': 0, 'round': 20, 'label': '1:00 PM'},
      {'hour': 14, 'minute': 0, 'round': 21, 'label': '2:00 PM'},
      {'hour': 15, 'minute': 0, 'round': 22, 'label': '3:00 PM'},
      {'hour': 16, 'minute': 0, 'round': 23, 'label': '4:00 PM'},
      {'hour': 17, 'minute': 0, 'round': 24, 'label': '5:00 PM'},
      {'hour': 18, 'minute': 0, 'round': 25, 'label': '6:00 PM'},
      {'hour': 19, 'minute': 0, 'round': 26, 'label': '7:00 PM'},
      {'hour': 20, 'minute': 0, 'round': 27, 'label': '8:00 PM'},
      {'hour': 21, 'minute': 0, 'round': 28, 'label': '9:00 PM'},
      {'hour': 21, 'minute': 30, 'round': 29, 'label': '9:30 PM'},
      {'hour': 22, 'minute': 0, 'round': 30, 'label': '10:00 PM'},
      {'hour': 22, 'minute': 30, 'round': 31, 'label': '10:30 PM'},
      {'hour': 23, 'minute': 0, 'round': 32, 'label': '11:00 PM'},
      {'hour': 23, 'minute': 30, 'round': 33, 'label': '11:30 PM'},
    ];

    final cycleDate = (now.hour < 6) ? now.subtract(const Duration(days: 1)) : now;
    final patrolDay = DateTime(cycleDate.year, cycleDate.month, cycleDate.day);

    List<Map<String, dynamic>> timeline = [];
    for (var slot in roundSlots) {
      timeline.add({
        'slot': slot,
        'time': DateTime(patrolDay.year, patrolDay.month, patrolDay.day, slot['hour'], slot['minute'])
      });
    }

    // *** DEBUG: Print current time for debugging ***
    debugPrint("Current time: ${DateFormat('hh:mm a').format(now)}");

    // *** REVISED LOGIC: More robust round detection ***
    Map<String, dynamic> current = timeline.first;
    int index = 0;
    bool foundActiveRound = false;
    
    // First, try to find a round whose scan window is currently active
    for (int i = 0; i < timeline.length; i++) {
      final roundTime = timeline[i]['time'] as DateTime;
      final scanWindowStart = roundTime;
      final scanWindowEnd = roundTime.add(const Duration(minutes: 25));
      
      // *** DEBUG: Print each round's window ***
      debugPrint("Round ${roundSlots[i]['round']}: ${DateFormat('hh:mm a').format(scanWindowStart)} to ${DateFormat('hh:mm a').format(scanWindowEnd)}");
      
      if (now.isAfter(scanWindowStart.subtract(const Duration(seconds: 1))) && 
          now.isBefore(scanWindowEnd.add(const Duration(seconds: 1)))) {
        current = timeline[i];
        index = i;
        foundActiveRound = true;
        debugPrint("Found active round: ${roundSlots[i]['round']}");
        break;
      }
    }
    
    // If no active scan window found, find the most recent round
    if (!foundActiveRound) {
      debugPrint("No active round found, finding most recent");
      for (int i = 0; i < timeline.length; i++) {
        final roundTime = timeline[i]['time'] as DateTime;
        if (!now.isBefore(roundTime)) {
          current = timeline[i];
          index = i;
        }
      }
    }

    Map<String, dynamic> next =
        index < timeline.length - 1 ? timeline[index + 1] : timeline.first;

    return {
      'current': current['slot'],
      'next': next['slot'],
      'currentRoundTime': current['time'],
      'nextRoundTime': next['time'],
    };
  }

  void _updateRoundInfo() {
    final roundInfo = _getCurrentRoundSlot();
    final currentSlot = roundInfo['current'] as Map<String, dynamic>;
    final nextSlot = roundInfo['next'] as Map<String, dynamic>;
    final roundTime = roundInfo['currentRoundTime'] as DateTime;
    
    // Calculate scan window times
    final windowOpen = roundTime;
    final windowClose = roundTime.add(const Duration(minutes: 25));
    
    // *** DEBUG: Print window info ***
    debugPrint("Scan window: ${DateFormat('hh:mm a').format(windowOpen)} to ${DateFormat('hh:mm a').format(windowClose)}");
    
    if (mounted) {
      setState(() {
        _currentRound = "Round ${currentSlot['round']}";
        _nextRoundTime = "Next: ${nextSlot['label']}";
        _currentRoundStart = roundTime;
        _scanWindowOpen = windowOpen;
        _scanWindowClose = windowClose;
      });
    }
  }

  bool _isWithinScanWindow() {
    final now = DateTime.now();
    
    if (_currentRoundStart == null || _scanWindowOpen == null || _scanWindowClose == null) {
      debugPrint("Scan window not set");
      return false;
    }
    
    bool isWithin = now.isAfter(_scanWindowOpen!) && now.isBefore(_scanWindowClose!);
    debugPrint("Is within scan window: $isWithin");
    debugPrint("Current: ${DateFormat('hh:mm:ss a').format(now)}");
    debugPrint("Window: ${DateFormat('hh:mm:ss a').format(_scanWindowOpen!)} to ${DateFormat('hh:mm:ss a').format(_scanWindowClose!)}");
    
    return isWithin;
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

    final roundEnd = roundStart.add(const Duration(minutes: 25));
    bool isScanWindowClosed = now.isAfter(roundEnd);
    
    try {
      // *** CRITICAL: Always filter by factory_code for independent factory operations ***
      final totalRes = await client
          .from('qr')
          .select('qr_id')
          .eq('factory_code', _selectedFactoryCode)
          .eq('status', 'active');
      
      final scannedRes = await client
          .from('scanning_details')
          .select('qr_id, status')
          .eq('factory_code', _selectedFactoryCode)
          .eq('round_slot', roundStart.toIso8601String());

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

  void _showFactorySelectionDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Select Factory"),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _factories.length,
              itemBuilder: (BuildContext context, int index) {
                final factory = _factories[index];
                return ListTile(
                  title: Text(factory['factory_name']),
                  subtitle: Text("Code: ${factory['factory_code']}"),
                  onTap: () {
                    setState(() {
                      _selectedFactoryCode = factory['factory_code'];
                      _factoryName = factory['factory_name'];
                      // Reset counts when switching factories
                      _totalQrCount = 0;
                      _scannedCount = 0;
                      _patrolStatus = "In Progress";
                    });
                    Navigator.of(context).pop();
                    _refreshPatrolStatus();
                  },
                  trailing: _selectedFactoryCode == factory['factory_code']
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
      final cycleDate = (now.hour < 6) ? now.subtract(const Duration(days: 1)) : now;
      final reportDate = DateTime(cycleDate.year, cycleDate.month, cycleDate.day);
      final client = Supabase.instance.client;
      List<Map<String, dynamic>> slots = [];
      final List<Map<String, dynamic>> roundSlots = [
        {'hour': 0, 'minute': 0, 'round': 1, 'label': '12:00 AM'},
        {'hour': 0, 'minute': 30, 'round': 2, 'label': '12:30 AM'},
        {'hour': 1, 'minute': 0, 'round': 3, 'label': '1:00 AM'},
        {'hour': 1, 'minute': 30, 'round': 4, 'label': '1:30 AM'},
        {'hour': 2, 'minute': 0, 'round': 5, 'label': '2:00 AM'},
        {'hour': 2, 'minute': 30, 'round': 6, 'label': '2:30 AM'},
        {'hour': 3, 'minute': 0, 'round': 7, 'label': '3:00 AM'},
        {'hour': 3, 'minute': 30, 'round': 8, 'label': '3:30 AM'},
        {'hour': 4, 'minute': 0, 'round': 9, 'label': '4:00 AM'},
        {'hour': 4, 'minute': 30, 'round': 10, 'label': '4:30 AM'},
        {'hour': 5, 'minute': 0, 'round': 11, 'label': '5:00 AM'},
        {'hour': 5, 'minute': 30, 'round': 12, 'label': '5:30 AM'},
        {'hour': 6, 'minute': 0, 'round': 13, 'label': '6:00 AM'},
        {'hour': 7, 'minute': 0, 'round': 14, 'label': '7:00 AM'},
        {'hour': 8, 'minute': 0, 'round': 15, 'label': '8:00 AM'},
        {'hour': 9, 'minute': 0, 'round': 16, 'label': '9:00 AM'},
        {'hour': 10, 'minute': 0, 'round': 17, 'label': '10:00 AM'},
        {'hour': 11, 'minute': 0, 'round': 18, 'label': '11:00 AM'},
        {'hour': 12, 'minute': 0, 'round': 19, 'label': '12:00 PM'},
        {'hour': 13, 'minute': 0, 'round': 20, 'label': '1:00 PM'},
        {'hour': 14, 'minute': 0, 'round': 21, 'label': '2:00 PM'},
        {'hour': 15, 'minute': 0, 'round': 22, 'label': '3:00 PM'},
        {'hour': 16, 'minute': 0, 'round': 23, 'label': '4:00 PM'},
        {'hour': 17, 'minute': 0, 'round': 24, 'label': '5:00 PM'},
        {'hour': 18, 'minute': 0, 'round': 25, 'label': '6:00 PM'},
        {'hour': 19, 'minute': 0, 'round': 26, 'label': '7:00 PM'},
        {'hour': 20, 'minute': 0, 'round': 27, 'label': '8:00 PM'},
        {'hour': 21, 'minute': 0, 'round': 28, 'label': '9:00 PM'},
        {'hour': 21, 'minute': 30, 'round': 29, 'label': '9:30 PM'},
        {'hour': 22, 'minute': 0, 'round': 30, 'label': '10:00 PM'},
        {'hour': 22, 'minute': 30, 'round': 31, 'label': '10:30 PM'},
        {'hour': 23, 'minute': 0, 'round': 32, 'label': '11:00 PM'},
        {'hour': 23, 'minute': 30, 'round': 33, 'label': '11:30 PM'},
      ];

      List<Map<String, dynamic>> timeline = [];
      for (var slot in roundSlots) {
        timeline.add({
          'slot': slot,
          'time': DateTime(reportDate.year, reportDate.month, reportDate.day, slot['hour'], slot['minute'])
        });
      }

      int currentRoundIndex = 0;
      bool foundActiveRound = false;
      
      // First, try to find a round whose scan window is currently active
      for (int i = 0; i < timeline.length; i++) {
        final roundTime = timeline[i]['time'] as DateTime;
        final scanWindowStart = roundTime;
        final scanWindowEnd = roundTime.add(const Duration(minutes: 25));
        
        if (now.isAfter(scanWindowStart.subtract(const Duration(seconds: 1))) && 
            now.isBefore(scanWindowEnd.add(const Duration(seconds: 1)))) {
          currentRoundIndex = i;
          foundActiveRound = true;
          break;
        }
      }
      
      // If no active scan window found, find the most recent round
      if (!foundActiveRound) {
        for (int i = 0; i < timeline.length; i++) {
          final roundTime = timeline[i]['time'] as DateTime;
          if (!now.isBefore(roundTime)) {
            currentRoundIndex = i;
          }
        }
      }

      // *** CRITICAL: Fetch QR data specific to this factory ***
      final qrData = await client
          .from('qr')
          .select('qr_id')
          .eq('factory_code', _selectedFactoryCode)
          .eq('status', 'active');
      int totalQrCount = qrData.length;

      if (totalQrCount == 0) {
        for (var slot in timeline) {
          slots.add({
            'time': slot['time'],
            'label': slot['slot']['label'],
            'round': 'Round ${slot['slot']['round']}',
            'status': 'no_qr'
          });
        }
      } else {
        for (int i = 0; i < timeline.length; i++) {
          final slot = timeline[i];
          final slotTime = slot['time'] as DateTime;
          
          String status;
          List<dynamic> scannedData = [];
          
          if (i < currentRoundIndex) {
            scannedData = await client
                .from('scanning_details')
                .select('qr_id, status, guard_name')
                .eq('factory_code', _selectedFactoryCode)
                .eq('round_slot', slotTime.toIso8601String());
            
            int successfulScanCount = 0;
            for (var scan in scannedData) {
              if (_isSuccessStatus(scan['status'])) {
                successfulScanCount++;
              }
            }
            
            if (successfulScanCount >= totalQrCount) {
              status = 'success';
            } else {
              status = 'missed';
            }
          } else if (i == currentRoundIndex) {
            status = 'current';
          } else {
            status = 'future';
          }
          
          slots.add({
            'time': slotTime,
            'label': slot['slot']['label'],
            'round': 'Round ${slot['slot']['round']}',
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
          .eq('factory_code', _selectedFactoryCode)
          .eq('status', 'active');
      final scanDetails = await client
          .from('scanning_details')
          .select('qr_id, qr_name, guard_name, scan_time, status')
          .eq('factory_code', _selectedFactoryCode)
          .eq('round_slot', slotTime.toIso8601String());
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
                    ? const Center(child: Text("No QR codes assigned to this factory"))
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
                            final scanWindowStart = slotTime;
                            final scanWindowEnd = slotTime.add(const Duration(minutes: 25));

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
              title: Text("Patrol Rounds Report - $_factoryName"),
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
    bool isAvailable = widget.isMaster ||
        (widget.canScan && _isWithinScanWindow() && (_scannedCount < _totalQrCount)) ||
        _totalQrCount == 0;
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
                                _factoryName,
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
                            icon: const Icon(Icons.factory, color: Color(0xFF005C97)),
                            onPressed: _showFactorySelectionDialog,
                            tooltip: "Select Factory",
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _currentRound,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF005C97),
                          ),
                        ),
                        Text(
                          "Now: ${DateFormat('hh:mm a').format(DateTime.now())}",
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                        Text(
                          _nextRoundTime,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black54,
                          ),
                        ),
                      ],
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
                            factoryCode: _selectedFactoryCode,
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
}