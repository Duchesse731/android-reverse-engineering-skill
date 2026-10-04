"""Offline regressions: source fixtures, ZIP markers, and deterministic tool stubs."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'plugins/android-reverse-engineering/skills/android-reverse-engineering/scripts'


def module(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def run(name, *args, env=None):
    prefix = ['python3'] if name.endswith('.py') else ['bash']
    return subprocess.run(prefix + [str(SCRIPTS / name)] + list(map(str, args)), input='', text=True, capture_output=True, env=env, timeout=15)


class RegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.t = Path(self.temp.name)
        self.src = self.t / 'sources'
        self.src.mkdir()

    def source(self, name, text):
        p = self.src / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        return p

    def apk(self, name='test.apk', descriptors=(), extra=None):
        p = self.t / name
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('classes.dex', b'\0'.join(d.encode() for d in descriptors))
            z.writestr('AndroidManifest.xml', '<manifest/>')
            for name, content in (extra or {}).items():
                z.writestr(name, content)
        return p

    def test_auth_search_reports_keys_base_urls_and_signing(self):
        self.source('Auth.java', 'String API_KEY = "DEMO"; String BASE_URL = "https://demo.test"; String Authorization = "Bearer DEMO"; String signing_key = "DEMO";')
        r = run('find-api-calls.sh', self.src, '--auth')
        self.assertEqual(r.returncode, 0, r.stderr)
        for key in ('API_KEY', 'BASE_URL', 'Authorization', 'signing_key'):
            self.assertIn(key, r.stdout)

    def test_retrofit_paths_and_empty_search(self):
        self.source('Api.java', '@POST("auth/login") void login();')
        self.assertIn('auth/login', run('find-api-calls.sh', self.src, '--retrofit').stdout)
        self.assertIn('"auth/login"', run('find-api-calls.sh', self.src, '--paths').stdout)
        self.assertEqual(run('find-api-calls.sh', self.src, '--ktor').returncode, 0)

    def test_compose_and_obfuscation_use_dex_markers(self):
        names = ['Landroidx/compose/runtime/Composer;', 'Lcom/app/BuildConfig;']
        names += [f'L{chr(97+i//26)}{chr(97+i%26)}/Demo;' for i in range(40)]
        r = run('fingerprint.py', self.apk(descriptors=names))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Jetpack Compose', r.stdout)
        self.assertIn('HIGH (40 short root packages', r.stdout)
        self.assertIn('BuildConfig:      descriptor detected', r.stdout)

    def test_invalid_and_empty_bundle_fail(self):
        bad = self.t / 'bad.apk'; bad.write_text('not ZIP')
        self.assertNotEqual(run('fingerprint.py', bad).returncode, 0)
        empty = self.t / 'empty.xapk'
        with zipfile.ZipFile(empty, 'w') as z: z.writestr('manifest.json', '{}')
        self.assertNotEqual(run('fingerprint.py', empty).returncode, 0)

    def test_xapk_consolidates_split_native_libraries(self):
        base = self.apk(descriptors=['Lio/ktor/client/HttpClient;'])
        split = self.apk('split.apk', extra={'lib/arm64-v8a/libflutter.so': b'fixture'})
        bundle = self.t / 'app.xapk'
        with zipfile.ZipFile(bundle, 'w') as z:
            z.writestr('base.apk', base.read_bytes()); z.writestr('config.arm64.apk', split.read_bytes())
        r = run('fingerprint.py', bundle)
        self.assertIn('Framework:        Flutter', r.stdout)
        self.assertIn('Ktor', r.stdout)
        self.assertIn('libflutter.so', r.stdout)

    def test_no_dex_marks_obfuscation_unknown(self):
        p = self.t / 'resources.apk'
        with zipfile.ZipFile(p, 'w') as z: z.writestr('AndroidManifest.xml', '<manifest/>')
        self.assertIn('UNKNOWN', run('fingerprint.py', p).stdout)

    def test_kotlin_dependency_is_not_assigned_as_owner(self):
        self.source('a/b.java', '@Metadata(d2 = {"", "Lcom/other/Dependency;", "Lcom/app/ActualClass;"}) class b {}')
        self.source('a/c.java', '@kotlin.coroutines.jvm.internal.DebugMetadata(c = "com.app.Repository$fetch$1") class c {}')
        self.source('a/d.java', '@Metadata(d2 = {"Lcom/app/PossibleSelf;", "Lcom/other/Dependency;"}) class d {}')
        self.source('a/e.java', '/* renamed from: a.f */ class e {}')
        self.source('a/Outer.java', 'class Outer { @DebugMetadata(c = "com.app.Unrelated$run$1") static class Inner {} }')
        out = self.t / 'mapping'
        r = run('recover-kotlin-names.py', self.src, out)
        self.assertEqual(r.returncode, 0, r.stderr)
        mapping = json.loads((out / 'mapping.json').read_text())
        self.assertEqual(mapping, {'a.c': 'com.app.Repository'})
        self.assertEqual(json.loads((out / 'candidates.json').read_text())['a.d']['candidate'], 'com.app.PossibleSelf')
        self.assertEqual(json.loads((out / 'evidence.json').read_text())['a.c']['confidence'], 'hint')
        self.assertIn('owner hint', run('lookup-name.sh', out, '-o', 'a.c').stdout)

    def tools(self, jadx='success', java='success', d2j='success'):
        tools = self.t / 'bin'; tools.mkdir(exist_ok=True)
        def write(name, body):
            p = tools / name; p.write_text('#!/usr/bin/env python3\n' + body); p.chmod(0o755)
        write('jadx', f'''import pathlib,sys
if {jadx!r} == 'fail': sys.exit(1)
if {jadx!r} == 'empty': sys.exit(0)
out=pathlib.Path(sys.argv[sys.argv.index('-d')+1])/'sources'; out.mkdir(parents=True,exist_ok=True); (out/'Test.java').write_text('class Test {{}}')
sys.exit(2 if {jadx!r} == 'partial' else 0)
''')
        write('java', f'''import pathlib,sys,zipfile
if {java!r} == 'fail': sys.exit(1)
out=pathlib.Path(sys.argv[-1]); out.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(out/pathlib.Path(sys.argv[-2]).name,'w') as z: z.writestr('com/app/Test.java','class Test {{}}')
''')
        write('d2j-dex2jar', f'''import pathlib,sys,zipfile
if {d2j!r} == 'fail': sys.exit(1)
p=pathlib.Path(sys.argv[sys.argv.index('-o')+1]);p.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(p,'w') as z: z.writestr('Test.class',b'fixture')
''')
        ff = self.t / 'vineflower.jar'; ff.write_text('fixture')
        env = os.environ.copy(); env['PATH'] = str(tools) + os.pathsep + env['PATH']; env['FERNFLOWER_JAR_PATH'] = str(ff)
        return env

    def test_jadx_failure_has_nonzero_exit(self):
        r = run('decompile.sh', '-o', self.t / 'output', self.apk(), env=self.tools(jadx='fail'))
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('Decompilation complete', r.stdout)

    def test_success_exit_without_sources_is_failure(self):
        r = run('decompile.sh', '-o', self.t / 'output', self.apk(), env=self.tools(jadx='empty'))
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('Decompilation complete', r.stdout)

    def test_invalid_arguments_are_not_success(self):
        self.assertNotEqual(run('decompile.sh').returncode, 0)
        self.assertNotEqual(run('decompile.sh', '--bogus').returncode, 0)

    def test_jadx_partial_output_is_preserved(self):
        out = self.t / 'output'
        r = run('decompile.sh', '-o', out, self.apk(), env=self.tools(jadx='partial'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('partial success', r.stderr)
        self.assertTrue((out / 'sources/Test.java').exists())

    def test_both_engines_retain_independent_success(self):
        for jadx, java in [('fail', 'success'), ('success', 'fail')]:
            with self.subTest(jadx=jadx, java=java):
                out = self.t / f'{jadx}-{java}'
                r = run('decompile.sh', '--engine', 'both', '-o', out, self.apk(), env=self.tools(jadx, java))
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertTrue(list(out.rglob('*.java')))

    def test_aar_uses_jvm_jars_without_dex2jar(self):
        aar = self.t / 'library.aar'
        jar = io.BytesIO()
        with zipfile.ZipFile(jar, 'w') as z: z.writestr('Test.class', b'fixture')
        with zipfile.ZipFile(aar, 'w') as z:
            z.writestr('AndroidManifest.xml', '<manifest/>'); z.writestr('classes.jar', jar.getvalue()); z.writestr('libs/helper.jar', jar.getvalue())
        out = self.t / 'output'
        r = run('decompile.sh', '--engine', 'fernflower', '-o', out, aar, env=self.tools(d2j='fail'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(list(out.glob('*-classes/sources/com/app/Test.java')))
        self.assertTrue(list(out.glob('*-helper/sources/com/app/Test.java')))

    def test_xapk_skips_resource_only_splits(self):
        base = self.apk(descriptors=['Lcom/app/Main;'])
        config = self.t / 'config.apk'
        with zipfile.ZipFile(config, 'w') as z: z.writestr('resources.arsc', b'fixture')
        bundle = self.t / 'bundle.xapk'
        with zipfile.ZipFile(bundle, 'w') as z:
            z.writestr('base.apk', base.read_bytes()); z.writestr('config.apk', config.read_bytes())
        r = run('decompile.sh', '-o', self.t / 'output', bundle, env=self.tools())
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Skipping resource-only split', r.stdout)

    def test_stale_output_is_rejected(self):
        out = self.t / 'output'; out.mkdir(); (out / 'old.java').write_text('old')
        r = run('decompile.sh', '-o', out, self.apk(), env=self.tools(jadx='fail'))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('not empty', r.stderr)
        self.assertEqual((out / 'old.java').read_text(), 'old')

    def test_vineflower_local_install_is_discovered(self):
        env = self.tools()
        env.pop('FERNFLOWER_JAR_PATH')
        home = self.t / 'home'; jar = home / '.local/share/vineflower/vineflower.jar'; jar.parent.mkdir(parents=True); jar.write_text('fixture')
        env['HOME'] = str(home)  # Isolated subprocess home, never changes session HOME.
        r = run('decompile.sh', '--engine', 'fernflower', '-o', self.t / 'output', self.apk(), env=env)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_release_digest_accepts_match_rejects_mismatch_and_missing(self):
        verifier = module('verify-release')
        asset = self.t / 'tool.zip'; asset.write_bytes(b'fixture')
        url = 'https://github.com/owner/repo/releases/download/v1/tool.zip'
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()
        for value, valid in [('sha256:' + digest, True), ('sha256:' + '0' * 64, False), (None, False)]:
            response = io.BytesIO(json.dumps({'assets': [{'name': 'tool.zip', 'digest': value}]}).encode())
            with patch.object(verifier.urllib.request, 'urlopen', return_value=response):
                if valid: verifier.verify(url, asset)
                else:
                    with self.assertRaises(ValueError): verifier.verify(url, asset)
        with self.assertRaises(ValueError): verifier.verify('https://other.test/tool.zip', asset)

    def test_shell_syntax(self):
        for script in SCRIPTS.glob('*.sh'):
            r = subprocess.run(['bash', '-n', str(script)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, f'{script.name}: {r.stderr}')


if __name__ == '__main__':
    unittest.main()
