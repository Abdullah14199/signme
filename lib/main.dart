import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_doc_scanner/flutter_doc_scanner.dart';
import 'package:image_picker/image_picker.dart';

import 'signme_service.dart';

void main() {
  runApp(const SignMeApp());
}

class SignMeApp extends StatelessWidget {
  const SignMeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SignMe ID Scan',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
      home: const IdScanPage(),
    );
  }
}

enum _ScanStatus { idle, uploading, processing, done, error }

class IdScanPage extends StatefulWidget {
  const IdScanPage({super.key});

  @override
  State<IdScanPage> createState() => _IdScanPageState();
}

class _IdScanPageState extends State<IdScanPage> {
  // Lets `flutter run --dart-define=SIGNME_API_KEY=...` prefill the field for
  // local testing without ever hardcoding the key into source.
  final _apiKeyController = TextEditingController(
    text: const String.fromEnvironment('SIGNME_API_KEY'),
  );
  final _picker = ImagePicker();
  final _docScanner = FlutterDocScanner();

  File? _imageFile;
  _ScanStatus _status = _ScanStatus.idle;
  String? _errorMessage;
  SignMeResult? _result;

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _picker.pickImage(source: source, imageQuality: 90);
    if (picked == null) return;
    setState(() {
      _imageFile = File(picked.path);
      _result = null;
      _errorMessage = null;
      _status = _ScanStatus.idle;
    });
    await _scan(); // no extra tap needed - send it to SignMe right away
  }

  /// Launches the live document-scanning UI (edge detection, auto-crop) via
  /// Google ML Kit's document scanner, instead of the plain camera app, then
  /// immediately uploads the captured image - no separate "Scan ID" tap needed.
  Future<void> _scanWithCamera() async {
    try {
      final scanResult = await _docScanner.getScannedDocumentAsImages(
        page: 1,
        useAutomaticSinglePictureProcessing: true,
      );
      final imageUri = scanResult?.images.firstOrNull;
      if (imageUri == null) return; // user cancelled

      final file = _fileFromScannerUri(imageUri);
      if (file == null) {
        setState(() => _errorMessage = "Couldn't read the scanned image ($imageUri). Try Gallery instead.");
        return;
      }
      setState(() {
        _imageFile = file;
        _result = null;
        _errorMessage = null;
        _status = _ScanStatus.idle;
      });
      await _scan();
    } on DocScanException catch (e) {
      setState(() => _errorMessage = 'Scan failed: ${e.message}');
    }
  }

  File? _fileFromScannerUri(String uriString) {
    final uri = Uri.parse(uriString);
    if (uri.scheme == 'file' || uri.scheme.isEmpty) {
      return File(uri.toFilePath());
    }
    return null; // e.g. a content:// URI we can't read directly via dart:io
  }

  Future<void> _scan() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      setState(() => _errorMessage = 'Enter your SignMe API key first.');
      return;
    }
    if (_imageFile == null) {
      setState(() => _errorMessage = 'Pick or capture an ID image first.');
      return;
    }

    setState(() {
      _status = _ScanStatus.uploading;
      _errorMessage = null;
      _result = null;
    });

    final service = SignMeService(apiKey: apiKey);
    try {
      setState(() => _status = _ScanStatus.processing);
      final result = await service.scanAuto(_imageFile!);
      setState(() {
        _result = result;
        _status = _ScanStatus.done;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _status = _ScanStatus.error;
      });
    } finally {
      service.dispose();
    }
  }

  bool get _isBusy => _status == _ScanStatus.uploading || _status == _ScanStatus.processing;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SignMe · Egyptian ID Scan')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(
                labelText: 'SignMe API key',
                border: OutlineInputBorder(),
                helperText: 'Get a free key from api.signme.it',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            AspectRatio(
              aspectRatio: 16 / 10,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.outline),
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: _imageFile == null
                    ? const Center(child: Text('No image selected'))
                    : Image.file(_imageFile!, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isBusy ? null : _scanWithCamera,
                    icon: const Icon(Icons.document_scanner_outlined),
                    label: const Text('Scan'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isBusy ? null : () => _pickImage(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Gallery'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isBusy ? null : _scan,
              icon: _isBusy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.document_scanner_outlined),
              label: Text(switch (_status) {
                _ScanStatus.uploading => 'Uploading…',
                _ScanStatus.processing => 'Reading ID…',
                _ => 'Scan ID',
              }),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            if (_result != null) ...[
              const SizedBox(height: 24),
              _ResultCard(result: _result!),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final SignMeResult result;
  const _ResultCard({required this.result});

  static const _typeLabels = {
    SignMeDocumentType.nationalId: 'Egyptian National ID',
    SignMeDocumentType.carLicense: 'Car / driver license',
    SignMeDocumentType.passport: 'Passport',
    SignMeDocumentType.unknown: 'Unrecognized document',
  };

  @override
  Widget build(BuildContext context) {
    // The real card only ever prints name/address/etc. on the front and
    // job/religion/dates on the back - never both. Only show the group that
    // actually matches what was detected, so OCR noise from the wrong side
    // (e.g. garbage landing in "Last name" on a back scan) never displays.
    final fields = <(String, String)>[
      if (result.hasValidFrontId) ...[
        ('First name', result.firstName),
        ('Last name', result.lastName),
        ('National ID', result.nationalId),
        ('Birthday', result.birthday),
        ('Gender', result.gender),
        ('City', result.city),
        ('Address', [result.address1, result.address2].where((s) => s.isNotEmpty).join(', ')),
      ],
      if (result.looksLikeIdBack) ...[
        ('Job', result.job),
        ('Religion', result.religion),
        ('Marital status', result.maritalStatus),
        ('Issue date', result.issueDateDisplay),
        ('Expiry date', result.expiryDisplay),
      ],
    ].where((f) => f.$2.isNotEmpty).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Extracted data', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _ValidationBanner(result: result),
            if (result.isNationalId) ...[
              const SizedBox(height: 8),
              _ExpiryBanner(result: result),
            ],
            const Divider(),
            if (fields.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No fields were recognized in this image.'),
              ),
            for (final (label, value) in fields)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 110, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Expanded(child: Text(value)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ValidationBanner extends StatelessWidget {
  final SignMeResult result;
  const _ValidationBanner({required this.result});

  @override
  Widget build(BuildContext context) {
    final type = result.documentType;
    final label = _ResultCard._typeLabels[type]!;
    final scheme = Theme.of(context).colorScheme;

    late final IconData icon;
    late final Color color;
    late final String message;

    if (type == SignMeDocumentType.unknown) {
      icon = Icons.help_outline;
      color = scheme.tertiary;
      message = "Couldn't confirm the document type from the extracted data.";
    } else if (type != SignMeDocumentType.nationalId) {
      icon = Icons.warning_amber_rounded;
      color = scheme.error;
      message = "This doesn't look like a National ID. Detected: $label.";
    } else {
      icon = Icons.check_circle_outline;
      color = Colors.green.shade700;
      message = 'Looks like a valid $label.';
    }

    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
      ],
    );
  }
}

class _ExpiryBanner extends StatelessWidget {
  final SignMeResult result;
  const _ExpiryBanner({required this.result});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final noExpiry = result.expiryDate == null;
    final expired = result.isExpired;

    final IconData icon;
    final Color color;
    final String message;
    if (noExpiry) {
      icon = Icons.help_outline;
      color = scheme.tertiary;
      message = 'Expiry date not found. Scan the back of the card to check it.';
    } else if (expired) {
      icon = Icons.event_busy;
      color = scheme.error;
      message = 'This ID expired on ${result.expiryDisplay}.';
    } else {
      icon = Icons.event_available;
      color = Colors.green.shade700;
      message = 'Valid until ${result.expiryDisplay}.';
    }

    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
