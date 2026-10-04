import io
import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'service'))
import engine

def apk_bytes(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        for name, content in files.items(): archive.writestr(name, content)
    return output.getvalue()

class EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.apk = self.root / 'app.apk'
    def tearDown(self): self.temp.cleanup()
    def write(self, files): self.apk.write_bytes(apk_bytes({'AndroidManifest.xml': b'manifest', **files}))
    def test_routes_flutter_native_and_hermes(self):
        self.write({'classes.dex':b'dex', 'lib/arm64-v8a/libapp.so':b'app', 'lib/arm64-v8a/libflutter.so':b'flutter', 'assets/index.android.bundle':bytes.fromhex('c61fbc03c103191f')+b'bytecode'})
        facts = engine.inspect_apk(self.apk)
        self.assertTrue(facts['flutter_arm64'])
        self.assertTrue(facts['has_dex'])
        self.assertEqual(len(facts['native_libraries']), 2)
        self.assertEqual(facts['hermes_bundles'], ['assets/index.android.bundle'])
    def test_plain_react_native_is_not_hermes(self):
        self.write({'assets/index.android.bundle':b'function main() {}'})
        self.assertEqual(engine.inspect_apk(self.apk)['hermes_bundles'], [])
    def test_rejects_non_app(self):
        self.apk.write_bytes(apk_bytes({'example.txt': b'not apk'}))
        with self.assertRaises(ValueError): engine.inspect_apk(self.apk)
    def test_expansion_limit(self):
        self.write({'classes.dex':b'1234'})
        with patch.object(engine, 'MAX_EXPANDED', 2), self.assertRaises(ValueError): engine.inspect_apk(self.apk)
    def test_generated_destination_prevents_zip_path_escape(self):
        self.write({'../../escape':b'data'})
        destination = self.root / 'safe.bin'
        engine.extract_member(self.apk, '../../escape', destination)
        self.assertEqual(destination.read_bytes(), b'data')
    def test_missing_engines_report_partial_and_remove_original(self):
        self.write({'classes.dex':b'dex'})
        updates = []
        with patch.dict(os.environ, {'APKTOOL_JAR':'/nonexistent/tool.jar','MOBSF_URL':'','MOBSF_API_KEY':''}):
            report = engine.analyze(self.apk, self.root, lambda **values: updates.append(values))
        self.assertEqual(updates[-1]['status'], 'partial')
        self.assertEqual([r['status'] for r in report['tools']], ['unavailable','unavailable','not_needed','not_needed','not_needed'])
        self.assertFalse(self.apk.exists())
        with zipfile.ZipFile(self.root / 'results.zip') as archive:
            self.assertIn('report.json', archive.namelist())
    def test_subprocess_timeout(self):
        with self.assertRaises(RuntimeError): engine.run_process([sys.executable,'-c','import time; time.sleep(20)'],self.root/'tool.log',.1)
    def test_failed_subprocess(self):
        with self.assertRaises(RuntimeError): engine.run_process([sys.executable,'-c','raise SystemExit(7)'],self.root/'tool.log',2)

if __name__ == '__main__': unittest.main()
