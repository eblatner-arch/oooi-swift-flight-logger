"""Read a MyFlightbook logbook export (CSV) into compact history entries.

History is kept apart from flights logged in this add-on: it feeds the Stats
and Map tabs only and is never written into the MyFlightbook import CSVs.

MyFlightbook's column names, date format and time format (decimal or hh:mm)
depend on the account's settings, so columns are matched by name with a few
common spellings, and values are parsed leniently.
"""
import csv
import io
import re
from datetime import datetime

import flightmath as fm

# entry key -> header spellings (compared lower-case with punctuation and spaces removed)
COLUMNS = {
    'date': ['date', 'flight date'],
    'total': ['total flight time', 'total time', 'total', 'totaltime'],
    'pic': ['pic'],
    'sic': ['sic'],
    'night': ['night', 'night time'],
    'xc': ['x-country', 'cross country', 'xc', 'crosscountry'],
    'landings': ['landings', 'all landings', 'total landings'],
    'fs_day': ['fs day landings', 'full stop day landings', 'day landings', 'fs day'],
    'fs_night': ['fs night landings', 'full stop night landings', 'night landings', 'fs night'],
    'takeoffs': ['takeoffs (any)', 'takeoffs', 'takeoffs any'],
    'night_takeoffs': ['takeoffs - night', 'night takeoffs', 'takeoffs night'],
    'route': ['route'],
    'from': ['from', 'departure', 'dep', 'origin'],
    'to': ['to', 'arrival', 'arr', 'destination', 'dest'],
    'registration': ['aircraft registration', 'registration'],
    'display_tail': ['display tail'],
    'tail': ['tail number', 'tail'],
    'model': ['model', 'aircraft type', 'type'],
    'icao_model': ['icao model'],
    'flight_number': ['flight number', 'flight no', 'flight #'],
    'comments': ['comments', 'remarks'],
    'ground_sim': ['ground simulator', 'simulator', 'ground sim'],
}


def _key(h):
    return re.sub(r'[^a-z0-9]', '', (h or '').lower())


def _hours(v):
    """'3.82', '3:49', '' -> hours as float."""
    v = (v or '').strip()
    if not v:
        return 0.0
    m = re.fullmatch(r'(\d+):(\d{1,2})', v)
    if m:
        return int(m.group(1)) + int(m.group(2)) / 60
    try:
        return float(v.replace(',', '.'))
    except ValueError:
        return 0.0


def _int(v):
    try:
        return int(float((v or '0').strip() or 0))
    except ValueError:
        return 0


_DATE_FORMATS = ('%Y-%m-%d', '%m/%d/%Y', '%m/%d/%y', '%Y/%m/%d', '%d %b %Y', '%b %d, %Y', '%d-%b-%Y', '%d.%m.%Y')


def _date(v):
    v = (v or '').strip()
    if not v:
        return None
    v = re.split(r'[T ](?=\d{1,2}:)', v)[0].strip()  # drop a time part
    for fmt in _DATE_FORMATS:
        try:
            return datetime.strptime(v, fmt).strftime('%Y-%m-%d')
        except ValueError:
            continue
    return None


def _route(text):
    """Route text -> list of airport codes as written (upper-case, repeats collapsed)."""
    out = []
    for tok in re.findall(r'[A-Za-z0-9]{3,4}', text or ''):
        if not out or out[-1] != tok.upper():
            out.append(tok.upper())
    return out


def resolve(entries):
    """Copy of entries with route codes turned into ICAO where the airport list knows them.

    Done when history is read rather than at import, so updating the airport
    list fixes airports in history that was imported earlier.
    Returns (entries, unknown codes most common first, unknown count).
    """
    cache, unknown, out = {}, {}, []
    for e in entries:
        r = []
        for c in e.get('r') or []:
            if c not in cache:
                cache[c] = fm.resolve_airport(c)
            ic = cache[c]
            if not ic:
                unknown[c] = unknown.get(c, 0) + 1
            code = ic or c
            if not r or r[-1] != code:
                r.append(code)
        out.append({**e, 'r': r})
    ranked = [c for c, _ in sorted(unknown.items(), key=lambda kv: -kv[1])]
    return out, ranked[:12], len(ranked)


def _header_row(rows):
    for i, row in enumerate(rows[:15]):
        keys = {_key(c) for c in row}
        if 'date' in keys and (keys & {_key(x) for x in COLUMNS['total'] + COLUMNS['route']}):
            return i
    return None


def parse(data):
    """CSV bytes -> (entries, summary). Raises ValueError with a readable message."""
    text = data.decode('utf-8-sig', errors='replace') if isinstance(data, bytes) else data
    if not text.strip():
        raise ValueError('The file is empty.')
    try:
        dialect = csv.Sniffer().sniff(text[:4096], delimiters=',;\t')
    except csv.Error:
        dialect = csv.excel
    rows = list(csv.reader(io.StringIO(text), dialect))
    h = _header_row(rows)
    if h is None:
        raise ValueError("This doesn't look like a MyFlightbook logbook export: no header row with Date and Total Flight Time or Route.")
    header = [_key(c) for c in rows[h]]
    col = {}
    for name, spellings in COLUMNS.items():
        for sp in spellings:
            if _key(sp) in header:
                col[name] = header.index(_key(sp))
                break

    def get(row, name):
        i = col.get(name)
        return row[i] if i is not None and i < len(row) else ''

    entries, skipped = [], 0
    for row in rows[h + 1:]:
        if not any(c.strip() for c in row):
            continue
        d = _date(get(row, 'date'))
        if not d:
            skipped += 1
            continue
        route = _route(get(row, 'route')) if 'route' in col else []
        if not route:
            route = _route(' '.join(x for x in (get(row, 'from'), get(row, 'to')) if x))
        total = _hours(get(row, 'total'))
        # Registration: the property if set, else the tail shown in MyFlightbook. Skip anonymous
        # aircraft ('#002377', '(Anonymous B737)') and simulators.
        reg = ''
        for cand in (get(row, 'registration'), get(row, 'display_tail'), get(row, 'tail')):
            cand = cand.strip()
            if cand and not cand.startswith(('#', '(')) and cand.upper() not in ('SIM', 'ATD', 'FTD', 'FFS'):
                reg = cand
                break
        model = (get(row, 'icao_model') or get(row, 'model').split(',')[0]).strip()
        e = {
            'd': d, 'r': route, 't': round(total, 2),
            'pic': round(_hours(get(row, 'pic')), 2), 'sic': round(_hours(get(row, 'sic')), 2),
            'n': round(_hours(get(row, 'night')), 2), 'x': round(_hours(get(row, 'xc')), 2),
            'l': _int(get(row, 'landings')), 'ld': _int(get(row, 'fs_day')), 'ln': _int(get(row, 'fs_night')),
            'reg': reg[:16], 'm': model[:24], 'fn': get(row, 'flight_number').strip()[:12],
        }
        if 'takeoffs' in col:
            e['to'] = _int(get(row, 'takeoffs'))
        if 'night_takeoffs' in col:
            e['ton'] = _int(get(row, 'night_takeoffs'))
        if total == 0 and _hours(get(row, 'ground_sim')) > 0:
            e['sim'] = 1
        entries.append(e)

    if not entries:
        raise ValueError('No flights found in the file. Check that it is the CSV download of your MyFlightbook logbook.')
    entries.sort(key=lambda e: e['d'])
    _, unknown, n_unknown = resolve(entries)
    summary = {
        'flights': sum(1 for e in entries if not e.get('sim')),
        'sim_sessions': sum(1 for e in entries if e.get('sim')),
        'skipped_rows': skipped,
        'first': entries[0]['d'], 'last': entries[-1]['d'],
        'total_hours': round(sum(e['t'] for e in entries), 1),
        'columns_found': sorted(col),
        'unknown_airports': unknown,
        'unknown_airport_count': n_unknown,
    }
    return entries, summary
