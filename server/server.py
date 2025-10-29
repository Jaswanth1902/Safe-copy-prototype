from flask import Flask, request, jsonify
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import x25519
import base64
import os
import threading
import time
import logging

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("safecopy")
try:
    # Optional dev-only CORS to allow web clients (localhost/phone) to POST
    # Install flask-cors in the venv when running locally: pip install flask-cors
    from flask_cors import CORS
    CORS(app)
    logger.info('flask-cors enabled')
except Exception:
    logger.info('flask-cors not available; continue without CORS')

# Generate server X25519 keypair for ephemeral ECDH key exchange
# In a production deployment, you'd persist a long-term key or rotate appropriately.
SERVER_X25519_PRIVATE = x25519.X25519PrivateKey.generate()
SERVER_X25519_PUBLIC_BYTES = SERVER_X25519_PRIVATE.public_key().public_bytes(
    encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw
)

# In-memory store for job IDs and decrypted content cache
job_ids = set()
cache = {}
cache_lock = threading.Lock()

@app.route('/print-job', methods=['POST'])
def receive_print_job():
    try:
        data = request.get_json()
        if not data:
            return 'Invalid JSON', 400

        job_id = data.get('job_id')
        timestamp = data.get('timestamp')
        filename = data.get('filename')
        payload_b64 = data.get('payload')
        client_pub_b64 = data.get('client_pub')
        if not all([job_id, timestamp, payload_b64]):
            return 'Missing fields', 400

        # Duplicate job detection
        with cache_lock:
            if job_id in job_ids:
                return 'Duplicate JobID', 409
            job_ids.add(job_id)

        # negotiate symmetric key: require client_pub for ECDH -> HKDF -> AES key
        derived_key = None
        if not client_pub_b64:
            with cache_lock:
                job_ids.discard(job_id)
            return 'client_pub is required for this prototype', 400
        try:
            client_pub_bytes = base64.b64decode(client_pub_b64)
            if len(client_pub_bytes) != 32:
                raise ValueError('client_pub must be 32 raw bytes')
            client_pub = x25519.X25519PublicKey.from_public_bytes(client_pub_bytes)
            shared = SERVER_X25519_PRIVATE.exchange(client_pub)
            # derive 32-byte AES key via HKDF-SHA256
            hkdf = HKDF(
                algorithm=hashes.SHA256(), length=32, salt=None, info=b'safecopy v1',
            )
            derived_key = hkdf.derive(shared)
        except Exception as e:
            with cache_lock:
                job_ids.discard(job_id)
            return f'Invalid client_pub: {e}', 400

        # decode payload -> nonce + ciphertext + tag
        try:
            combined = base64.b64decode(payload_b64)
        except Exception as e:
            with cache_lock:
                job_ids.discard(job_id)
            return f'Invalid payload encoding: {e}', 400
        # assuming nonce=12, tag=16
        if len(combined) < 12 + 16:
            with cache_lock:
                job_ids.discard(job_id)
            return 'Invalid payload size', 400
        nonce = combined[:12]
        tag = combined[-16:]
        ciphertext = combined[12:-16]

        # choose AES key: derived_key is required (PSK fallback removed)
        aes_key = derived_key
        aesgcm = AESGCM(aes_key)
        aad = f'{job_id}|{timestamp}'.encode('utf-8')
        try:
            plaintext = aesgcm.decrypt(nonce, ciphertext + tag, aad)
        except Exception as e:
            # cleanup job id on failure
            with cache_lock:
                job_ids.discard(job_id)
            return f'Decryption failed: {e}', 400

        # Store in memory cache (simulating in-ram processing) with timestamp
        with cache_lock:
            cache[job_id] = {
                'filename': filename,
                'timestamp': timestamp,
                'data': plaintext,
                '_ts': time.time(),
            }

        # Simulate printing: here we just acknowledge
        # Zeroing plaintext bytes from local scope (best-effort)
        try:
            if isinstance(plaintext, (bytes, bytearray)):
                ba = bytearray(plaintext)
                for i in range(len(ba)):
                    ba[i] = 0
        except Exception:
            pass

        logger.info('Stored job %s (filename=%s size=%d)', job_id, filename, len(plaintext))
        return jsonify({'status': 'ok'}), 200

    except Exception as e:
        return f'Internal error: {e}', 500

@app.route('/cache/<job_id>', methods=['GET'])
def get_cached(job_id):
    with cache_lock:
        item = cache.get(job_id)
        if not item:
            return 'Not found', 404
        return jsonify({'filename': item['filename'], 'timestamp': item['timestamp'], 'size': len(item['data'])})

@app.route('/cache/<job_id>', methods=['DELETE'])
def delete_cached(job_id):
    with cache_lock:
        item = cache.pop(job_id, None)
        job_ids.discard(job_id)
        return ('', 204)


@app.route('/server-pub', methods=['GET'])
def server_pub():
    """Return the server's X25519 public key (raw bytes, base64-encoded)."""
    return jsonify({'server_pub': base64.b64encode(SERVER_X25519_PUBLIC_BYTES).decode('ascii')}), 200

def _cache_cleanup_thread(ttl_seconds=60, interval=30):
    """Background thread: remove cache entries older than ttl_seconds."""
    while True:
        try:
            now = time.time()
            with cache_lock:
                to_delete = []
                for jid, item in list(cache.items()):
                    ts = item.get('_ts')
                    if ts and now - ts > ttl_seconds:
                        to_delete.append(jid)
                for jid in to_delete:
                    logger.info('Auto-deleting job %s due to TTL', jid)
                    cache.pop(jid, None)
                    job_ids.discard(jid)
        except Exception:
            pass
        time.sleep(interval)


if __name__ == '__main__':
    # Start cleanup thread for prototype
    t = threading.Thread(target=_cache_cleanup_thread, args=(300, 60), daemon=True)
    t.start()
    # Warning: prototype only, do not use in production without TLS and auth
    app.run(host='0.0.0.0', port=5000, debug=True)
