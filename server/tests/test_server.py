import base64
import json
import threading
import time
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import pytest

import server as sc_server
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def encrypt_payload(plaintext_bytes: bytes, job_id: str, timestamp: str):
    """Return (payload_b64, client_pub_b64) for posting to the server.
    Uses an ephemeral client X25519 key to derive the AES key via HKDF.
    """
    # client ephemeral key
    client_priv = X25519PrivateKey.generate()
    client_pub = client_priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )
    client_pub_b64 = base64.b64encode(client_pub).decode('ascii')

    # derive shared secret with server public
    server_pub = sc_server.SERVER_X25519_PUBLIC_BYTES
    shared = client_priv.exchange(sc_server.x25519.X25519PublicKey.from_public_bytes(server_pub))
    hkdf = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b'safecopy v1')
    key = hkdf.derive(shared)

    aesgcm = AESGCM(key)
    nonce = os.urandom(12)
    aad = f'{job_id}|{timestamp}'.encode('utf-8')
    ct = aesgcm.encrypt(nonce, plaintext_bytes, aad)
    combined = nonce + ct
    return base64.b64encode(combined).decode('ascii'), client_pub_b64


def test_decrypt_and_cache():
    client = sc_server.app.test_client()
    job_id = 'job-1'
    timestamp = '2025-10-18T00:00:00Z'
    plaintext = b'%PDF-1.4 testpdf'
    payload, client_pub = encrypt_payload(plaintext, job_id, timestamp)

    resp = client.post('/print-job', json={'job_id': job_id, 'timestamp': timestamp, 'filename': 't.pdf', 'payload': payload, 'client_pub': client_pub})
    assert resp.status_code == 200
    data = client.get(f'/cache/{job_id}')
    assert data.status_code == 200
    js = data.get_json()
    assert js['filename'] == 't.pdf'
    assert js['timestamp'] == timestamp
    assert js['size'] == len(plaintext)


def test_duplicate_job_rejected():
    client = sc_server.app.test_client()
    job_id = 'job-dup'
    timestamp = '2025-10-18T00:01:00Z'
    plaintext = b'doc'
    payload, client_pub = encrypt_payload(plaintext, job_id, timestamp)

    resp1 = client.post('/print-job', json={'job_id': job_id, 'timestamp': timestamp, 'filename': 'a.pdf', 'payload': payload, 'client_pub': client_pub})
    assert resp1.status_code == 200
    resp2 = client.post('/print-job', json={'job_id': job_id, 'timestamp': timestamp, 'filename': 'a.pdf', 'payload': payload, 'client_pub': client_pub})
    assert resp2.status_code == 409


def test_bad_payload_rejected():
    client = sc_server.app.test_client()
    job_id = 'job-bad'
    timestamp = '2025-10-18T00:02:00Z'
    # produce a valid client_pub but send a malformed payload
    _, client_pub = encrypt_payload(b'ok', 'sentinel', '2025-10-18T00:00:00Z')
    payload = 'not-base64!!!'
    resp = client.post('/print-job', json={'job_id': job_id, 'timestamp': timestamp, 'filename': 'b.pdf', 'payload': payload, 'client_pub': client_pub})
    assert resp.status_code in (400,)