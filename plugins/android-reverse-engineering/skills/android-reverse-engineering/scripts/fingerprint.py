#!/usr/bin/env python3
"""Inspect APK ZIP members and printable DEX descriptors without executing app code."""
import argparse
import io
import re
import sys
import zipfile
from pathlib import Path


def inspect(path):
    entries, descriptors = set(), set()

    def apk(data):
        with zipfile.ZipFile(data) as archive:
            for member in archive.infolist():
                entries.add(member.filename)
                if re.fullmatch(r'classes\d*\.dex', member.filename):
                    descriptors.update(m.decode('ascii') for m in re.findall(
                        rb'L[a-zA-Z][a-zA-Z0-9_]*(?:/[a-zA-Z0-9_$]+)+;', archive.read(member)))

    if path.suffix.lower() == '.apk':
        apk(path)
    elif path.suffix.lower() in ('.xapk', '.apks', '.apkm'):
        with zipfile.ZipFile(path) as bundle:
            members = [x for x in bundle.infolist() if x.filename.lower().endswith('.apk')]
            if not members:
                raise ValueError('Bundle contains no APK files')
            for member in members:
                apk(io.BytesIO(bundle.read(member)))
    else:
        raise ValueError('Expected APK, XAPK, APKS, or APKM')
    names = {d[1:-1] for d in descriptors}
    markers = '\n'.join(sorted(entries | names))
    has = lambda pattern: re.search(pattern, markers, re.M) is not None
    framework, rationale = 'Native Android (Java/Kotlin)', 'no cross-platform markers found'
    for pattern, label, reason in (
        (r'^lib/[^/]+/libflutter\.so$|^assets/flutter_assets/', 'Flutter', 'Flutter assets or native runtime'),
        (r'^lib/[^/]+/(libhermes|libreactnativejni|libreactnative)\.so$|^assets/index\.android\.bundle$', 'React Native', 'React Native runtime or JS bundle'),
        (r'^assets/(www|public)/index\.html$|^assets/www/cordova\.js$', 'Cordova / Capacitor', 'WebView HTML/JS shell'),
        (r'^lib/[^/]+/(libmonodroid|libmaui)\.so$|^assemblies/', 'Xamarin / .NET MAUI', '.NET runtime or assemblies'),
        (r'^androidx/compose/', 'Native Android (Kotlin + Jetpack Compose)', 'Compose DEX descriptors'),
        (r'^META-INF/.*\.kotlin_module$|^kotlin/', 'Native Android (Kotlin)', 'Kotlin metadata or runtime'),
    ):
        if has(pattern):
            framework, rationale = label, reason
            break
    short = {n.split('/')[0] for n in names if re.match(r'^[a-z]{1,2}/', n)}
    level = 'HIGH' if len(short) > 30 else 'MODERATE' if len(short) > 10 else 'LOW'
    if not descriptors:
        obfuscation = 'UNKNOWN (no DEX descriptors found)'
    else:
        obfuscation = f'{level} ({len(short)} short root packages; heuristic, not proof)'
    stacks = [label for pattern, label in (
        ('retrofit2/', 'Retrofit'), ('okhttp3/', 'OkHttp'), ('io/ktor/', 'Ktor'),
        ('com/apollographql/', 'Apollo (GraphQL)'), ('com/android/volley/', 'Volley')) if has(pattern)]
    di = [label for pattern, label in (('dagger/hilt/', 'Hilt'), ('dagger/', 'Dagger'), ('org/koin/', 'Koin'), ('javax/inject/', 'javax.inject')) if has(pattern)]
    serial = [label for pattern, label in (('kotlinx/serialization/', 'kotlinx.serialization'), ('com/google/gson/', 'Gson'), ('com/squareup/moshi/', 'Moshi'), ('com/fasterxml/jackson/', 'Jackson')) if has(pattern)]
    sdk_patterns = {'AppsFlyer':'com/appsflyer/', 'Datadog':'com/datadog/', 'Sentry':'io/sentry/', 'Firebase':'com/google/firebase/', 'Google Play Services':'com/google/android/gms/', 'Facebook SDK':'com/facebook/', 'Stripe':'com/stripe/', 'Braintree':'com/braintreepayments/', 'PayU':'com/payu/', 'Zendesk':'zendesk/', 'Intercom':'io/intercom/', 'Segment':'com/segment/', 'Amplitude':'com/amplitude/', 'Mixpanel':'com/mixpanel/', 'OneSignal':'com/onesignal/', 'Microsoft Clarity':'com/microsoft/clarity/', 'Hotjar':'com/hotjar/', 'Instabug':'com/instabug/', 'Storyteller':'com/storyteller/'}
    sdks = [label for label, pattern in sdk_patterns.items() if has(pattern)]
    print(f'=== APK Fingerprint: {path.name} ===\n')
    print(f'Framework:        {framework}\n  Rationale:      {rationale}')
    print(f'Obfuscation:      {obfuscation}')
    print('HTTP stack:       ' + (', '.join(stacks) or 'none detected'))
    print('DI:               ' + (', '.join(di) or 'none detected'))
    print('Serialization:    ' + (', '.join(serial) or 'none detected'))
    print('BuildConfig:      ' + ('descriptor detected' if has(r'(^|/)BuildConfig$') else 'not detected; inspect decompiled sources'))
    print('Third-party SDKs: ' + (', '.join(sdks) or 'none detected'))
    print('\nNative libraries (consolidated across splits):')
    libs = sorted(e for e in entries if re.fullmatch(r'lib/[^/]+/[^/]+\.so', e))
    print('\n'.join('  ' + e for e in libs) or '  (none)')
    print('\nRecommended next step:')
    if framework.startswith('Flutter'):
        print('  Inspect libapp.so using Flutter-specific tools; Java output is only the host.')
    elif framework.startswith('React'):
        print('  Inspect the JS/Hermes bundle using matching tools; Java output is only the host.')
    elif framework.startswith('Cordova'):
        print('  Inspect HTML/JS in assets/www or assets/public.')
    elif framework.startswith('Xamarin'):
        print('  Inspect .NET assemblies using ILSpy or equivalent tooling.')
    else:
        print('  Proceed with jadx decompilation; review heuristic findings against code.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path)
    args = parser.parse_args()
    try:
        inspect(args.file)
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as exc:
        parser.exit(1, f'Error: {exc}\n')


if __name__ == '__main__':
    main()
