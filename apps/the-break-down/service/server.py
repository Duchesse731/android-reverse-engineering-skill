"""Private, disk-backed single-worker analysis API using Python's standard library."""
import concurrent.futures
import hmac
import json
import os
import shutil
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit
from engine import MAX_UPLOAD, TOOLS, analyze, inspect_apk

ROOT = Path(os.environ.get('BREAKDOWN_DATA', '/data')).resolve()
TOKEN = os.environ.get('ENGINE_TOKEN', '')
POOL = concurrent.futures.ThreadPoolExecutor(max_workers=1)
SLOTS = threading.BoundedSemaphore(3)
LOCK = threading.Lock()
JOBS = {}
RETENTION = 7 * 86400

def update_job(job_id, **values):
    with LOCK:
        JOBS[job_id].update(values)
        path = ROOT / job_id / 'status.json'
        temp = path.with_suffix('.tmp')
        temp.write_text(json.dumps(JOBS[job_id]))
        temp.replace(path)

def execute(job_id):
    try:
        update_job(job_id, status='running')
        analyze(ROOT / job_id / 'app.apk', ROOT / job_id,
                lambda **values: update_job(job_id, **values))
    except Exception as error:
        update_job(job_id, status='failed', detail=str(error)[:300])
        (ROOT / job_id / 'app.apk').unlink(missing_ok=True)
    finally:
        SLOTS.release()

def cleanup():
    with LOCK:
        for directory in ROOT.iterdir():
            if not directory.is_dir(): continue
            state = JOBS.get(directory.name, {})
            if state.get('status') in ('queued', 'running'): continue
            if time.time() - directory.stat().st_mtime > RETENTION:
                shutil.rmtree(directory)
                JOBS.pop(directory.name, None)

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def authorized(self):
        return bool(TOKEN) and hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + TOKEN)
    def send_json(self, payload, code=200):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        if urlsplit(self.path).path == '/healthz': return self.send_json({'ok': True})
        if not self.authorized(): return self.send_json({'error': 'Access denied.'}, 401)
        path = urlsplit(self.path).path
        if path == '/api/health':
            installed = {'MobSF': bool(os.environ.get('MOBSF_URL') and os.environ.get('MOBSF_API_KEY')),
                         'Apktool': Path(os.environ.get('APKTOOL_JAR', '/opt/tools/apktool.jar')).is_file(),
                         'Ghidra': Path(os.environ.get('GHIDRA_HEADLESS', '/opt/tools/ghidra/support/analyzeHeadless')).is_file(),
                         'Blutter': Path(os.environ.get('BLUTTER_SCRIPT', '/opt/tools/blutter/blutter.py')).is_file(),
                         'hermes-dec': bool(shutil.which('hbc-decompiler'))}
            return self.send_json({'connected': True, 'ready': all(installed.values()), 'engines': installed, 'maxUpload': MAX_UPLOAD})
        parts = path.strip('/').split('/')
        if len(parts) not in (3, 4) or parts[:2] != ['api', 'jobs']:
            return self.send_json({'error': 'Not found.'}, 404)
        job_id = parts[2]
        with LOCK: job = JOBS.get(job_id)
        if not job: return self.send_json({'error': 'This result is unavailable or has expired.'}, 404)
        if len(parts) == 3: return self.send_json(job)
        if parts[3] != 'download' or job['status'] not in ('completed', 'partial'):
            return self.send_json({'error': 'The download is not ready.'}, 409)
        file = ROOT / job_id / 'results.zip'
        self.send_response(200)
        self.send_header('Content-Type', 'application/zip')
        self.send_header('Content-Disposition', 'attachment; filename="the-break-down-results.zip"')
        self.send_header('Content-Length', str(file.stat().st_size))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        with file.open('rb') as source: shutil.copyfileobj(source, self.wfile)
    def do_POST(self):
        if not self.authorized():
            self.close_connection = True
            return self.send_json({'error': 'Access denied.'}, 401)
        if urlsplit(self.path).path != '/api/jobs': return self.send_json({'error': 'Not found.'}, 404)
        try: size = int(self.headers.get('Content-Length', '0'))
        except ValueError: size = 0
        if size <= 0 or size > MAX_UPLOAD:
            self.close_connection = True
            return self.send_json({'error': 'Choose an APK under 250 MB.'}, 413)
        name = Path(unquote(self.headers.get('X-File-Name', 'app.apk'))).name
        if not name.lower().endswith('.apk'):
            self.close_connection = True
            return self.send_json({'error': 'Choose an .apk file.'}, 400)
        if not SLOTS.acquire(blocking=False):
            self.close_connection = True
            return self.send_json({'error': 'Analysis is busy. Try again shortly.'}, 429)
        job_id = uuid.uuid4().hex
        directory = ROOT / job_id
        directory.mkdir()
        try:
            self.connection.settimeout(120)
            remaining = size
            with (directory / 'app.apk').open('wb') as output:
                while remaining:
                    data = self.rfile.read(min(1024 * 1024, remaining))
                    if not data: raise ValueError('The upload was interrupted.')
                    output.write(data)
                    remaining -= len(data)
            inspect_apk(directory / 'app.apk')
            with LOCK: JOBS[job_id] = {'id': job_id, 'filename': name[:160], 'created': time.time(), 'status': 'queued', 'progress': 0, 'tools': []}
            update_job(job_id)
            POOL.submit(execute, job_id)
            self.send_json({'id': job_id}, 202)
        except Exception as error:
            shutil.rmtree(directory, ignore_errors=True)
            SLOTS.release()
            self.send_json({'error': str(error)[:300]}, 400)

def initialize():
    if len(TOKEN) < 32: raise RuntimeError('A private ENGINE_TOKEN of at least 32 characters is required.')
    ROOT.mkdir(parents=True, exist_ok=True)
    for file in ROOT.glob('*/status.json'):
        try:
            state = json.loads(file.read_text())
            JOBS[file.parent.name] = state
            if state.get('status') in ('queued', 'running'):
                update_job(file.parent.name, status='failed', detail='Analysis was interrupted. Upload the app again.')
                (file.parent / 'app.apk').unlink(missing_ok=True)
        except (ValueError, OSError): continue
    cleanup()

def janitor():
    while True:
        time.sleep(3600)
        cleanup()

if __name__ == '__main__':
    initialize()
    threading.Thread(target=janitor, daemon=True).start()
    ThreadingHTTPServer(('0.0.0.0', int(os.environ.get('PORT', 8080))), Handler).serve_forever()
