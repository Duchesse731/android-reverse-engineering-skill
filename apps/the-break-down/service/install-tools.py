"""Install pinned upstream engines; verify release downloads before extraction."""
import hashlib
import subprocess
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path('/opt/tools')
ROOT.mkdir(parents=True, exist_ok=True)
RELEASES = [
 ('https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar', 'apktool.jar', 'dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423'),
 ('https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip', 'ghidra.zip', 'ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db')]
for url, name, expected in RELEASES:
    file = ROOT / name
    with urllib.request.urlopen(url, timeout=120) as source, file.open('wb') as out:
        digest = hashlib.sha256()
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            out.write(chunk)
    if digest.hexdigest() != expected: raise RuntimeError('Release checksum mismatch: ' + name)
with zipfile.ZipFile(ROOT / 'ghidra.zip') as archive: archive.extractall(ROOT)
(ROOT / 'ghidra').symlink_to(ROOT / 'ghidra_12.1.4_PUBLIC', target_is_directory=True)
(ROOT / 'ghidra.zip').unlink()
for name, repo, commit in [
 ('blutter','https://github.com/worawit/blutter.git','4a60ac648bf448c5a7596437243bcd0b9376fdf0'),
 ('hermes-dec','https://github.com/P1sec/hermes-dec.git','a0f18f97ab661eb8ed659c8c683a0d21ea619e69')]:
    target = ROOT / name
    subprocess.run(['git','clone',repo,str(target)],check=True)
    subprocess.run(['git','checkout','--detach',commit],cwd=target,check=True)
subprocess.run(['/opt/venv/bin/pip','install','/opt/tools/hermes-dec'],check=True)
