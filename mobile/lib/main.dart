import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const SafeCopyApp());
}

class SafeCopyApp extends StatelessWidget {
  const SafeCopyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeCopy Mobile',
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: const HomePage(),
    );
  }
}

// Backwards-compatibility wrapper for tests and older examples that expect
// a `MyApp` top-level widget.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => const SafeCopyApp();
}

class JobItem {
  final String jobId;
  final String filename;
  final DateTime timestamp;
  String status;

  JobItem(
      {required this.jobId,
      required this.filename,
      required this.timestamp,
      this.status = 'queued'});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<JobItem> _jobs = [];
  String _status = '';
  // Default to localhost for developer workflows so the web build can reach
  // the local Flask dev server running on the host machine.
  String _serverUrl = 'http://127.0.0.1:5000/print-job';
  Uint8List? _preSharedKey; // 32 bytes

  final _uuid = const Uuid();

  // Ephemeral client keypair (generated once per app run and reused for uploads)
  SimpleKeyPair? _clientKeyPair;
  SimplePublicKey? _clientPublicKey;
  Uint8List? _clientPubBytes;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadConfig();
    await _initEphemeralKey();
  }

  Future<void> _initEphemeralKey() async {
    if (_clientKeyPair != null) return;
    try {
      final algorithm = X25519();
      _clientKeyPair = await algorithm.newKeyPair();
      final localPub = await _clientKeyPair!.extractPublicKey();
      _clientPublicKey = localPub;
      _clientPubBytes = Uint8List.fromList(localPub.bytes);
    } catch (e) {
      // If key generation fails, ensure variables are null and surface an error later.
      _clientKeyPair = null;
      _clientPublicKey = null;
      _clientPubBytes = null;
    }
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serverUrl = prefs.getString('serverUrl') ?? _serverUrl;
      final keyBase64 = prefs.getString('psk');
      if (keyBase64 != null) {
        try {
          _preSharedKey = base64Decode(keyBase64);
        } catch (_) {
          _preSharedKey = null;
        }
      }
    });
  }

  Future<void> _saveConfig(String serverUrl, Uint8List? key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('serverUrl', serverUrl);
    if (key != null) {
      await prefs.setString('psk', base64Encode(key));
    }
    setState(() {
      _serverUrl = serverUrl;
      _preSharedKey = key;
    });
  }

  Future<void> _openSettings() async {
    final result = await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) =>
                SettingsPage(serverUrl: _serverUrl, psk: _preSharedKey)));
    if (result != null && result is Map<String, dynamic>) {
      await _saveConfig(result['serverUrl'], result['psk']);
    }
  }

  Future<void> _pickAndSendPdf() async {
    setState(() => _status = 'Picking file...');
    final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        withData: true // ensure bytes are returned where possible
        );
    if (result == null || result.files.isEmpty) {
      setState(() => _status = 'No file selected');
      return;
    }

    Uint8List? fileBytes = result.files.first.bytes;
    final filePath = result.files.first.path;
    // If bytes aren't provided (some platform configurations), try to read
    // from the returned path. Note: on Android this path may be a content:// URI
    // which cannot be read via File(path). In that case prefer pickFiles(withData: true)
    // which we requested above. If it still fails, show an error to the user.
    if (fileBytes == null && filePath != null) {
      try {
        // If filePath is a normal file system path this will work.
        if (!filePath.startsWith('content://')) {
          final f = File(filePath);
          fileBytes = await f.readAsBytes();
        } else {
          // content:// URIs must be opened via ContentResolver on Android.
          throw Exception(
              'Selected file is a content URI (Android). Use withData:true or open via content resolver.');
        }
      } catch (e) {
        setState(() => _status = 'Failed to read file bytes: $e');
        return;
      }
    }
    final fileName = result.files.first.name;

    final jobId = _uuid.v4();
    final timestamp = DateTime.now().toUtc();
    final job = JobItem(
        jobId: jobId,
        filename: fileName,
        timestamp: timestamp,
        status: 'encrypting');
    setState(() {
      _jobs.insert(0, job);
      _status = 'Encrypting...';
    });

    try {
      final out =
          await _encryptPdf(fileBytes!, jobId, timestamp.toIso8601String());
      final payloadBase64 = out['payload']!;
      final clientPub = out['client_pub'];

      setState(() {
        job.status = 'sending';
        _status = 'Sending...';
      });

      final body = {
        'job_id': jobId,
        'timestamp': timestamp.toIso8601String(),
        'filename': fileName,
        'payload': payloadBase64
      };
      if (clientPub != null) {
        body['client_pub'] = clientPub;
      }

      // Debug print: show client_pub being uploaded (should be non-empty)
      print("Uploading PDF with client_pub: ${body['client_pub']}");

      final postUrl = _serverUrl.endsWith('/print-job')
          ? _serverUrl
          : '$_serverUrl/print-job';
      final resp = await http.post(Uri.parse(postUrl),
          body: jsonEncode(body),
          headers: {
            'Content-Type': 'application/json'
          }).timeout(const Duration(seconds: 12));

      if (resp.statusCode == 200) {
        setState(() {
          job.status = 'sent';
          _status = 'Sent';
        });
      } else if (resp.statusCode == 409) {
        setState(() {
          job.status = 'duplicate';
          _status = 'Duplicate JobID rejected by server';
        });
      } else {
        setState(() {
          job.status = 'error';
          _status = 'Server error: ${resp.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        job.status = 'error';
        _status = 'Network/error: $e';
      });
    }
  }

  Future<Map<String, String>> _encryptPdf(
      Uint8List plaintext, String jobId, String timestamp) async {
    // If a pre-shared key is set, use it. Otherwise attempt ephemeral ECDH with server.
    Uint8List keyBytes;
    String? clientPubB64;
    if (_preSharedKey != null && _preSharedKey!.length == 32) {
      keyBytes = _preSharedKey!;
    } else {
      // attempt to fetch server public key
      try {
        final base = Uri.parse(_serverUrl);
        // Build a stable /server-pub URL from the origin so whether the user set
        // the server URL to the base or to /print-job it still resolves correctly.
        final origin =
            '${base.scheme}://${base.hasAuthority ? base.authority : base.host}';
        final serverPubUri = Uri.parse('$origin/server-pub');
        // Debug: print the URL we're trying to fetch (helps diagnose timeouts)
        print('Fetching server public key from $serverPubUri');
        final r =
            await http.get(serverPubUri).timeout(const Duration(seconds: 15));
        if (r.statusCode == 200) {
          final js = jsonDecode(r.body);
          final serverPubB64 = js['server_pub'] as String;
          final serverPub = base64Decode(serverPubB64);
          // ensure we have an ephemeral keypair initialized and reuse it
          final algorithm = X25519();
          await _initEphemeralKey();
          if (_clientKeyPair == null || _clientPubBytes == null) {
            throw Exception('Ephemeral client keypair not available');
          }
          clientPubB64 = base64Encode(_clientPubBytes!);

          // perform shared secret using the stored client keypair
          final sharedSecret = await algorithm.sharedSecretKey(
              keyPair: _clientKeyPair!,
              remotePublicKey:
                  SimplePublicKey(serverPub, type: KeyPairType.x25519));
          // derive key with HKDF-SHA256 (outputLength=32)
          final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
          final derived = await hkdf.deriveKey(
              secretKey: sharedSecret, info: utf8.encode('safecopy v1'));
          final derivedBytes = await derived.extractBytes();
          keyBytes = Uint8List.fromList(derivedBytes);
        } else {
          throw Exception('server-pub fetch ${r.statusCode}');
        }
      } catch (e) {
        throw Exception('No PSK and key-exchange failed: $e');
      }
    }

    final algorithm = AesGcm.with256bits();
    final secretKey = SecretKey(keyBytes);
    final aad = utf8.encode('$jobId|$timestamp');
    final nonce = algorithm.newNonce();
    final secretBox = await algorithm.encrypt(plaintext,
        secretKey: secretKey, nonce: nonce, aad: aad);

    final combined = <int>[];
    combined.addAll(nonce);
    combined.addAll(secretBox.cipherText);
    combined.addAll(secretBox.mac.bytes);

    final payload = base64Encode(combined);
    final out = <String, String>{'payload': payload};
    if (clientPubB64 != null) out['client_pub'] = clientPubB64;
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SafeCopy Mobile'), actions: [
        IconButton(icon: const Icon(Icons.settings), onPressed: _openSettings)
      ]),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            ElevatedButton.icon(
                onPressed: _pickAndSendPdf,
                icon: const Icon(Icons.upload_file),
                label: const Text('Pick PDF & Send')),
            const SizedBox(height: 8),
            Text('Status: $_status', style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            Expanded(
              child: _jobs.isEmpty
                  ? const Center(child: Text('No jobs yet'))
                  : ListView.builder(
                      itemCount: _jobs.length,
                      itemBuilder: (context, i) {
                        final j = _jobs[i];
                        return ListTile(
                          title: Text(j.filename),
                          subtitle:
                              Text('${j.jobId} • ${j.timestamp.toLocal()}'),
                          trailing: Text(j.status),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  final String serverUrl;
  final Uint8List? psk;
  const SettingsPage({super.key, required this.serverUrl, required this.psk});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _serverCtrl;
  late TextEditingController _pskCtrl;

  @override
  void initState() {
    super.initState();
    _serverCtrl = TextEditingController(text: widget.serverUrl);
    _pskCtrl = TextEditingController(
        text: widget.psk != null ? base64Encode(widget.psk!) : '');
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _pskCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final url = _serverCtrl.text.trim();
    final keyText = _pskCtrl.text.trim();
    Uint8List? key;
    if (keyText.isNotEmpty) {
      try {
        final decoded = base64Decode(keyText);
        if (decoded.length != 32) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('PSK must decode to 32 bytes')));
          return;
        }
        key = decoded;
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PSK must be valid base64')));
        return;
      }
    }

    Navigator.of(context).pop({'serverUrl': url, 'psk': key});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(children: [
          TextField(
              controller: _serverCtrl,
              decoration: const InputDecoration(
                  labelText: 'Server URL (POST /print-job)')),
          const SizedBox(height: 12),
          TextField(
              controller: _pskCtrl,
              decoration: const InputDecoration(
                  labelText: 'Pre-shared key (base64, 32 bytes)'),
              maxLines: 1),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: _save, child: const Text('Save')),
        ]),
      ),
    );
  }
}
