# HANDOFF — SafeCopy Prototype

IMPORTANT: If you're an AI/code-assistant or a developer opening this repository for the first time, read this file fully before making edits or running the project.

This file documents the current development state, how to run tests and the app, changes that were recently made, and known issues with concrete steps to reproduce and fix them.

---

## Summary

- This repo contains two main parts:
  - `server/` — Python Flask prototype server.
  - `mobile/` — Flutter mobile app (also runs on web/Chrome in debug).
- Current status (as of last updates in this branch):
  - Server unit tests: PASS (pytest in `server/tests/`).
  - Mobile widget test: PASS (`mobile/test/widget_test.dart`).
  - Server is runnable via the project's virtualenv.
  - Mobile app can run on Chrome and physical devices.

---

## Files I edited / added (recent changes you must know)

- Added `server/__init__.py` — re-exported `server.server` symbols so tests using `import server` work.
- Added optional CORS support in `server/server.py` (uses `flask-cors` when installed) and installed `flask-cors` in the venv.
- Edited `mobile/pubspec.yaml` — added `flutter_test` under `dev_dependencies` so `flutter test` runs.
- Edited `mobile/lib/main.dart` (multiple changes):
  - Added a `MyApp` wrapper for tests.
  - Default server URL changed to `http://127.0.0.1:5000/print-job` for local dev convenience.
  - Implemented a reusable ephemeral X25519 keypair generated at app init and re-used for uploads.
  - `_encryptPdf` now uses the stored ephemeral keypair and returns `client_pub` as base64.
  - Upload code now includes `client_pub` in the JSON POST body and prints a debug line immediately before sending: `Uploading PDF with client_pub: ...`.
  - Robust construction of `/server-pub` origin and longer timeout for fetching server public key.
- Edited `mobile/test/widget_test.dart` to reflect the real app UI.

---

## How to run (developer steps)

All commands assume Windows PowerShell (project path contains spaces; the examples below use the project root). Replace `<project-root>` with your path if different.

### 1) Server (Python) — prepare environment and run tests

1. Activate / use the project virtualenv (the workspace has `.venv`):

```powershell
# from project root
& ".\.venv\Scripts\Activate.ps1"
# or use the full Python path for commands below
```

2. Install server requirements (if not already installed):

```powershell
& ".\.venv\Scripts\python.exe" -m pip install -r server/requirements.txt
```

3. Run server unit tests:

```powershell
& ".\.venv\Scripts\python.exe" -m pytest server/tests -q
```

4. Start the Flask dev server (keep this terminal open while using mobile/web):

```powershell
& ".\.venv\Scripts\python.exe" ".\server\server.py"
```

Expected output:

```
 * Running on http://127.0.0.1:5000
 * Running on http://<your_pc_ipv4>:5000
```

If you only see `127.0.0.1` restart server ensuring `app.run(host='0.0.0.0', ...)` is used.

### 2) Mobile (Flutter) — tests and dev run

1. Install Flutter SDK (the workspace already had Flutter available on the original machine). Check with:

```powershell
flutter --version
```

2. From `mobile/`, fetch packages:

```powershell
Set-Location -Path ".\mobile"
flutter pub get
```

3. Run widget tests:

```powershell
flutter test --coverage
```

4. Run the app (Chrome or a device):

```powershell
# Chrome
flutter run -d chrome
# Or to run on a connected Android device
flutter run -d <deviceId>
```

Notes: If building to Windows desktop, you need Visual Studio toolchain; `flutter doctor` will report the required workloads.

---

## How to test the ECDH/No-PSK flow (end-to-end)

1. Start the Flask server on the PC and keep the terminal visible.
2. Make sure your phone and PC are on the same Wi‑Fi network.
3. In the phone app: Settings → Server URL → `http://<your_pc_ipv4>:5000` (e.g. `http://10.44.180.237:5000`). Leave PSK blank.
4. Upload a small PDF.
5. Watch the mobile logs (on PC):
   - For Flutter device logs: `flutter logs -d <deviceId>` or use `adb logcat` on Android.
   - You must see two debug prints in the app logs:
     - `Fetching server public key from http://<ip>:5000/server-pub`
     - `Uploading PDF with client_pub: <BASE64>`
6. Watch the Flask server terminal — it should show a `POST /print-job` and a `Stored job ...` info line.

If the app prints `No PSK and key-exchange failed: TimeoutException` then the mobile client could not fetch `/server-pub`. See "Networking troubleshooting" below.

---

## Networking troubleshooting (phone → PC timeouts)

If `http://<your_pc_ipv4>:5000/server-pub` times out in the phone browser:

1. On PC, verify server is listening:

```powershell
# look for process
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'server.py' } | Select ProcessId,CommandLine
# or show listener
netstat -ano | findstr ":5000"
Get-NetTCPConnection -LocalPort 5000 -State Listen | Format-Table -AutoSize
```

2. Test from PC:

```powershell
Invoke-RestMethod -Uri 'http://127.0.0.1:5000/server-pub'
Invoke-RestMethod -Uri 'http://<your_pc_ipv4>:5000/server-pub'
```

3. If the PC cannot reach the LAN IP, ensure `app.run(host='0.0.0.0', port=5000)` is used in `server/server.py` and restart.
4. If PC works but phone doesn't, check firewall/router:

```powershell
# check reachability
Test-NetConnection -ComputerName <your_pc_ipv4> -Port 5000
# To add firewall rule (Admin):
netsh advfirewall firewall add rule name="Allow Flask 5000" dir=in action=allow protocol=TCP localport=5000
```

5. If your Wi‑Fi uses client isolation or a guest network, move both devices to the same (non‑isolated) network.

---

## Known issues & TODOs

- analysis_options.yaml includes `package:flutter_lints/flutter.yaml` but `flutter_lints` is not added in `dev_dependencies`. This triggers an analyzer warning. Quick fix: add `flutter_lints` to `mobile/pubspec.yaml` dev_dependencies and run `flutter pub get`.
- Desktop (Windows) Flutter builds require Visual Studio toolchain (not installed). `flutter doctor` reports exact workloads.
- Some ephemeral Flutter build directories were locked by file handles (OneDrive/VSCode). If `flutter clean` or `flutter run` errors on cleanup, close editors or kill Dart/Flutter processes and retry.

---

## How I validated changes

- Ran `pytest` in `server/tests` (5 tests) — all passed after adding `server/__init__.py`.
- Ran `flutter test` for the widget test — updated the test and it passed.
- Manually tested the Flutter web/Chrome run and mobile changes; added debug prints so you can verify `client_pub` is sent.

---

## If the new teammate is an AI / automation — READ THIS FIRST

- This project contains both Python and Flutter code. When making edits, the AI must:

  1. Run server tests (`pytest`) and mobile tests (`flutter test`) after changes.
  2. Run `flutter analyze` in `mobile/` to catch static issues.
  3. Avoid committing secrets or private keys.
  4. If changing network code, re-run full E2E manually (server + mobile) because tests are limited.

- Important locations:
  - Server implementation & API: `server/server.py`
  - Server tests: `server/tests/`
  - Mobile app entry: `mobile/lib/main.dart`
  - Mobile tests: `mobile/test/`

---

## Recommended next work items (small, safe wins)

- Add `flutter_lints` to `mobile/dev_dependencies` and re-run `flutter analyze`.
- Add a CI workflow (GitHub Actions) that runs server `pytest` and `flutter test` on push.
- Add a tiny integration test that spins up the server and posts an example encrypted payload.
- Add a short `server/README.md` describing endpoints and payload format (server expects `client_pub` when no PSK).

---

## Contact / notes

If you need immediate help reproducing the No-PSK issue, collect and paste the following when asking for help:

- The `Uploading PDF with client_pub:` printed line from the mobile logs (full base64 string).
- The Flask server terminal logs (the POST request handling and any exception stack traces).
- Output of `Invoke-RestMethod` run on your PC for `http://127.0.0.1:5000/server-pub` and `http://<your_pc_ipv4>:5000/server-pub`.

---

End of HANDOFF. Place this file at project root and commit it before handing over the repository.
