"""OOOI Flight Logger add-on server (Python standard library only).

Serves the web UI through Home Assistant ingress, keeps flights in /data,
writes MyFlightbook CSVs to /share/oooi_logger, scans OOOI photos with Gemini,
and uploads the files to Google Drive using a device sign-in (refresh token).
"""
import base64
import gzip
import re
import hashlib
import hmac
import json
import logging
import mimetypes
import os
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import flightmath as fm
import history as hist

DATA = os.environ.get('OOOI_DATA', '/data')
SHARE = os.environ.get('OOOI_SHARE', '/share/oooi_logger')
WWW = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'www')
PORT = int(os.environ.get('OOOI_PORT', '8099'))
DIRECT_PORT = int(os.environ.get('OOOI_DIRECT_PORT', '8199'))
ALLOWED = {'172.30.32.2', '127.0.0.1', '::1'}
DEV = os.environ.get('OOOI_DEV') == '1'
SCOPE = 'https://www.googleapis.com/auth/drive.file openid email'
DRIVE_API = 'https://www.googleapis.com/drive/v3/files'
DRIVE_UP = 'https://www.googleapis.com/upload/drive/v3/files'
GOOGLE_TOKEN = os.environ.get('OOOI_GOOGLE_TOKEN', 'https://oauth2.googleapis.com/token')
GOOGLE_DEVICE = os.environ.get('OOOI_GOOGLE_DEVICE', 'https://oauth2.googleapis.com/device/code')
GEMINI_BASE = os.environ.get('OOOI_GEMINI', 'https://generativelanguage.googleapis.com/v1beta/models')
DRIVE_BASE = os.environ.get('OOOI_DRIVE')  # test override for both Drive hosts
AIRPORTS_URL = os.environ.get('OOOI_AIRPORTS_URL', 'https://raw.githubusercontent.com/mborsetti/airportsdata/main/airportsdata/airports.csv')
MIN_AIRPORTS = 5000

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger('oooi')
LOCK = threading.RLock()


# ---------------- storage ----------------
def _path(name):
    return os.path.join(DATA, name)


def load(name, default):
    try:
        with open(_path(name), encoding='utf-8') as fh:
            return json.load(fh)
    except FileNotFoundError:
        return default
    except Exception:
        log.exception('could not read %s', name)
        return default


def save(name, obj):
    tmp = _path(name + '.tmp')
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(obj, fh, indent=1)
    os.replace(tmp, _path(name))


def options():
    o = load('options.json', {})
    return {
        'gemini_api_key': (o.get('gemini_api_key') or '').strip(),
        'gemini_model': (o.get('gemini_model') or 'gemini-3.5-flash-lite').strip(),
        'google_client_id': (o.get('google_client_id') or '').strip(),
        'google_client_secret': (o.get('google_client_secret') or '').strip(),
        'drive_folder': (o.get('drive_folder') or 'OOOI Logger (Home Assistant)').strip(),
        'app_password': (o.get('app_password') or ''),
    }


def settings():
    s = {'seat': 'PIC', 'anon_tail': '#002377', 'model': 'B737'}
    s.update(load('settings.json', {}))
    s.pop('airline', None)  # setting removed in 1.11.0
    s['csv_names'] = {}     # standard headers are fixed to MyFlightbook's names since 1.13.0
    return s


def flights():
    return load('flights.json', {'flights': []})['flights']


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def write_local_files():
    """Write CSVs and a JSON backup to /share so they are reachable over Samba too."""
    with LOCK:
        fl, cfg = flights(), settings()
    try:
        os.makedirs(SHARE, exist_ok=True)
        files = {
            'MyFlightbook Import - pending.csv': fm.build_csv([f for f in fl if not f.get('imported')], cfg),
            'Flight Log - all flights.csv': fm.build_csv(fl, cfg),
            'flights.json': json.dumps({'app': 'oooi-logger-haos', 'savedAt': now_iso(), 'flights': fl}, indent=1),
        }
        for name, content in files.items():
            tmp = os.path.join(SHARE, name + '.tmp')
            with open(tmp, 'w', encoding='utf-8') as fh:
                fh.write(content)
            os.replace(tmp, os.path.join(SHARE, name))
    except Exception:
        log.exception('could not write files to %s', SHARE)


# ---------------- HTTP helpers for Google ----------------
class HttpError(Exception):
    def __init__(self, status, body):
        super().__init__(f'HTTP {status}: {body[:300]}')
        self.status, self.body = status, body


def http(method, url, data=None, headers=None, timeout=60):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        raise HttpError(e.code, e.read().decode('utf-8', 'replace'))


def form_post(url, fields):
    st, body = http('POST', url, urllib.parse.urlencode(fields).encode(), {'Content-Type': 'application/x-www-form-urlencoded'})
    return json.loads(body)


def _drive(url):
    if DRIVE_BASE:
        return url.replace('https://www.googleapis.com', DRIVE_BASE)
    return url


# ---------------- Google sign-in (device flow) ----------------
DEVICE = {'pending': None}


def google_state():
    return load('google.json', {})


def start_device_flow():
    o = options()
    if not o['google_client_id'] or not o['google_client_secret']:
        raise ValueError('Add google_client_id and google_client_secret in the add-on Configuration tab first.')
    res = form_post(GOOGLE_DEVICE, {'client_id': o['google_client_id'], 'scope': SCOPE})
    pending = {
        'user_code': res['user_code'], 'verification_url': res.get('verification_url') or res.get('verification_uri'),
        'expires_at': time.time() + int(res.get('expires_in', 1800)), 'interval': int(res.get('interval', 5)),
        'device_code': res['device_code'], 'error': None,
    }
    DEVICE['pending'] = pending
    threading.Thread(target=_poll_device, args=(pending,), daemon=True).start()
    return {k: pending[k] for k in ('user_code', 'verification_url', 'expires_at')}


def _poll_device(p):
    o = options()
    interval = p['interval']
    while time.time() < p['expires_at'] and DEVICE['pending'] is p:
        time.sleep(interval)
        try:
            tok = form_post(GOOGLE_TOKEN, {
                'client_id': o['google_client_id'], 'client_secret': o['google_client_secret'],
                'device_code': p['device_code'], 'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            })
        except HttpError as e:
            err = ''
            try:
                err = json.loads(e.body).get('error', '')
            except Exception:
                pass
            if err == 'authorization_pending':
                continue
            if err == 'slow_down':
                interval += 5
                continue
            p['error'] = {'access_denied': 'You declined access on the Google page.', 'expired_token': 'The code expired. Start again.'}.get(err, f'Google sign-in failed ({err or e.status}).')
            return
        except Exception as e:
            log.warning('device poll: %s', e)
            continue
        email = ''
        if tok.get('id_token'):
            try:
                part = tok['id_token'].split('.')[1]
                email = json.loads(base64.urlsafe_b64decode(part + '=' * (-len(part) % 4))).get('email', '')
            except Exception:
                pass
        with LOCK:
            g = google_state()
            g.update({'refresh_token': tok.get('refresh_token') or g.get('refresh_token'), 'access_token': tok.get('access_token'),
                      'access_exp': time.time() + int(tok.get('expires_in', 3600)) - 60, 'email': email or g.get('email', ''),
                      'connected_at': now_iso(), 'last_error': None})
            save('google.json', g)
        DEVICE['pending'] = None
        log.info('Google Drive connected%s', f' as {email}' if email else '')
        schedule_sync(0.5)
        return
    if DEVICE['pending'] is p and not p['error']:
        p['error'] = 'The code expired. Start again.'


def access_token():
    with LOCK:
        g = google_state()
    if not g.get('refresh_token'):
        raise PermissionError('not connected')
    if g.get('access_token') and g.get('access_exp', 0) > time.time():
        return g['access_token']
    o = options()
    try:
        tok = form_post(GOOGLE_TOKEN, {'client_id': o['google_client_id'], 'client_secret': o['google_client_secret'],
                                       'refresh_token': g['refresh_token'], 'grant_type': 'refresh_token'})
    except HttpError as e:
        if e.status in (400, 401):
            with LOCK:
                g = google_state()
                g.update({'refresh_token': None, 'access_token': None,
                          'last_error': 'Google sign-in expired or was revoked. Connect Google again in Settings.'})
                save('google.json', g)
            raise PermissionError('revoked')
        raise
    with LOCK:
        g = google_state()
        g.update({'access_token': tok['access_token'], 'access_exp': time.time() + int(tok.get('expires_in', 3600)) - 60})
        save('google.json', g)
    return tok['access_token']


# ---------------- Google Drive ----------------
def gd(method, url, token, data=None, ctype=None):
    h = {'Authorization': 'Bearer ' + token}
    if ctype:
        h['Content-Type'] = ctype
    return http(method, _drive(url), data, h)


def find_id(token, name, parent=None, mime=None):
    q = "name = '%s' and trashed = false" % name.replace('\\', '\\\\').replace("'", "\\'")
    if parent:
        q += " and '%s' in parents" % parent
    if mime:
        q += " and mimeType = '%s'" % mime
    _, body = gd('GET', f'{DRIVE_API}?q={urllib.parse.quote(q)}&fields=files(id)&spaces=drive&pageSize=1', token)
    files = json.loads(body).get('files') or []
    return files[0]['id'] if files else None


def create_folder(token, name):
    _, body = gd('POST', f'{DRIVE_API}?fields=id', token, json.dumps({'name': name, 'mimeType': 'application/vnd.google-apps.folder'}).encode(), 'application/json')
    return json.loads(body)['id']


def create_file(token, name, parent, mime, content):
    bd = 'oooi' + secrets.token_hex(8)
    meta = json.dumps({'name': name, 'parents': [parent], 'mimeType': mime})
    body = (f'--{bd}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{meta}\r\n'
            f'--{bd}\r\nContent-Type: {mime}; charset=UTF-8\r\n\r\n{content}\r\n--{bd}--').encode('utf-8')
    _, res = gd('POST', f'{DRIVE_UP}?uploadType=multipart&fields=id', token, body, f'multipart/related; boundary={bd}')
    return json.loads(res)['id']


def update_file(token, fid, mime, content):
    """Replace a file's content. Returns its metadata, including whether it is in Drive's trash."""
    _, body = gd('PATCH', f'{DRIVE_UP}/{fid}?uploadType=media&fields=id,trashed', token, content.encode('utf-8'), mime + '; charset=UTF-8')
    try:
        return json.loads(body or b'{}')
    except ValueError:
        return {}


def upsert(token, g, key, name, mime, content, folder):
    fid = g.get(key)
    if fid:
        try:
            # Deleting a file in Drive only moves it to the trash, and a trashed file still accepts
            # updates, so check the result and make a fresh copy instead of writing into the trash.
            if not update_file(token, fid, mime, content).get('trashed'):
                return fid
            log.info('%s is in Drive\'s trash; creating a new copy', name)
        except HttpError as e:
            if e.status != 404:
                raise
    fid = find_id(token, name, folder)
    if fid:
        update_file(token, fid, mime, content)
    else:
        fid = create_file(token, name, folder, mime, content)
    g[key] = fid
    return fid


SYNC = {'timer': None, 'running': False, 'again': False}


def schedule_sync(delay=2.0):
    with LOCK:
        if SYNC['timer']:
            SYNC['timer'].cancel()
        t = threading.Timer(delay, run_sync)
        t.daemon = True
        SYNC['timer'] = t
        t.start()


def run_sync():
    with LOCK:
        if SYNC['running']:
            SYNC['again'] = True
            return
        SYNC['running'] = True
    try:
        do_sync()
    finally:
        with LOCK:
            SYNC['running'] = False
            again, SYNC['again'] = SYNC['again'], False
        if again:
            run_sync()


def do_sync():
    with LOCK:
        g = google_state()
    if not g.get('refresh_token'):
        return False
    o = options()
    try:
        token = access_token()
        with LOCK:
            fl, cfg = flights(), settings()
            g = google_state()
        folder = g.get('folder_id')
        if folder:
            try:
                _, body = gd('GET', f'{DRIVE_API}/{folder}?fields=id,trashed', token)
                if json.loads(body).get('trashed'):
                    folder = None
            except HttpError as e:
                if e.status == 404:
                    folder = None
                else:
                    raise
        if not folder:
            folder = find_id(token, o['drive_folder'], None, 'application/vnd.google-apps.folder') or create_folder(token, o['drive_folder'])
            g.update({'folder_id': folder, 'json_id': None, 'pending_id': None, 'all_id': None})
        upsert(token, g, 'json_id', 'flights.json', 'application/json',
               json.dumps({'app': 'oooi-logger-haos', 'savedAt': now_iso(), 'flights': fl}, indent=1), folder)
        upsert(token, g, 'pending_id', 'MyFlightbook Import – pending.csv', 'text/csv',
               fm.build_csv([f for f in fl if not f.get('imported')], cfg), folder)
        upsert(token, g, 'all_id', 'Flight Log – all flights.csv', 'text/csv', fm.build_csv(fl, cfg), folder)
        g.update({'last_sync': now_iso(), 'last_error': None})
        log.info('Drive sync done (%d flights)', len(fl))
        ok = True
    except PermissionError:
        return False
    except HttpError as e:
        msg = ''
        try:
            msg = json.loads(e.body)['error']['message']
        except Exception:
            pass
        g['last_error'] = f'Drive sync failed ({e.status}){": " + msg if msg else ""}.'
        log.warning(g['last_error'])
        ok = False
    except Exception as e:
        g['last_error'] = f'Drive sync failed: {e}'
        log.warning(g['last_error'])
        ok = False
    with LOCK:
        cur = google_state()
        for k in ('folder_id', 'json_id', 'pending_id', 'all_id', 'last_sync', 'last_error'):
            if k in g:
                cur[k] = g[k]
        save('google.json', cur)
    return ok


# ---------------- Gemini ----------------
SCAN_PROMPT = """The image is a photo of a Boeing FMC/CDU screen showing the airline ACARS page titled "ACARS-PREVIOUS OOOI". Read the values under each label:
- FLT NBR: flight number (digits only)
- DEP/DES: departure and destination ICAO codes, written like KORD/KDEN
- CREW, OUT, OFF, ON, IN: four-digit UTC times (HHMM)
- TRIP: total time written HH:MM
The screen shows zeros with a slash (Ø). Read them as 0. Do not confuse 1 and 7, 5 and 6, 8 and 0.
Reply with only one JSON object, for example:
{"flightNumber":"1234","from":"KORD","to":"KDEN","crew":"1205","out":"1212","off":"1230","on":"1447","in":"1455","trip":"02:50","confidence":"high","notes":""}
Use null for any value you cannot read with confidence. confidence is "high", "medium" or "low". If the photo is not this ACARS page, return all values null and say what you see in notes."""


# Gemini sometimes sits on a request for 20-40 s (its own queue; the same photo usually takes about
# a second). If no answer has come back after HEDGE_AFTER seconds, send the same request again and use
# whichever answer arrives first: up to three requests in flight (at 0, 4 and 9 s).
HEDGE_AFTER = (0, 4, 9)
GEMINI_LIMIT = 90


def _gemini_error(e, model):
    msg = ''
    try:
        msg = json.loads(e.body)['error']['message']
    except Exception:
        pass
    return {
        400: 'Gemini rejected the request. Check gemini_api_key in the add-on Configuration.' if 'key' in msg.lower() else f'Gemini error: {msg}',
        403: 'Gemini refused the key. Check it in the add-on Configuration.',
        404: f'Gemini has no model named "{model}". Change gemini_model in the add-on Configuration.',
        429: 'Gemini free-tier limit reached. Wait a minute and scan again.',
    }.get(e.status, f'Gemini error ({e.status}). {msg}')


def gemini_scan(jpeg):
    o = options()
    if not o['gemini_api_key']:
        return 400, {'error': 'Add gemini_api_key in the add-on Configuration tab to scan.'}
    model = o['gemini_model']
    url = f"{GEMINI_BASE}/{urllib.parse.quote(model)}:generateContent?key={urllib.parse.quote(o['gemini_api_key'])}"
    gen = {'responseMimeType': 'application/json', 'temperature': 0}
    if 'flash' in model and (model.startswith('gemini-3') or model.startswith('gemini-4')):
        gen['thinkingConfig'] = {'thinkingLevel': 'minimal'}   # reading a screen needs no reasoning
    body = json.dumps({
        'contents': [{'role': 'user', 'parts': [{'text': SCAN_PROMPT}, {'inline_data': {'mime_type': 'image/jpeg', 'data': base64.b64encode(jpeg).decode()}}]}],
        'generationConfig': gen,
    }).encode()

    def call():
        return http('POST', url, body, {'Content-Type': 'application/json'}, timeout=GEMINI_LIMIT)[1]

    t0 = time.monotonic()
    pool = ThreadPoolExecutor(max_workers=len(HEDGE_AFTER))
    futs, first_err, res, winner = {}, None, None, 0
    try:
        while res is None:
            el = time.monotonic() - t0
            while len(futs) < len(HEDGE_AFTER) and el >= HEDGE_AFTER[len(futs)]:
                futs[pool.submit(call)] = len(futs) + 1
            nxt = HEDGE_AFTER[len(futs)] if len(futs) < len(HEDGE_AFTER) else GEMINI_LIMIT
            pending = [f for f in futs if not f.done()]
            if pending:
                wait(pending, timeout=max(0.05, min(nxt, GEMINI_LIMIT) - el), return_when=FIRST_COMPLETED)
            else:
                time.sleep(0.1)
            for f in [f for f in futs if f.done()]:
                try:
                    res, winner = f.result(), futs[f]
                    break
                except HttpError as e:
                    if e.status in (400, 403, 404):   # a request that can never work: no point waiting for the others
                        return 502, {'error': _gemini_error(e, model)}
                    first_err = first_err or e
                except Exception as e:
                    first_err = first_err or e
            if res is None:
                done_all = len(futs) == len(HEDGE_AFTER) and all(f.done() for f in futs)
                if done_all or time.monotonic() - t0 >= GEMINI_LIMIT:
                    e = first_err
                    if isinstance(e, HttpError):
                        return 502, {'error': _gemini_error(e, model)}
                    return 502, {'error': f'Could not reach Gemini: {e or "no answer in time"}'}
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    ms = round((time.monotonic() - t0) * 1000)
    j = json.loads(res)
    text = ''.join(p.get('text', '') for p in (((j.get('candidates') or [{}])[0].get('content') or {}).get('parts') or []))
    start, end = text.find('{'), text.rfind('}')
    if start < 0 or end < start:
        return 502, {'error': 'Gemini could not read the page clearly. Retake the photo straight on with less glare.'}
    try:
        out = json.loads(text[start:end + 1])
    except Exception:
        return 502, {'error': 'Gemini could not read the page clearly. Retake the photo straight on with less glare.'}
    if isinstance(out, dict):
        # for the scan timer: Gemini's own time, and which of the requests answered
        out['gemini_ms'] = ms
        out['gemini_request'] = winner
        out['gemini_requests'] = len(futs)
        log.info('Scan: Gemini answered in %.1f s (request %d of %d)', ms / 1000, winner, len(futs))
    return 200, out


# ---------------- Airport database ----------------
def airports_info():
    meta = load('airports_meta.json', {})
    if meta.get('updated') and os.path.isfile(_path('airports.js')):
        return {'source': 'updated', 'updated': meta['updated'], 'count': len(fm.AP)}
    return {'source': 'bundled', 'updated': None, 'count': len(fm.AP)}


def update_airports():
    """Download the latest airport list, rebuild it, and switch to it if it looks sane."""
    try:
        _, body = http('GET', AIRPORTS_URL, timeout=120)
    except HttpError as e:
        raise RuntimeError(f'GitHub returned an error ({e.status}). Your current airport list is unchanged.')
    except Exception as e:
        raise RuntimeError(f'Could not download the airport list: {e}. Your current airport list is unchanged.')
    try:
        src, n = fm.build_airports_js(body.decode('utf-8'))
        test = fm.parse_airports_js(src)
    except Exception:
        raise RuntimeError('The downloaded airport list was not in the expected format. Your current airport list is unchanged.')
    if n < MIN_AIRPORTS or 'KJFK' not in test:
        raise RuntimeError(f'The downloaded list only had {n} airports, which looks wrong. Your current airport list is unchanged.')
    before = len(fm.AP)
    with LOCK:
        tmp = _path('airports.js.tmp')
        with open(tmp, 'w', encoding='utf-8') as fh:
            fh.write(src)
        os.replace(tmp, _path('airports.js'))
        fm.load_airports(_path('airports.js'))
        save('airports_meta.json', {'updated': now_iso(), 'count': n, 'source_url': AIRPORTS_URL})
    log.info('Airport database updated: %d airports (was %d)', n, before)
    return {'count': n, 'before': before}


# ---------------- API ----------------
def state():
    o = options()
    with LOCK:
        g, fl, cfg = google_state(), flights(), settings()
    p = DEVICE['pending']
    return {
        'flights': fl, 'settings': cfg,
        'drive': {
            'configured': bool(o['google_client_id'] and o['google_client_secret']), 'connected': bool(g.get('refresh_token')),
            'email': g.get('email', ''), 'last_sync': g.get('last_sync'), 'last_error': g.get('last_error'), 'folder_id': g.get('folder_id'),
            'folder': o['drive_folder'], 'syncing': SYNC['running'],
            'pending': ({'user_code': p['user_code'], 'verification_url': p['verification_url'], 'expires_at': p['expires_at'], 'error': p['error']} if p else None),
        },
        'scan': {'configured': bool(o['gemini_api_key']), 'model': o['gemini_model']},
        'share_path': SHARE,
        'history': history_info(),
        'csv_columns': fm.CSV_COLS,
        'csv_sources': fm.CSV_SOURCES,
        'airports': airports_info(),
    }


# ---------------- Imported MyFlightbook history ----------------
_UNKNOWN_CACHE = {'key': None, 'val': None}


def history_info():
    h = load('history.json', None)
    if not h:
        return None
    info = {'imported_at': h.get('imported_at'), 'version': h.get('imported_at'), 'file': h.get('file', ''), **h.get('summary', {})}
    # Recheck unknown airports against the current airport list (it may have been updated, or a
    # renamed code like KPBI→KDJT handled) instead of showing the list saved at import time.
    key = (h.get('imported_at'), len(fm.AP), load('airports_meta.json', {}).get('updated'))
    if _UNKNOWN_CACHE['key'] != key:
        _, unknown, n = hist.resolve(h.get('entries') or [])
        _UNKNOWN_CACHE.update(key=key, val=(unknown, n))
    info['unknown_airports'], info['unknown_airport_count'] = _UNKNOWN_CACHE['val']
    return info


def changed():
    write_local_files()
    schedule_sync()


def _secret():
    path = _path('secret.key')
    try:
        with open(path, 'rb') as fh:
            return fh.read()
    except FileNotFoundError:
        key = secrets.token_bytes(32)
        with open(path, 'wb') as fh:
            fh.write(key)
        return key


def auth_token(password):
    return hmac.new(_secret(), password.encode('utf-8'), hashlib.sha256).hexdigest()


# ---------------- Fast loading ----------------
# Static files are read once and kept in memory (re-read when they change on disk). Each gets an
# ETag from its content. index.html links every script and stylesheet with ?v=<that tag>, so the
# browser can keep those files for a year and only fetches index.html (or a 304) on each open.
_FILES = {}
_COMPRESSIBLE = ('text/', 'application/javascript', 'application/json', 'image/svg+xml', 'application/manifest+json')


def static_file(full):
    st = os.stat(full)
    hit = _FILES.get(full)
    if hit and hit['mtime'] == st.st_mtime and hit['size'] == st.st_size:
        return hit
    with open(full, 'rb') as fh:
        body = fh.read()
    ctype = mimetypes.guess_type(full)[0] or 'application/octet-stream'
    if full.endswith('.webmanifest'):
        ctype = 'application/manifest+json'
    if full.endswith('.js'):
        ctype = 'application/javascript'
    hit = {'mtime': st.st_mtime, 'size': st.st_size, 'body': body, 'ctype': ctype, 'gz': None,
           'etag': '"' + hashlib.sha1(body).hexdigest()[:16] + '"'}
    _FILES[full] = hit
    return hit


def asset_path(rel):
    """Disk path for a web file (the airport list downloaded to /data replaces the bundled one)."""
    if rel == 'js/airports.js' and os.path.isfile(_path('airports.js')) and load('airports_meta.json', {}).get('updated'):
        return _path('airports.js')
    full = os.path.normpath(os.path.join(WWW, rel))
    return full if full.startswith(WWW) and os.path.isfile(full) else None


_ASSET_REF = re.compile(r'((?:js|css|icons)/[\w.-]+\.(?:js|css|png|svg))(?=["\'])')


def versioned_page(rel):
    """index.html / login.html with ?v=<content tag> added to every local script, stylesheet and icon."""
    page = static_file(os.path.join(WWW, rel))
    tags = []

    def add(m):
        full = asset_path(m.group(1))
        if not full:
            return m.group(1)
        tag = static_file(full)['etag'].strip('"')[:10]
        tags.append(tag)
        return f'{m.group(1)}?v={tag}'
    text = _ASSET_REF.sub(add, page['body'].decode('utf-8'))
    body = text.encode('utf-8')
    return {'body': body, 'ctype': 'text/html; charset=utf-8', 'gz': None,
            'etag': '"' + hashlib.sha1(body).hexdigest()[:16] + '"'}


OPEN_PATHS = {'/login.html', '/css/app.css', '/manifest.webmanifest', '/api/login'}


class Handler(BaseHTTPRequestHandler):
    server_version = 'OOOILogger/1.0'
    DIRECT = False  # True for the add-on's own port (Safari web app); False for HA ingress

    def log_message(self, fmt, *args):
        if DEV:
            log.info('%s %s', self.address_string(), fmt % args)

    def _guard(self):
        if not self.DIRECT:
            if DEV or self.client_address[0] in ALLOWED:
                return True
            self.send_error(403)
            return False
        pw = options()['app_password']
        p = self._route()
        if not pw or p in OPEN_PATHS or p.startswith('/icons/'):
            return True
        cookie = self.headers.get('Cookie') or ''
        got = next((c.split('=', 1)[1] for c in (x.strip() for x in cookie.split(';')) if c.startswith('oooi_auth=')), '')
        if got and hmac.compare_digest(got, auth_token(pw)):
            return True
        if self.command == 'GET' and p == '/':
            self._static('login.html')
        elif p.startswith('/api/'):
            self._json(401, {'error': 'Log in again.'})
        else:
            self.send_error(401)
        return False

    def _send(self, code, body, ctype, cache='no-cache', etag=None, entry=None):
        """Send a response: 304 when the browser already has it, gzip when it helps."""
        if etag and code == 200 and etag in [t.strip() for t in (self.headers.get('If-None-Match') or '').split(',')]:
            self.send_response(304)
            self.send_header('ETag', etag)
            self.send_header('Cache-Control', cache)
            self.end_headers()
            return
        gz = None
        # Compress on the direct port. Through ingress, Home Assistant's proxy handles the connection to the phone.
        if self.DIRECT and len(body) > 1024 and ctype.startswith(_COMPRESSIBLE) and 'gzip' in (self.headers.get('Accept-Encoding') or ''):
            if entry is not None:
                if entry.get('gz') is None:
                    entry['gz'] = gzip.compress(body, 6)
                gz = entry['gz']
            else:
                gz = gzip.compress(body, 6)
        out = gz or body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(out)))
        self.send_header('Cache-Control', cache)
        self.send_header('Vary', 'Accept-Encoding')
        if etag:
            self.send_header('ETag', etag)
        if gz:
            self.send_header('Content-Encoding', 'gzip')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(out)

    def _static(self, rel):
        page = versioned_page(rel)
        self._send(200, page['body'], page['ctype'], 'no-cache', page['etag'], page)

    def _json(self, code, obj, etag=None):
        body = json.dumps(obj).encode()
        self._send(code, body, 'application/json', 'no-cache' if etag else 'no-store', etag)

    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n > 25 * 1024 * 1024:
            raise ValueError('too large')
        return self.rfile.read(n) if n else b''

    def _route(self):
        return urllib.parse.urlparse(self.path).path.rstrip('/') or '/'

    def do_GET(self):
        if not self._guard():
            return
        p = self._route()
        if p == '/api/state':
            return self._json(200, state())
        if p == '/api/history':
            h = load('history.json', None) or {'entries': []}
            entries, unknown, n = hist.resolve(h.get('entries') or [])
            ver = f"{h.get('imported_at')}|{len(fm.AP)}|{load('airports_meta.json', {}).get('updated')}"
            return self._json(200, {**h, 'entries': entries, 'unknown_airports': unknown, 'unknown_airport_count': n,
                                    'version': ver}, etag='"h' + hashlib.sha1(ver.encode()).hexdigest()[:15] + '"')
        if p == '/api/csv/pending':
            with LOCK:
                csv_text = fm.build_csv([f for f in flights() if not f.get('imported')], settings())
            body = csv_text.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/csv; charset=utf-8')
            self.send_header('Content-Disposition', f'attachment; filename="MyFlightbook Import {datetime.now():%Y-%m-%d}.csv"')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        # static files (an updated airport list in /data replaces the bundled one)
        rel = 'index.html' if p == '/' else p.lstrip('/')
        if rel in ('index.html', 'login.html'):
            return self._static(rel)
        full = asset_path(rel)
        if not full:
            self.send_error(404)
            return
        f = static_file(full)
        # A ?v= link names this exact content, so the browser can keep it; otherwise it checks each time.
        versioned = 'v=' in urllib.parse.urlparse(self.path).query
        self._send(200, f['body'], f['ctype'], 'public, max-age=31536000, immutable' if versioned else 'no-cache', f['etag'], f)

    def do_PUT(self):
        if not self._guard():
            return
        p = self._route()
        try:
            data = json.loads(self._body() or b'{}')
        except Exception:
            return self._json(400, {'error': 'Bad JSON'})
        if p.startswith('/api/flights/'):
            fid = urllib.parse.unquote(p.split('/api/flights/', 1)[1])
            keep = ('date', 'flightNumber', 'tail', 'from', 'to', 'crew', 'out', 'off', 'on', 'in', 'comments', 'duty', 'seat', 'approaches', 'imported', 'createdAt')
            f = {k: data.get(k) for k in keep if k in data}
            if isinstance(data.get('extra'), dict):  # values for columns typed in on the Log screen
                f['extra'] = {str(k)[:16]: str(v)[:500] for k, v in list(data['extra'].items())[:30] if str(v).strip()}
            if isinstance(data.get('override'), dict):  # per-flight edits to automatic columns
                f['override'] = {str(k)[:80]: str(v)[:500] for k, v in list(data['override'].items())[:60] if str(v).strip()}
            f['id'] = fid
            f['updatedAt'] = now_iso()
            r = fm.compute(f)
            if not r['ok']:
                return self._json(400, {'error': 'Missing ' + ', '.join(r['missing']) + '.'})
            with LOCK:
                fl = flights()
                old = next((x for x in fl if x['id'] == fid), None)
                f.setdefault('createdAt', (old or {}).get('createdAt') or now_iso())
                if old and 'imported' not in data:
                    f['imported'] = old.get('imported', False)
                fl = [x for x in fl if x['id'] != fid] + [f]
                save('flights.json', {'flights': fl})
            changed()
            return self._json(200, {'ok': True, 'flight': f})
        if p == '/api/settings':
            with LOCK:
                s = settings()
                for k in ('seat', 'anon_tail', 'model'):
                    if k in data and str(data[k]).strip():
                        s[k] = str(data[k]).strip()
                if data.get('time_fmt') in ('hm', 'dec'):
                    s['time_fmt'] = data['time_fmt']
                if any(k in data for k in ('csv_names', 'csv_off', 'csv_extra', 'csv_show')):
                    names = data.get('csv_names', s.get('csv_names')) or {}
                    off = data.get('csv_off', s.get('csv_off')) or []
                    extra_in = data.get('csv_extra', s.get('csv_extra')) or []
                    if not isinstance(names, dict) or not isinstance(off, list) or not isinstance(extra_in, list):
                        return self._json(400, {'error': 'Bad column settings.'})
                    if len(extra_in) > 30:
                        return self._json(400, {'error': 'You can add up to 30 columns.'})
                    extra = []
                    for x in extra_in:
                        x = x if isinstance(x, dict) else {}
                        name = str(x.get('name') or '').strip()[:80]
                        src = str(x.get('source') or 'text')
                        if not name:
                            return self._json(400, {'error': 'Every added column needs a header name.'})
                        if src not in ('text', 'field') and src not in fm.CSV_SOURCES:
                            return self._json(400, {'error': f'"{name}" has an unknown value.'})
                        cid = str(x.get('id') or '')
                        if not re.fullmatch(r'[a-z0-9]{1,16}', cid) or any(e['id'] == cid for e in extra):
                            cid = 'c' + secrets.token_hex(4)
                        extra.append({'id': cid, 'name': name, 'source': src,
                                      'text': str(x.get('text') or '')[:200] if src in ('text', 'field') else ''})
                    names = {}  # standard headers can no longer be renamed
                    off = [c for c in fm.CSV_COLS if c in off]
                    if len(off) == len(fm.CSV_COLS) and not extra:
                        return self._json(400, {'error': 'Keep at least one column.'})
                    headers = fm.csv_layout({'csv_names': names, 'csv_off': off, 'csv_extra': extra})[1]
                    dup = sorted({h for h in headers if [x.lower() for x in headers].count(h.lower()) > 1})
                    if dup:
                        return self._json(400, {'error': 'Two columns are both named ' + ', '.join(f'"{d}"' for d in dup) + '.'})
                    show_in = data.get('csv_show', s.get('csv_show')) or []
                    ids = {e['id'] for e in extra}
                    show = [k for k in show_in if isinstance(k, str) and (k in fm.CSV_COLS or k in ids)] if isinstance(show_in, list) else []
                    s['csv_names'], s['csv_off'], s['csv_extra'], s['csv_show'] = names, off, extra, show
                save('settings.json', s)
            changed()
            return self._json(200, {'ok': True, 'settings': s})
        self._json(404, {'error': 'Not found'})

    def do_DELETE(self):
        if not self._guard():
            return
        p = self._route()
        if p.startswith('/api/flights/'):
            fid = urllib.parse.unquote(p.split('/api/flights/', 1)[1])
            with LOCK:
                save('flights.json', {'flights': [x for x in flights() if x['id'] != fid]})
            changed()
            return self._json(200, {'ok': True})
        self._json(404, {'error': 'Not found'})

    def do_POST(self):
        if not self._guard():
            return
        p = self._route()
        if p == '/api/login':
            pw = options()['app_password']
            try:
                given = json.loads(self._body() or b'{}').get('password', '')
            except Exception:
                given = ''
            if pw and not hmac.compare_digest(given.encode('utf-8'), pw.encode('utf-8')):
                time.sleep(1)
                return self._json(401, {'error': 'Wrong password.'})
            body = json.dumps({'ok': True}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            if pw:
                self.send_header('Set-Cookie', f'oooi_auth={auth_token(pw)}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax')
            self.end_headers()
            self.wfile.write(body)
            return
        if p == '/api/scan':
            try:
                img = self._body()
            except ValueError:
                return self._json(413, {'error': 'Photo is too large.'})
            code, res = gemini_scan(img)
            return self._json(code, res)
        if p == '/api/flights/mark-imported':
            n = 0
            with LOCK:
                fl = flights()
                for f in fl:
                    if not f.get('imported'):
                        f['imported'], f['importedAt'], f['updatedAt'] = True, now_iso(), now_iso()
                        n += 1
                save('flights.json', {'flights': fl})
            changed()
            return self._json(200, {'ok': True, 'count': n})
        if p == '/api/drive/connect':
            try:
                return self._json(200, start_device_flow())
            except ValueError as e:
                return self._json(400, {'error': str(e)})
            except HttpError as e:
                return self._json(502, {'error': f'Google refused the sign-in request ({e.status}). Check the client ID and that its type is "TVs and Limited Input devices".'})
            except Exception as e:
                return self._json(502, {'error': f'Could not reach Google: {e}'})
        if p == '/api/airports/update':
            try:
                res = update_airports()
            except RuntimeError as e:
                return self._json(502, {'error': str(e)})
            changed()
            return self._json(200, {'ok': True, **res, 'airports': airports_info()})
        if p == '/api/history/import':
            try:
                body = self._body()
            except ValueError:
                return self._json(413, {'error': 'That file is over 25 MB.'})
            try:
                entries, summary = hist.parse(body)
            except ValueError as e:
                return self._json(400, {'error': str(e)})
            except Exception:
                log.exception('history import failed')
                return self._json(400, {'error': "Couldn't read that file. Use the CSV download from MyFlightbook."})
            name = urllib.parse.unquote(self.headers.get('X-File-Name') or '')[:120]
            with LOCK:
                save('history.json', {'imported_at': now_iso(), 'file': name, 'summary': summary, 'entries': entries})
            log.info('Imported MyFlightbook history: %d flights (%s to %s)', summary['flights'], summary['first'], summary['last'])
            return self._json(200, {'ok': True, 'history': history_info()})
        if p == '/api/history/delete':
            with LOCK:
                try:
                    os.remove(_path('history.json'))
                except FileNotFoundError:
                    pass
            return self._json(200, {'ok': True})
        if p == '/api/drive/cancel':
            DEVICE['pending'] = None
            return self._json(200, {'ok': True})
        if p == '/api/drive/sync':
            ok = do_sync()
            return self._json(200 if ok else 502, {'ok': ok, 'drive': state()['drive']})
        if p == '/api/drive/disconnect':
            with LOCK:
                g = google_state()
                tok = g.get('refresh_token')
                save('google.json', {})
            if tok:
                try:
                    form_post('https://oauth2.googleapis.com/revoke', {'token': tok})
                except Exception:
                    pass
            return self._json(200, {'ok': True})
        self._json(404, {'error': 'Not found'})


def main():
    os.makedirs(DATA, exist_ok=True)
    if load('airports_meta.json', {}).get('updated') and os.path.isfile(_path('airports.js')):
        fm.load_airports(_path('airports.js'))
    log.info('Airport database: %d airports (%s)', len(fm.AP), airports_info()['source'])
    write_local_files()
    srv = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    direct = ThreadingHTTPServer(('0.0.0.0', DIRECT_PORT), type('DirectHandler', (Handler,), {'DIRECT': True}))
    threading.Thread(target=direct.serve_forever, daemon=True).start()
    log.info('OOOI Flight Logger listening on %d (ingress) and %d (direct, %s), data %s, files %s', PORT, DIRECT_PORT,
             'password on' if options()['app_password'] else 'no password', DATA, SHARE)
    if google_state().get('refresh_token'):
        schedule_sync(3)
    srv.serve_forever()


if __name__ == '__main__':
    main()
