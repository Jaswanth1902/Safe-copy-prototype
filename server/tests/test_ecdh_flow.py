import base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import pytest

import base64
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
import pytest

import server as sc


def test_ecdh_flow_inprocess():
    # create client ephemeral keypair
    client_priv = X25519PrivateKey.generate()
    client_pub = client_priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
    )
    client_pub_b64 = base64.b64encode(client_pub).decode('ascii')

    # get server public from server module (raw bytes)
    server_pub = sc.SERVER_X25519_PUBLIC_BYTES

    # derive shared secret via x25519
    server_pub_key = X25519PublicKey.from_public_bytes(server_pub)
    shared = client_priv.exchange(server_pub_key)

    # derive 32-byte key via HKDF-SHA256 (must match server parameters)
    hkdf = HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=b'safecopy v1')
    key = hkdf.derive(shared)

    # encrypt a small payload with deterministic nonce
    aes = AESGCM(key)
    nonce = b"\x00" * 12
    plaintext = b"%PDF-1.4 testpdf"
    aad = b"job-ecdh|2025-10-18T00:00:00Z"
    ct = aes.encrypt(nonce, plaintext, aad)  # returns ciphertext + tag
    combined = nonce + ct
    payload_b64 = base64.b64encode(combined).decode('ascii')

    # use Flask test client to post
    client = sc.app.test_client()
    resp = client.post(
        '/print-job',
        json={
            'job_id': 'job-ecdh',
            'timestamp': '2025-10-18T00:00:00Z',
            'filename': 'ecdh.pdf',
            'payload': payload_b64,
            'client_pub': client_pub_b64,
        },
    )
    assert resp.status_code == 200, resp.get_data(as_text=True)

    # validate cache
    res = client.get('/cache/job-ecdh')
    assert res.status_code == 200
    js = res.get_json()
    assert js['filename'] == 'ecdh.pdf'
    assert js['size'] == len(plaintext)
