import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PatrolRound {
  final DateTime time;
  final String label;
  final int round;

  PatrolRound(this.time, this.label, this.round);
}

class DbPatrolRound {
  final int roundNumber;
  final String startTime;
  final String endTime;

  DbPatrolRound({required this.roundNumber, required this.startTime, required this.endTime});

  factory DbPatrolRound.fromJson(Map<String, dynamic> json) {
    int rNum = int.tryParse(json['round_number']?.toString() ?? '0') ?? 0;
    
    String safeTime(dynamic val) {
      if (val == null) return "00:00";
      String s = val.toString().trim();
      if (s.isEmpty) return "00:00";
      if (s.contains(':')) {
        final p = s.split(':');
        return "${p[0].padLeft(2, '0')}:${p[1].padLeft(2, '0')}";
      }
      return s.length >= 5 ? s.substring(0, 5) : s;
    }

    return DbPatrolRound(
      roundNumber: rNum,
      startTime: safeTime(json['start_time']),
      endTime: safeTime(json['end_time']),
    );
  }
}

List<DbPatrolRound> _cachedDbRounds = [];

Future<void> loadCachedRounds() async {
  final prefs = await SharedPreferences.getInstance();
  final jsonStr = prefs.getString('cached_rounds');
  if (jsonStr != null) {
    final List<dynamic> list = jsonDecode(jsonStr);
    _cachedDbRounds = list.map((e) => DbPatrolRound.fromJson(e)).toList();
    _cachedDbRounds.sort((a, b) => a.roundNumber.compareTo(b.roundNumber));
  }
}

List<PatrolRound> buildPatrolRounds(DateTime now) {
  final base = DateTime(now.year, now.month, now.day);
  
  if (_cachedDbRounds.isNotEmpty) {
    return _cachedDbRounds.map((r) {
      final start = _parseTime(base, r.startTime);
      final end = _parseTime(base, r.endTime);
      
      final startLbl = DateFormat('h:mm a').format(start);
      final endLbl = DateFormat('h:mm a').format(end);
      
      return PatrolRound(
        start,
        '$startLbl to $endLbl',
        r.roundNumber
      );
    }).toList();
  }

  // Fallback legacy method if DB is empty
  final cycleStart = base;
  final slots = List<DateTime>.generate(
    12,
    (index) => DateTime(cycleStart.year, cycleStart.month, cycleStart.day, index * 2, 0),
  );

  return List<PatrolRound>.generate(
    slots.length,
    (index) => PatrolRound(
      slots[index],
      DateFormat('h:mm a').format(slots[index]),
      index + 1,
    ),
  );
}

DateTime _parseTime(DateTime base, String timeStr) {
  final parts = timeStr.split(':');
  return DateTime(base.year, base.month, base.day, int.parse(parts[0]), int.parse(parts[1]));
}

Map<String, dynamic> getCurrentPatrolRound(DateTime now) {
  // If no cache, fall back to legacy behavior
  if (_cachedDbRounds.isEmpty) {
    return _getLegacyPatrolRound(now);
  }

  final base = DateTime(now.year, now.month, now.day);
  bool foundActive = false;
  DbPatrolRound? currentDbRound;
  DateTime? activeStart;
  DateTime? activeEnd;
  
  // Find active round
  for (var r in _cachedDbRounds) {
     var start = _parseTime(base, r.startTime);
     var end = _parseTime(base, r.endTime);
     
     // Handle cross-midnight rounds
     if (end.isBefore(start)) {
       if (now.hour < end.hour) {
           start = start.subtract(const Duration(days: 1));
       } else {
           end = end.add(const Duration(days: 1));
       }
     }
     
     if (!now.isBefore(start) && now.isBefore(end)) {
        foundActive = true;
        currentDbRound = r;
        activeStart = start;
        activeEnd = end;
        break;
     }
  }

  // If no round is currently active, find the NEXT upcoming round
  if (!foundActive) {
    for (var r in _cachedDbRounds) {
       var start = _parseTime(base, r.startTime);
       var end = _parseTime(base, r.endTime);
       if (end.isBefore(start)) {
         if (now.hour < end.hour) start = start.subtract(const Duration(days: 1));
         else end = end.add(const Duration(days: 1));
       }
       
       if (now.isBefore(start)) {
         currentDbRound = r;
         activeStart = start;
         activeEnd = end;
         break;
       }
    }
    
    // If still null, it must be the first round of the next day
    if (currentDbRound == null && _cachedDbRounds.isNotEmpty) {
      currentDbRound = _cachedDbRounds.first;
      var start = _parseTime(base.add(const Duration(days: 1)), currentDbRound.startTime);
      var end = _parseTime(base.add(const Duration(days: 1)), currentDbRound.endTime);
      if (end.isBefore(start)) end = end.add(const Duration(days: 1));
      
      activeStart = start;
      activeEnd = end;
    }
  }

  // Next Round calc
  int currentIndex = _cachedDbRounds.indexOf(currentDbRound!);
  int nextIndex = (currentIndex + 1) % _cachedDbRounds.length;
  DbPatrolRound nextDbRound = _cachedDbRounds[nextIndex];
  DateTime nextStart = _parseTime(
    nextIndex <= currentIndex ? base.add(const Duration(days: 1)) : base, 
    nextDbRound.startTime
  );

  final startLbl = DateFormat('h:mm a').format(activeStart!);
  final endLbl = DateFormat('h:mm a').format(activeEnd!);
  final nStartLbl = DateFormat('h:mm a').format(nextStart);
  
  return {
    'current': PatrolRound(activeStart, '$startLbl to $endLbl', currentDbRound.roundNumber),
    'next': PatrolRound(nextStart, nStartLbl, nextDbRound.roundNumber),
    'currentRoundTime': activeStart,
    'nextRoundTime': nextStart,
    'currentRoundLabel': '${currentDbRound.startTime} - ${currentDbRound.endTime}',
    'currentRoundNumber': currentDbRound.roundNumber,
    'scanWindowOpen': activeStart,
    'scanWindowClose': activeEnd,
    'isActive': foundActive,
  };
}

Map<String, dynamic> _getLegacyPatrolRound(DateTime now) {
  final todayRounds = buildPatrolRounds(now);
  final tomorrowRounds = buildPatrolRounds(now.add(const Duration(days: 1)));
  final allRounds = [...todayRounds, ...tomorrowRounds];
  
  PatrolRound current = allRounds.first;
  int currentIndex = 0;
  bool foundActive = false;

  DateTime getScanWindowStart(DateTime roundStart) => roundStart.add(const Duration(minutes: 45));
  DateTime getScanWindowEnd(DateTime roundStart) => roundStart.add(const Duration(hours: 1, minutes: 30));

  for (var i = 0; i < allRounds.length; i++) {
    final start = getScanWindowStart(allRounds[i].time);
    final end = getScanWindowEnd(allRounds[i].time);
    if (!now.isBefore(start) && now.isBefore(end)) {
      current = allRounds[i];
      currentIndex = i;
      foundActive = true;
      break;
    }
  }

  if (!foundActive) {
    for (var i = 0; i < allRounds.length; i++) {
      final start = getScanWindowStart(allRounds[i].time);
      if (now.isBefore(start)) {
        current = allRounds[i];
        currentIndex = i;
        break;
      }
      current = allRounds[i];
      currentIndex = i;
    }
  }

  final next = currentIndex < allRounds.length - 1
      ? allRounds[currentIndex + 1]
      : allRounds.first;

  return {
    'current': current,
    'next': next,
    'currentRoundTime': current.time,
    'nextRoundTime': next.time,
    'currentRoundLabel': current.label,
    'currentRoundNumber': current.round,
    'scanWindowOpen': getScanWindowStart(current.time),
    'scanWindowClose': getScanWindowEnd(current.time),
    'isActive': foundActive,
  };
}

DateTime getNearestPatrolRoundStart(DateTime now) {
  final info = getCurrentPatrolRound(now);
  return info['currentRoundTime'] as DateTime;
}

DateTime getScanWindowStart(DateTime roundStart) {
  return roundStart.add(const Duration(minutes: 45));
}
