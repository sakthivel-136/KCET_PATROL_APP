import 'package:intl/intl.dart';

class PatrolRound {
  final DateTime time;
  final String label;
  final int round;

  PatrolRound(this.time, this.label, this.round);
}

List<DateTime> _buildDaySlots(DateTime date) {
  final base = DateTime(date.year, date.month, date.day);
  return List<DateTime>.generate(
    16,
    (index) => DateTime(base.year, base.month, base.day, 6 + index),
  );
}

List<DateTime> _buildNightSlots(DateTime date) {
  final base = DateTime(date.year, date.month, date.day);
  return [
    DateTime(base.year, base.month, base.day, 22, 0),
    DateTime(base.year, base.month, base.day, 22, 30),
    DateTime(base.year, base.month, base.day, 23, 0),
    DateTime(base.year, base.month, base.day, 23, 30),
  ];
}

List<DateTime> _buildEarlyMorningSlots(DateTime date) {
  final base = DateTime(date.year, date.month, date.day);
  return List<DateTime>.generate(
    12,
    (index) => DateTime(base.year, base.month, base.day, index ~/ 2, (index % 2) * 30),
  );
}

List<PatrolRound> buildPatrolRounds(DateTime now) {
  final localDay = DateTime(now.year, now.month, now.day);
  final cycleStart = now.hour < 6 ? localDay.subtract(const Duration(days: 1)) : localDay;
  final cycleEndDay = cycleStart.add(const Duration(days: 1));

  final slots = <DateTime>[];
  slots.addAll(_buildDaySlots(cycleStart));
  slots.addAll(_buildNightSlots(cycleStart));
  slots.addAll(_buildEarlyMorningSlots(cycleEndDay));
  slots.sort();

  return List<PatrolRound>.generate(
    slots.length,
    (index) => PatrolRound(
      slots[index],
      DateFormat('h:mm a').format(slots[index]),
      index + 1,
    ),
  );
}

bool _isHourlySlot(DateTime time) {
  return time.minute == 0 && time.hour >= 6 && time.hour <= 21;
}

DateTime getScanWindowStart(DateTime roundStart) {
  return roundStart.subtract(const Duration(minutes: 5));
}

DateTime getScanWindowEnd(DateTime roundStart) {
  return roundStart.add(const Duration(minutes: 15));
}

bool isWithinPatrolScanWindow(DateTime now, DateTime roundStart) {
  final start = getScanWindowStart(roundStart);
  final end = getScanWindowEnd(roundStart);
  return !now.isBefore(start) && now.isBefore(end);
}

Map<String, dynamic> getCurrentPatrolRound(DateTime now) {
  final rounds = buildPatrolRounds(now);
  PatrolRound current = rounds.first;
  int currentIndex = 0;
  bool foundActive = false;

  for (var i = 0; i < rounds.length; i++) {
    final start = getScanWindowStart(rounds[i].time);
    final end = getScanWindowEnd(rounds[i].time);
    if (!now.isBefore(start) && now.isBefore(end)) {
      current = rounds[i];
      currentIndex = i;
      foundActive = true;
      break;
    }
  }

  if (!foundActive) {
    for (var i = 0; i < rounds.length; i++) {
      final start = getScanWindowStart(rounds[i].time);
      if (now.isBefore(start)) {
        current = rounds[i];
        currentIndex = i;
        break;
      }
      current = rounds[i];
      currentIndex = i;
    }
  }

  final next = currentIndex < rounds.length - 1
      ? rounds[currentIndex + 1]
      : rounds.first;

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
