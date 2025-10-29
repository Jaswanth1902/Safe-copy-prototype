import base64
import time
import threading
import requests
import pytest

import server as sc
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def _start_server_thread():
    # start Flask app in a background thread (use a different port to avoid conflicts)
    def run():
        sc.app.run(host='127.0.0.1', port=5050, debug=False, use_reloader=False)

    t = threading.Thread(target=run, daemon=True)
    t.start()
    # wait for server to be available
    time.sleep(0.8)
    return t


def test_integration_client_server():
    t = _start_server_thread()
    base = 'http://127.0.0.1:5050'

    # simulate mobile client ephemeral keypair
    client_priv = X25519PrivateKey.generate()
    client_pub = client_priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )
    client_pub_b64 = base64.b64encode(client_pub).decode('ascii')

    # derive shared secret with server's public key
    server_pub = sc.SERVER_X25519_PUBLIC_BYTES
    shared = client_priv.exchange(sc.x25519.X25519PublicKey.from_public_bytes(server_pub))
    hkdf = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b'safecopy v1')
    key = hkdf.derive(shared)

    # prepare AES-GCM payload
    aes = AESGCM(key)
    nonce = b"\x00" * 12
    plaintext = b"integration test payload"
    aad = b"job-int|2025-10-18T12:00:00Z"
    ct = aes.encrypt(nonce, plaintext, aad)
    combined = nonce + ct
    payload_b64 = base64.b64encode(combined).decode('ascii')

    # POST to /print-job
    r = requests.post(f'{base}/print-job', json={
        'job_id': 'job-int', 'timestamp': '2025-10-18T12:00:00Z', 'filename': 'int.pdf',
        'payload': payload_b64, 'client_pub': client_pub_b64
    })
    assert r.status_code == 200, r.text

    # check cache
    r2 = requests.get(f'{base}/cache/job-int')
    assert r2.status_code == 200
    js = r2.json()
    assert js['filename'] == 'int.pdf'
    assert js['size'] == len(plaintext)
