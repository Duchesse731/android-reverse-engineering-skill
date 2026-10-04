import json
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch
from test_engine import apk_bytes
import server

class HttpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.token = 'a' * 40
        self.patches = [patch.object(server, 'ROOT', Path(self.temp.name)),patch.object(server, 'TOKEN', self.token),patch.dict(server.JOBS, {}, clear=True)]
        for p in self.patches: p.start()
        server.initialize()
        self.http = server.ThreadingHTTPServer(('127.0.0.1',0),server.Handler)
        threading.Thread(target=self.http.serve_forever,daemon=True).start()
        self.base = 'http://127.0.0.1:' + str(self.http.server_port)
    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        for p in reversed(self.patches): p.stop()
        self.temp.cleanup()
    def request(self,path,data=None,auth=True,headers=None):
        values = {'Authorization':'Bearer '+self.token} if auth else {}
        values.update(headers or {})
        return urllib.request.urlopen(urllib.request.Request(self.base+path,data=data,headers=values),timeout=3)
    def test_authentication_required(self):
        with self.assertRaises(urllib.error.HTTPError) as error: self.request('/api/health',auth=False)
        self.assertEqual(error.exception.code,401)
    def test_invalid_upload_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as error: self.request('/api/jobs',b'not a zip',headers={'X-File-Name':'app.apk'})
        self.assertEqual(error.exception.code,400)
        self.assertFalse(list(server.ROOT.iterdir()))
    def test_upload_job_report_and_download(self):
        data = apk_bytes({'AndroidManifest.xml':b'manifest','classes.dex':b'dex'})
        with self.request('/api/jobs',data,headers={'X-File-Name':'test.apk'}) as response:
            self.assertEqual(response.status,202)
            job_id = json.load(response)['id']
        for _ in range(40):
            with self.request('/api/jobs/'+job_id) as response: state=json.load(response)
            if state['status'] not in ('queued','running'): break
            time.sleep(.05)
        self.assertEqual(state['status'],'partial')
        self.assertEqual(state['filename'],'test.apk')
        with self.request('/api/jobs/'+job_id+'/download') as response:
            self.assertEqual(response.headers['Content-Type'],'application/zip')
            self.assertTrue(response.read().startswith(b'PK'))
        self.assertFalse((server.ROOT/job_id/'app.apk').exists())
    def test_restart_marks_running_job_interrupted(self):
        job_id = 'b'*32
        directory = server.ROOT/job_id
        directory.mkdir()
        (directory/'status.json').write_text(json.dumps({'id':job_id,'status':'running'}))
        (directory/'app.apk').write_bytes(b'original')
        server.initialize()
        self.assertEqual(server.JOBS[job_id]['status'],'failed')
        self.assertFalse((directory/'app.apk').exists())
    def test_retention_removes_old_completed_job(self):
        import os
        directory=server.ROOT/('c'*32)
        directory.mkdir()
        os.utime(directory,(time.time()-server.RETENTION-5,)*2)
        server.cleanup()
        self.assertFalse(directory.exists())
