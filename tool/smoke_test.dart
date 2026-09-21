// Standalone smoke test for SignMeService against the real API.
// Usage: dart run tool/smoke_test.dart <path-to-image>
// Reads the API key from the SIGNME_API_KEY environment variable.

import 'dart:io';

import 'package:signme/signme_service.dart';

Future<void> main(List<String> args) async {
  final apiKey = Platform.environment['SIGNME_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('Set SIGNME_API_KEY in the environment first.');
    exit(1);
  }
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run tool/smoke_test.dart <path-to-image>');
    exit(1);
  }

  final imageFile = File(args[0]);
  if (!imageFile.existsSync()) {
    stderr.writeln('Image not found: ${args[0]}');
    exit(1);
  }

  final service = SignMeService(apiKey: apiKey);
  try {
    print('Uploading ${imageFile.path}...');
    final id = await service.uploadImage(imageFile);
    print('Upload OK, job id: $id');

    print('Polling ReadImage...');
    await Future.delayed(const Duration(seconds: 2));
    SignMeResult? result;
    for (var attempt = 0; attempt < 12 && result == null; attempt++) {
      result = await service.readImage(id);
      if (result == null) {
        print('  still processing (attempt ${attempt + 1})...');
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    }
    if (result == null) {
      stderr.writeln('Timed out waiting for OCR result.');
      exit(1);
    }
    print('--- Result ---');
    print('firstName:   ${result.firstName}');
    print('lastName:    ${result.lastName}');
    print('nationalId:  ${result.nationalId}');
    print('birthday:    ${result.birthday}');
    print('gender:      ${result.gender}');
    print('city:        ${result.city}');
    print('address1:    ${result.address1}');
    print('raw:         ${result.raw}');
  } on SignMeException catch (e) {
    stderr.writeln('SignMe error: $e');
    exit(1);
  } finally {
    service.dispose();
  }
}
