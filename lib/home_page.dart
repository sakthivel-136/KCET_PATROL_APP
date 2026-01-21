import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'scan_page.dart';

class HomePage extends StatefulWidget {
  final String guardName;
  final String factoryCode;
  final bool isMaster;
  const HomePage({super.key, required this.guardName, required this.factoryCode, required this.isMaster});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _factoryName = "Loading...";

  @override
  void initState() {
    super.initState();
    _fetchFactoryName();
  }

  Future<void> _fetchFactoryName() async {
    final data = await Supabase.instance.client
        .from('factories')
        .select('factory_name')
        .eq('factory_code', widget.factoryCode)
        .single();
    if (mounted) setState(() => _factoryName = data['factory_name']);
  }

  Future<bool> _checkAvailability() async {
    final now = DateTime.now();
    final h = now.hour;
    DateTime windowStart = (h >= 22 || h < 6) 
        ? DateTime(now.year, now.month, now.day, h, (now.minute < 30) ? 0 : 30)
        : DateTime(now.year, now.month, now.day, h);

    final result = await Supabase.instance.client
        .from('scanning_details')
        .select()
        .eq('factory_code', widget.factoryCode)
        .gte('scan_time', windowStart.toIso8601String())
        .limit(1);
    return result.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Dashboard"), automaticallyImplyLeading: false),
      body: FutureBuilder<bool>(
        future: _checkAvailability(),
        builder: (context, snapshot) {
          bool isAvailable = snapshot.data ?? false;
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_factoryName, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                Text("User: ${widget.guardName}"),
                const SizedBox(height: 30),
                StreamBuilder(
                  stream: Stream.periodic(const Duration(seconds: 1)),
                  builder: (c, s) => Text(DateFormat('hh:mm:ss a').format(DateTime.now()), style: const TextStyle(fontSize: 40)),
                ),
                const SizedBox(height: 50),
                GestureDetector(
                  onTap: () {
                    if (isAvailable) {
                      Navigator.push(context, MaterialPageRoute(builder: (c) => ScanningPage(guardName: widget.guardName, factoryCode: widget.factoryCode)));
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("ALREADY SCANNED FOR THIS SLOT")));
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(50),
                    decoration: BoxDecoration(color: isAvailable ? Colors.green : Colors.red, shape: BoxShape.circle),
                    child: const Icon(Icons.qr_code_scanner, size: 80, color: Colors.white),
                  ),
                ),
              ],
            ),
          );
        }
      ),
    );
  }
}