import datetime

def get_scan_window_start(round_start):
    return round_start - datetime.timedelta(minutes=5)

def get_scan_window_end(round_start):
    return round_start + datetime.timedelta(minutes=15)

def build_patrol_rounds(now):
    local_day = datetime.datetime(now.year, now.month, now.day)
    cycle_start = local_day - datetime.timedelta(days=1) if now.hour < 6 else local_day
    cycle_end_day = cycle_start + datetime.timedelta(days=1)
    
    slots = []
    # Day slots: 6 to 21
    for h in range(6, 22):
        slots.append(datetime.datetime(cycle_start.year, cycle_start.month, cycle_start.day, h))
    # Night slots: 22, 22:30, 23, 23:30
    for h in [22, 23]:
        slots.append(datetime.datetime(cycle_start.year, cycle_start.month, cycle_start.day, h, 0))
        slots.append(datetime.datetime(cycle_start.year, cycle_start.month, cycle_start.day, h, 30))
    # Early morning slots: 0 to 5:30
    for idx in range(12):
        slots.append(datetime.datetime(cycle_end_day.year, cycle_end_day.month, cycle_end_day.day, idx // 2, (idx % 2) * 30))
        
    slots.sort()
    rounds = []
    for idx, slot in enumerate(slots):
        rounds.append({'time': slot, 'round': idx + 1})
    return rounds

def get_current_patrol_round(now):
    rounds = build_patrol_rounds(now)
    current = rounds[0]
    found_active = False
    
    for i in range(len(rounds)):
        start = get_scan_window_start(rounds[i]['time'])
        end = get_scan_window_end(rounds[i]['time'])
        if not now < start and now < end:
            current = rounds[i]
            found_active = True
            break
            
    if not found_active:
        for i in range(len(rounds)):
            start = get_scan_window_start(rounds[i]['time'])
            if now < start:
                current = rounds[i]
                break
            current = rounds[i]
            
    return current, found_active

# Test from 19:50 to 20:10
base_time = datetime.datetime(2026, 6, 13, 19, 50)
for m in range(21):
    test_time = base_time + datetime.timedelta(minutes=m)
    current, active = get_current_patrol_round(test_time)
    print(f"{test_time.strftime('%H:%M')} -> Round {current['round']} ({current['time'].strftime('%H:%M')}) - Active: {active}")
