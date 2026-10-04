#!/usr/bin/env python3
"""Index surviving Kotlin name hints. Never infer an owner from a referenced type."""
import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

DEBUG = re.compile(r'@(?:[\w.]+\.)?DebugMetadata\([^)]*?c\s*=\s*"([^"\n]+)"', re.S)
META = re.compile(r'@(?:[\w.]+\.)?Metadata\([^)]*?d2\s*=\s*\{([^}]*)\}', re.S)
# Kotlin class metadata's first d2 element is a possible self descriptor.
# Inspect ONLY that first element; later entries can be arbitrary dependencies.
SELF = re.compile(r'^\s*"L([\w/$]+);"')
FQN = re.compile(r'^[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+$')
SKIP = ('kotlin.', 'kotlinx.', 'android.', 'androidx.', 'java.', 'javax.', 'org.jetbrains.', 'okhttp3.', 'okio.', 'retrofit2.', 'dagger.', 'io.ktor.')


def recover(src, out):
    if not src.is_dir():
        raise ValueError(f'Not a source directory: {src}')
    mapping, evidence, candidates = {}, {}, {}
    counts = defaultdict(int)
    for path in sorted(src.rglob('*.java')):
        obf = '.'.join(path.relative_to(src).with_suffix('').parts)
        if obf.startswith(SKIP):
            continue
        text = path.read_text(errors='replace')
        declaration = re.search(r'\b(?:class|interface|enum)\s+[A-Za-z_$]', text)
        annotations = text[:declaration.start()] if declaration else ''
        debug = DEBUG.search(annotations)
        if debug and FQN.fullmatch(debug.group(1)):
            # This is a coroutine/outer-class association, not an exact class rename.
            real = debug.group(1).split('$', 1)[0]
            mapping[obf] = real
            evidence[obf] = {'kind': 'debug_metadata_outer_class', 'confidence': 'hint', 'file': str(path), 'metadata_class': debug.group(1)}
            counts['debug_metadata_outer_class'] += 1
        else:
            meta = META.search(annotations)
            own = SELF.match(meta.group(1)) if meta else None
            if own:
                real = own.group(1).replace('/', '.')
                if FQN.fullmatch(real) and real != obf:
                    # Metadata may be rewritten by the shrinker. Keep unverified self
                    # descriptors separate from the lookup map, not as certain names.
                    candidates[obf] = {'candidate': real, 'kind': 'metadata_first_descriptor', 'confidence': 'unverified', 'file': str(path)}
    out.mkdir(parents=True, exist_ok=True)
    package_dir = out / 'by_package'
    package_dir.mkdir(exist_ok=True)
    # Remove stale generated indexes when re-running on changed sources.
    for old in package_dir.glob('*.txt'):
        old.unlink()
    (out / 'mapping.json').write_text(json.dumps(mapping, indent=2, sort_keys=True) + '\n')
    (out / 'evidence.json').write_text(json.dumps(evidence, indent=2, sort_keys=True) + '\n')
    (out / 'candidates.json').write_text(json.dumps(candidates, indent=2, sort_keys=True) + '\n')
    rows = ['obf_fqn\treal_fqn\tfile\tkind\tconfidence']
    packages = defaultdict(list)
    for obf, real in sorted(mapping.items()):
        e = evidence[obf]
        rows.append(f'{obf}\t{real}\t{e["file"]}\t{e["kind"]}\t{e["confidence"]}')
        packages[real.rsplit('.', 1)[0]].append(f'{real}\t{obf}\t{e["file"]}')
    (out / 'mapping.tsv').write_text('\n'.join(rows) + '\n')
    for pkg, lines in packages.items():
        (package_dir / (pkg.replace('.', '_') + '.txt')).write_text('\n'.join(lines) + '\n')
    print(f'Indexed {len(mapping)} coroutine owner hints; {len(candidates)} unverified metadata candidates')
    print('No recovery percentage is guaranteed. Validate hints against declarations and call sites.')
    print(f'Wrote {out}/mapping.tsv, mapping.json, evidence.json, candidates.json, by_package/')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('sources', type=Path)
    parser.add_argument('output', type=Path, nargs='?')
    args = parser.parse_args()
    try:
        recover(args.sources, args.output or args.sources.parent / 'mapping')
    except (ValueError, OSError) as exc:
        parser.exit(1, f'Error: {exc}\n')


if __name__ == '__main__':
    main()
