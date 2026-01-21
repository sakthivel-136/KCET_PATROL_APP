import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:screenshot/screenshot.dart';
import 'dart:async';
import 'dart:io';

class ScanningPage extends StatefulWidget {
  final String guardName;
  final String factoryCode;
  const ScanningPage({super.key, required this.guardName, required this.factoryCode});

  @override
  State<ScanningPage> createState() => _ScanningPageState();
}

class _ScanningPageState extends State<ScanningPage> {
  late final MobileScannerController ctrl;
  
  List<Map<String, dynamic>> _checkpoints = [];
  bool _loading = true;
  bool _isProcessing = false; 
  String? _activeQrId; 
  int _overlayTimer = 0;

  @override
  void initState() {
    super.initState();
    
    final int hour = DateTime.now().hour;
    final bool isNightTime = (hour >= 18 || hour < 6);

    ctrl = MobileScannerController(
      torchEnabled: isNightTime, 
    );

    _fetchCheckpoints();
  }

  Future<void> _fetchCheckpoints() async {
    try {
      final data = await Supabase.instance.client
          .from('qr')
          .select()
          .eq('factory_code', widget.factoryCode);
      
      setState(() {
        _checkpoints = data.map((e) => {
          ...e, 
          'completed': false, 
          'timer': 0, 
          'scanned_once': false,
          'waiting_time': e['waiting_time'] ?? 15
        }).toList();
        _loading = false;
      });
    } catch (e) {
      debugPrint("Fetch error: $e");
    }
  }

  void _triggerScanError(String message, Color color) async {
    setState(() => _isProcessing = true);
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: color,
        duration: const Duration(seconds: 1),
      )
    );
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _isProcessing = false);
  }

  void _onDetect(BarcodeCapture cap) async {
    if (_isProcessing) return;
    
    final code = cap.barcodes.first.rawValue;
    if (code == null) return;

    final checkpointIndex = _checkpoints.indexWhere((p) => p['qr_id'].toString() == code);
    
    if (checkpointIndex == -1) {
      _triggerScanError("UNKNOWN QR CODE", Colors.orange);
      return;
    }

    var p = _checkpoints[checkpointIndex];

    if (p['completed']) {
      _triggerScanError("ALREADY SCANNED", Colors.blueGrey);
      return;
    }

    if (_activeQrId != null && _activeQrId != code) {
      _triggerScanError("FINISH ACTIVE QR FIRST", Colors.red);
      return;
    }

    if (!p['scanned_once']) {
      setState(() { 
        _isProcessing = true;
        _activeQrId = code; 
        p['scanned_once'] = true; 
        p['timer'] = p['waiting_time']; 
        _overlayTimer = p['waiting_time'];
        p['start_time'] = DateTime.now(); 
      });
      _startTimer(p);
      Future.delayed(const Duration(seconds: 1), () => setState(() => _isProcessing = false));
    } 
    else if (p['timer'] == 0) {
      setState(() => _isProcessing = true);
      try {
        Position pos = await Geolocator.getCurrentPosition();
        await Supabase.instance.client.from('scanning_details').insert({
          'guard_name': widget.guardName,
          'qr_id': p['qr_id'],
          'qr_name': p['qr_name'],
          'lat': pos.latitude,
          'log': pos.longitude,
          'factory_code': widget.factoryCode,
          'scan_time': DateTime.now().toIso8601String()
        });
        setState(() { 
          p['completed'] = true; 
          _activeQrId = null; 
          _overlayTimer = 0; 
        });
        _checkAutoClose();
        await Future.delayed(const Duration(seconds: 2));
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }
  }

  void _startTimer(Map<String, dynamic> p) {
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      int diff = p['waiting_time'] - DateTime.now().difference(p['start_time']).inSeconds;
      if (diff <= 0) {
        setState(() { p['timer'] = 0; _overlayTimer = 0; });
        HapticFeedback.vibrate(); 
        t.cancel();
      } else { 
        setState(() { p['timer'] = diff; _overlayTimer = diff; }); 
      }
    });
  }

  void _checkAutoClose() {
    if (_checkpoints.every((p) => p['completed'])) {
      ctrl.stop();
      showDialog(
        context: context, 
        barrierDismissible: false,
        builder: (c) => const AlertDialog(
          title: Text("Patrol Finished!"), 
          content: Text("All points verified. App will close.")
        )
      );
      Future.delayed(const Duration(seconds: 2), () => exit(0));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("QR Patrol Scan")),
      // REPLACED SOS WITH FLASH BUTTON
      floatingActionButton: ValueListenableBuilder(
        valueListenable: ctrl.torchState,
        builder: (context, state, child) {
          return FloatingActionButton.large(
            onPressed: () => ctrl.toggleTorch(),
            backgroundColor: state == TorchState.on ? Colors.yellow[700] : Colors.grey[800],
            child: Icon(
              state == TorchState.on ? Icons.flash_on : Icons.flash_off,
              color: Colors.white,
              size: 40,
            ),
          );
        },
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : Column(
        children: [
          Stack(
            children: [
              SizedBox(height: 250, child: MobileScanner(controller: ctrl, onDetect: _onDetect)),
              if (_overlayTimer > 0)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    child: Center(
                      child: Text("WAIT\n$_overlayTimer", textAlign: TextAlign.center, 
                        style: const TextStyle(color: Colors.white, fontSize: 70, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              itemCount: _checkpoints.length,
              itemBuilder: (c, i) {
                final p = _checkpoints[i];
                
                // Determine Box Color based on Scan Status
                Color boxColor = Colors.white;
                if (p['completed']) {
                  boxColor = Colors.green;
                } else if (p['scanned_once']) {
                  boxColor = Colors.yellow;
                }

                return AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: boxColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 5, spreadRadius: 1)
                    ]
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        p['qr_name'].toString().toUpperCase(),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: p['completed'] || p['scanned_once'] ? Colors.black : Colors.black87,
                        ),
                      ),
                      if (p['timer'] > 0)
                        Text("WAIT: ${p['timer']}s", style: const TextStyle(fontWeight: FontWeight.bold))
                      else if (p['completed'])
                        const Icon(Icons.check_circle, color: Colors.white)
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

  @override
  void dispose() { 
    ctrl.dispose(); 
    super.dispose(); 
  }
}