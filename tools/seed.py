"""Made-up flights and logbook history for testing the app against the real add-on server.

python3 tools/seed.py <data dir>   (then run tools/addon/server.py with OOOI_DATA=<data dir>)
"""
import json, os, random, sys
from datetime import date, timedelta, datetime, timezone

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
random.seed(7)
today = date.today()

# (from, to, block minutes)
ROUTES = [("KEWR", "KFLL", 175), ("KEWR", "KMCO", 160), ("KEWR", "KDEN", 265), ("KIAH", "KEWR", 215), ("KEWR", "KSFO", 380),
          ("KORD", "KEWR", 130), ("KEWR", "KTPA", 165), ("KEWR", "TJSJ", 235), ("KDEN", "KLAX", 150), ("KEWR", "KBOS", 75)]


def hhmm(m):
    m %= 1440
    return f"{m // 60:02d}{m % 60:02d}"


flights = []
for i in range(7):
    a, b, blk = ROUTES[i % len(ROUTES)]
    if i % 2:
        a, b = b, a
    d = today - timedelta(days=2 + i * 3)
    out_m = [690, 1310, 845, 1420, 500, 1150, 980][i]
    crew = out_m - 7
    off = out_m + 14
    on = out_m + blk - 9
    inn = out_m + blk
    flights.append({
        "id": f"{d.isoformat()}_{1200 + i * 37}_{hhmm(out_m)}_demo", "date": d.isoformat(), "flightNumber": str(1200 + i * 37),
        "tail": f"N{37500 + i * 13}", "from": a, "to": b, "crew": hhmm(crew), "out": hhmm(out_m), "off": hhmm(off), "on": hhmm(on),
        "in": hhmm(inn), "comments": "", "duty": "PF" if i % 3 != 1 else "PM", "seat": "SIC", "approaches": 0,
        "imported": i >= 4, "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    })
json.dump({"flights": flights}, open(os.path.join(out, "flights.json"), "w"), indent=1)
json.dump({"seat": "SIC", "anon_tail": "#002377", "model": "B737", "time_fmt": "hm"}, open(os.path.join(out, "settings.json"), "w"))

entries = []
d = today - timedelta(days=3 * 365)
while d < today - timedelta(days=25):
    for _ in range(random.choice([0, 0, 1, 2])):
        a, b, blk = random.choice(ROUTES)
        if random.random() < 0.5:
            a, b = b, a
        t = round((blk + 7) / 60, 2)
        night = round(random.choice([0, 0, 0, t * 0.3, t]), 2)
        pf = random.random() < 0.5
        nl = 1 if pf and night > t * 0.5 else 0
        entries.append({"d": d.isoformat(), "r": [a, b], "t": t, "pic": 0, "sic": t, "n": night, "x": t,
                        "l": 1 if pf else 0, "ld": 1 if pf and not nl else 0, "ln": nl, "to": 1 if pf else 0, "ton": nl,
                        "reg": f"N{random.randint(37200, 37999)}", "m": "B737", "fn": str(random.randint(200, 2400))})
    d += timedelta(days=1)
summary = {"flights": len(entries), "sim_sessions": 0, "skipped_rows": 0, "first": entries[0]["d"], "last": entries[-1]["d"],
           "total_hours": round(sum(e["t"] for e in entries), 1), "columns_found": [], "unknown_airports": [], "unknown_airport_count": 0}
json.dump({"imported_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "file": "logbook.csv", "summary": summary, "entries": entries},
          open(os.path.join(out, "history.json"), "w"))
print(f"{len(flights)} flights, {len(entries)} history entries in {out}")
