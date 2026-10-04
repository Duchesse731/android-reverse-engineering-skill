# The Break Down

Private browser workspace and automatic static Android analysis service. The user selects an APK, starts analysis, and downloads a combined archive or JSON summary. No commands, scripting, device setup, or programming are exposed in the product.

## Delivery status

The browser, authenticated gateway, queue, durable job status, tool adapters, native export script, and container assembly are implemented. The browser is deployed independently. Full analysis requires a provisioned container server and a connected MobSF instance; a Workers or Netlify frontend cannot execute these native/Python/Java engines. Production APK analysis is not yet verified. Missing engines disable uploads in the browser and remain explicit in service reports.

## Components

- MobSF: main security report through its documented REST API.
- Apktool 3.0.3: resources, manifest and Smali decoding.
- Ghidra 12.1.4: native ELF analysis and bounded pseudocode export.
- Blutter: pinned upstream commit; supported ARM64 Flutter APK analysis.
- hermes-dec: pinned upstream commit; detected Hermes bytecode decompilation.

Apktool and Ghidra downloads are SHA-256 verified. Blutter, Hermes and the MobSF build use pinned commits. Operating-system packages and the base container are not fully reproducibly pinned. Upstream licenses: MobSF GPL-3.0, Apktool/Ghidra Apache-2.0, Blutter MIT, Hermes AGPL-3.0-or-later; this repository contains adapters, not vendored engine code.

## Operator deployment

This section is for the maintainer, not an end-user setup flow.

1. Build the Dockerfile in a Linux container environment with sufficient disk and memory. Blutter additionally builds version-specific Dart components on first use and needs outbound access to official source repositories.
2. Run MobSF privately from the pinned compose build. Obtain its generated REST API key from its administrative interface and configure `MOBSF_API_KEY` only as a service secret.
3. Set `ENGINE_TOKEN` to a generated private value of at least 32 characters, `MOBSF_URL` to the private MobSF HTTP address, and mount writable persistent storage at `/data`. A mounted volume must be writable by UID 10001. No app binaries are executed as applications.
4. Configure `ENGINE_URL` and `ENGINE_TOKEN` as private runtime values on the frontend. `ENGINE_URL` must be an HTTPS endpoint, reachable by the gateway. Do not expose the token to the browser. Preserve the frontend's owner-only access.
5. Validate all engine readiness flags and run owned/authorized APK fixtures through every applicable route before declaring production readiness.

Gateway upload limit: 64 MB. Service upload limit: 250 MB. Expanded inventory limit: 1 GB; 50,000 ZIP entries. Native analysis covers at most 12 libraries and 500 functions per library; Hermes analysis covers at most 8 bundles. Limits appear in reports. Tool subprocesses have bounded execution time and process-group termination. Queue capacity is 3 jobs and 1 active analysis. Results and original uploads have a 7-day retention ceiling; analysis uploads are removed when jobs finish. Cleanup runs hourly and at startup. MobSF's delete-scan API is called after report export, including on scan errors; deletion failures mark that engine failed and require operator investigation. Crash-time orphan cleanup in MobSF must still be configured before production use.

## Verification

`python -m unittest discover -s tests -p 'test_*.py' -v` checks actual ZIP inventory/routing, failed/missing engine reporting, subprocess timeout, authenticated HTTP upload, job status and downloads. `node --test tests/gateway.test.mjs` checks gateway readiness, denied routes and upload limits. These checks are not end-to-end verification of installed analysis engines. Container builds and live MobSF/Ghidra/Blutter runs remain unverified when Docker is unavailable.
