# SafeCopy Prototype

This repository contains a SafeCopy prototype: a mobile client (Flutter skeleton) and a Python Flask server that receives encrypted print jobs and stores them in-memory for processing.

This README documents the server architecture, the cryptographic flow (ECDH → HKDF → AES‑GCM), endpoint behavior, how to run tests and automation, and security notes for hand-off.

## Repository layout (important files)

- `server/` — Flask server, tests and automation
  - `server.py` — core Flask app: `/print-job`, `/cache/<job_id>`, `/server-pub`
  - `requirements.txt` — Python dependencies
  - `run_tests.ps1` — installs dependencies and runs pytest (PowerShell)
  - `tests/` — unit, ECDH and integration tests (pytest)
- `mobile/` — Flutter mobile skeleton (UI + crypto; requires local Flutter to run)

## High-level overview

SafeCopy prototype goal: allow a mobile device to send a PDF (or other file) securely to a receiving PC for ephemeral printing/processing without writing the raw file to disk.

High-level flow:

1. Mobile generates a JobID and an ephemeral X25519 keypair.
2. Mobile fetches server's X25519 public key (or uses a pre-shared value). Mobile performs ECDH and derives a symmetric key with HKDF.
3. Mobile encrypts the payload using AES‑256‑GCM with the derived key, including JobID|timestamp as AAD.
4. Mobile POSTs JSON to `/print-job` including `job_id`, `timestamp`, `filename`, `payload` (base64 of nonce+ciphertext+tag), and `client_pub` (base64 of client's X25519 pubkey).
5. Server derives the same AES key (server ephemeral private key + client_pub), decrypts the payload in memory, does best-effort zeroing of plaintext, and stores metadata + bytes in an in-memory cache keyed by JobID.

## Crypto flow (detailed)

The server and client use the following steps and primitives:

- Key exchange: X25519 (Curve25519) ephemeral ECDH.
- KDF: HKDF with SHA-256, info = `b"safecopy v1"`, output length = 32 bytes (AES-256 key).
- AEAD: AES‑256‑GCM (12-byte nonce, 16-byte tag). AAD = `job_id|timestamp` (UTF‑8 encoded).

ASCII diagram:

Client (ephemeral key) Server (ephemeral long-term key)

---

generate X25519 keypair SERVER_X25519_PRIVATE
client_pub --------------------------------> server retrieves client_pub
shared = server_priv.exchange(client_pub)
client computes shared = client_priv.exchange(server_pub) <-- server_pub
client hkdf(shared) -> AES key
server hkdf(shared) -> AES key (same)
client AES-GCM encrypt(nonce, plaintext, aad) -> nonce|ciphertext|tag
client POST /print-job {client_pub, payload, job_id, timestamp, filename}
server decrypts and caches plaintext in RAM

Important: the server implementation in this prototype requires `client_pub` (PSK fallback removed).

## Endpoints

- `POST /print-job` — Accepts JSON with fields:

  - `job_id` (string, required)
  - `timestamp` (string, required)
  - `filename` (string, optional but recommended)
  - `payload` (base64 string: nonce + ciphertext + tag, required)
  - `client_pub` (base64 X25519 public key, required)

  Server behavior (prototype):

  - Rejects missing fields or malformed base64 with 400.
  - Rejects duplicate `job_id` with 409.
  - Derives AES-256 key using server private key and `client_pub` via HKDF.
  - Decrypts AES-GCM with AAD=`job_id|timestamp`.
  - Stores the decrypted bytes (and metadata) in the in-memory cache under `job_id` and returns 200.

- `GET /cache/<job_id>` — Returns `{filename, timestamp, size}` or 404 if not found.
- `DELETE /cache/<job_id>` — Removes cache entry and clears JobID.
- `GET /server-pub` — Returns the server's X25519 public key (base64) for client use.

## Tests & automation

There are three types of tests included:

- Unit ECDH test: `tests/test_ecdh_flow.py` — verifies key derivation and decryption in-process.
- Unit server tests: `tests/test_server.py` — verifies decryption, duplicate rejection, and bad payload handling. These tests simulate the client with ephemeral X25519 keys and include `client_pub`.
- Integration test: `tests/test_integration_client_server.py` — starts the Flask dev server in a background thread (on port 5050), runs a simulated client over HTTP (`requests`) and verifies `/cache/<job_id>`.

To run tests locally on Windows PowerShell (from `server/`):

```powershell
# from c:\...\safecopy_prototype\server
python -m pip install -r requirements.txt
python -m pytest -q
```

You can also use the included helper script:

```powershell
./run_tests.ps1
```

CI: the test scripts are written to run in a headless CI environment. The integration test binds to `127.0.0.1:5050` and uses `use_reloader=False` so it is CI-friendly. For GitHub Actions you can run the same commands on a Windows or Linux runner (adjust the PowerShell steps accordingly).

## Security notes & deployment guidance

- Prototype choices and limitations

  - This is a development prototype. The Flask dev server is used in tests and is not suitable for production. Use a WSGI server (gunicorn/uvicorn) behind TLS in production.
  - PSK fallback has been removed from the prototype — the server requires `client_pub` and ECDH-based key derivation.
  - The server performs best-effort memory zeroing of plaintext (overwriting a local `bytearray`) but Python cannot guarantee that no copies remain in memory or swap. For true secure deletion, use a language/platform with explicit secure buffers or a dedicated secure enclave.

- Transport security

  - Always run the server behind TLS (nginx or a reverse proxy) or enable HTTPS using a proper certificate. For local testing, `mkcert` or a self-signed cert is acceptable; do not use self-signed certs in public deployments.

- Key management

  - In production, do not use ephemeral or hardcoded long-term keys without rotation and storage in a secure key-store (HSM / KMS / OS-protected keystore).
  - Consider using client authentication (mTLS) or an authentication token to prevent unauthorized POSTs.

- Concurrency
  - The in-memory cache is protected by a threading.Lock in this prototype. For horizontal scaling or persistence, use a dedicated cache (Redis) or encrypted storage with controlled lifecycle.

## Notes & next steps

- The server includes a cache cleanup thread scaffold (TTL-based), but cache items must be written with a timestamp `_ts` for automatic TTL removal to take effect. Consider adding `_ts = time.time()` when writing cache entries.
- Add a `config.json` (or environment-based config) to hold settings like port, TTL, and certificate paths.
- Replace the Flask dev server with a production-ready WSGI server and add automatic TLS certificate provisioning.

## Contact / Handoff

If you're handing this to another developer or a CI process, share the following:

- Run `./server/run_tests.ps1` (Windows) to install dependencies and validate tests.
- Encourage reviewing `server/server.py` for security-relevant lines (ECDH, HKDF info, AAD formation) before deploying.

---

This README was generated as part of the SafeCopy prototype and is intended to make the repository ready for hand-off or CI setup. If you'd like, I can add a GitHub Actions workflow next that runs tests on push and on PRs.
SafeCopy prototype

This workspace contains two prototypes:

1. mobile/ - Flutter mobile prototype skeleton
2. server/ - Python Flask server prototype

Server (Python) quick start

1. Create a virtualenv and install requirements:

   python -m venv .venv; .\.venv\Scripts\Activate.ps1; python -m pip install -r requirements.txt

2. Run the server:

   python server.py

Note: This is a prototype. The symmetric key is hardcoded for demonstration only.

Mobile (Flutter) quick start

1. Open the `mobile` folder in Android Studio or VS Code.
2. Run `flutter pub get` to fetch dependencies.
3. Edit `lib/main.dart` and set `serverUri` to your PC's LAN IP and ensure the server is running.
4. Run the app on your phone via USB debugging or emulator.

Testing

- Use the mobile app to pick a PDF and send it to the server.
- The server stores the decrypted PDF bytes in an in-memory cache keyed by `job_id`.
- Use GET /cache/<job_id> to inspect cached metadata, DELETE /cache/<job_id> to remove it.

Key-exchange (optional, stronger than pre-shared key)

- The server exposes `GET /server-pub` which returns the server's X25519 public key (base64).
- The mobile client can generate an ephemeral X25519 keypair, fetch the server public key, derive a shared secret, derive a 32-byte AES key via HKDF-SHA256, and then include the client's raw public key (base64) in the `client_pub` field of the `/print-job` JSON. The server will use its private key + the client public key to derive the same AES key and decrypt the payload.

This avoids embedding a long-term pre-shared key in the client and provides forward secrecy when the client uses ephemeral keys.
