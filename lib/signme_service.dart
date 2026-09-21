import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Which side/type of document is being scanned.
/// Maps to the `ID_type` query parameter on the SignMe uploadImage endpoint.
enum SignMeIdType {
  idFront(0),
  idBack(1),
  passport(2);

  final int value;
  const SignMeIdType(this.value);
}

class SignMeException implements Exception {
  final String message;
  SignMeException(this.message);

  @override
  String toString() => message;
}

/// What kind of document the extracted fields actually look like.
///
/// SignMe doesn't return an explicit "document type" - `ID_type=0` covers
/// national ID fronts, driver licenses, *and* car licenses in one bucket,
/// and just fills in whichever fields it recognized. This classifies the
/// result after the fact from which fields came back non-empty.
enum SignMeDocumentType { nationalId, carLicense, passport, unknown }

/// Extracted document fields returned by the SignMe ReadImage endpoint.
class SignMeResult {
  final String firstName;
  final String lastName;
  final String nationalId;
  final String birthday;
  final String gender;
  final String city;
  final String address1;
  final String address2;
  final String issueDate;
  final String expiry;
  final String plateNumber;
  final String passportType;
  final String job;
  final String religion;
  final String maritalStatus;
  final Map<String, dynamic> raw;

  SignMeResult({
    required this.firstName,
    required this.lastName,
    required this.nationalId,
    required this.birthday,
    required this.gender,
    required this.city,
    required this.address1,
    required this.address2,
    required this.issueDate,
    required this.expiry,
    required this.plateNumber,
    required this.passportType,
    required this.job,
    required this.religion,
    required this.maritalStatus,
    required this.raw,
  });

  factory SignMeResult.fromJson(Map<String, dynamic> json) {
    String field(String key) => (json[key] ?? '').toString().trim();
    return SignMeResult(
      firstName: field('firstname'),
      lastName: field('lastname'),
      nationalId: field('national_ID'),
      birthday: field('birthday'),
      gender: field('gender'),
      city: field('city'),
      address1: field('address1'),
      address2: field('address2'),
      issueDate: field('issueDate'),
      expiry: field('expiry'),
      plateNumber: field('platenumber'),
      passportType: field('passportType'),
      job: field('job'),
      religion: field('religion'),
      maritalStatus: field('status'),
      raw: json,
    );
  }

  static final _egyptianNationalIdPattern = RegExp(r'^\d{14}$');

  // SignMe's OCR will stuff *something* into free-text fields like `job` for
  // any card-shaped image (a club card, a business card, ...), so a plain
  // "field is non-empty" check is too weak - it false-positives on those.
  // Religion and marital status on an Egyptian ID only ever take a handful
  // of known printed values, so require a match against those instead.
  static const _knownReligions = {'مسلم', 'مسلمة', 'مسيحى', 'مسيحي', 'مسيحية'};
  static const _knownMaritalStatuses = {'أعزب', 'اعزب', 'عزباء', 'متزوج', 'متزوجة', 'مطلق', 'مطلقة', 'أرمل', 'ارمل', 'أرملة'};

  /// True when the 14-digit national ID number was read - only the *front*
  /// of the card prints this, so personal-info fields (name, address, city,
  /// gender, birthday) are only trustworthy when this is true. On a back
  /// scan those fields are empty on the real card, so anything SignMe put
  /// there is OCR noise and shouldn't be shown as if it were real data.
  bool get hasValidFrontId => _egyptianNationalIdPattern.hasMatch(nationalId);

  /// True when religion/marital status/issue+expiry look like genuine back-
  /// of-ID data (checked against known printed values, not just "non-empty").
  bool get looksLikeIdBack =>
      _knownReligions.contains(religion) ||
      _knownMaritalStatuses.contains(maritalStatus) ||
      (_parseFlexibleDate(issueDate) != null && _parseFlexibleDate(expiry) != null);

  /// Best-effort guess at what was actually scanned, based on which fields
  /// SignMe managed to extract.
  SignMeDocumentType get documentType {
    if (passportType.isNotEmpty) return SignMeDocumentType.passport;
    if (plateNumber.isNotEmpty) return SignMeDocumentType.carLicense;
    if (hasValidFrontId || looksLikeIdBack) return SignMeDocumentType.nationalId;
    return SignMeDocumentType.unknown;
  }

  /// Whether this looks like a genuine Egyptian National ID (front or back).
  bool get isNationalId => documentType == SignMeDocumentType.nationalId;

  /// Parses a date from SignMe, which isn't consistent about the format:
  /// usually `dd/MM/yyyy` (as documented), but sometimes `yyyy-MM-d` with
  /// dashes and a dropped leading zero. Whichever segment is 4 digits is
  /// taken as the year; day-vs-month order is inferred from whether the
  /// year leads (ISO-like, `yyyy-MM-dd`) or trails (`dd/MM/yyyy`).
  static DateTime? _parseFlexibleDate(String value) {
    final parts = value.split(RegExp(r'[/\-]'));
    if (parts.length != 3) return null;
    final nums = parts.map(int.tryParse).toList();
    if (nums.any((n) => n == null)) return null;
    final n = nums.cast<int>();

    int year, month, day;
    if (n[0] >= 1000) {
      year = n[0];
      month = n[1];
      day = n[2];
    } else if (n[2] >= 1000) {
      day = n[0];
      month = n[1];
      year = n[2];
    } else {
      return null; // no 4-digit year anywhere - not a date we recognize
    }

    final date = DateTime(year, month, day);
    // Guard against DateTime's own overflow normalization (e.g. day 32).
    if (date.year != year || date.month != month || date.day != day) return null;
    return date;
  }

  static String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  /// The card's expiry date, parsed from whatever format SignMe returned it
  /// in. Null if there's no expiry field or it couldn't be parsed.
  DateTime? get expiryDate => _parseFlexibleDate(expiry);

  /// The card's issue date, parsed the same way as [expiryDate].
  DateTime? get issueDateParsed => _parseFlexibleDate(issueDate);

  /// Expiry date normalized to `dd/MM/yyyy` for display, regardless of which
  /// format SignMe actually sent it in. Falls back to the raw string if it
  /// didn't parse, so nothing is silently hidden.
  String get expiryDisplay {
    final date = expiryDate;
    return date == null ? expiry : _formatDate(date);
  }

  /// Issue date normalized the same way as [expiryDisplay].
  String get issueDateDisplay {
    final date = issueDateParsed;
    return date == null ? issueDate : _formatDate(date);
  }

  /// Whether the card's printed expiry date is in the past.
  bool get isExpired {
    final date = expiryDate;
    if (date == null) return false;
    final today = DateTime.now();
    return date.isBefore(DateTime(today.year, today.month, today.day));
  }

  /// Combines a front-mode read and a back-mode read of the *same photo*
  /// into one trustworthy result.
  ///
  /// SignMe needs to be told which side it's looking at (`ID_type`) to know
  /// which fields to extract. Fed a back-of-card photo under front mode, it
  /// still finds the ID number/gender/birthday (their fixed layout reads
  /// fine either way) but has no job/religion/status slots to put the rest
  /// in, so it force-fits back-side text into the name/address fields
  /// instead - producing plausible-looking garbage rather than an error.
  /// Front mode alone can't tell the difference, so this only trusts
  /// name/address/city once the back-mode read has *confirmed* this isn't
  /// actually the back of the card.
  factory SignMeResult.mergeFrontAndBack(SignMeResult frontRead, SignMeResult backRead) {
    if (backRead.looksLikeIdBack) {
      return SignMeResult(
        firstName: '',
        lastName: '',
        nationalId: frontRead.hasValidFrontId ? frontRead.nationalId : backRead.nationalId,
        birthday: frontRead.birthday.isNotEmpty ? frontRead.birthday : backRead.birthday,
        gender: frontRead.gender.isNotEmpty ? frontRead.gender : backRead.gender,
        city: '',
        address1: '',
        address2: '',
        issueDate: backRead.issueDate,
        expiry: backRead.expiry,
        plateNumber: '',
        passportType: '',
        job: backRead.job,
        religion: backRead.religion,
        maritalStatus: backRead.maritalStatus,
        raw: {'front': frontRead.raw, 'back': backRead.raw},
      );
    }
    // Not confirmed as a back read - trust the front-mode read as-is (this
    // also covers driver/car licenses and passports, which only ever get
    // scanned in front mode).
    return SignMeResult(
      firstName: frontRead.firstName,
      lastName: frontRead.lastName,
      nationalId: frontRead.nationalId,
      birthday: frontRead.birthday,
      gender: frontRead.gender,
      city: frontRead.city,
      address1: frontRead.address1,
      address2: frontRead.address2,
      issueDate: frontRead.issueDate,
      expiry: frontRead.expiry,
      plateNumber: frontRead.plateNumber,
      passportType: frontRead.passportType,
      job: frontRead.job,
      religion: frontRead.religion,
      maritalStatus: frontRead.maritalStatus,
      raw: {'front': frontRead.raw, 'back': backRead.raw},
    );
  }
}

/// Thin client for the SignMe Egyptian ID OCR API (https://api.signme.it/).
///
/// Flow: uploadImage(file) -> returns a job id -> readImage(id) is polled
/// until the OCR result is ready.
class SignMeService {
  static const _baseUrl = 'https://webapi.signme.it/api/v2/SignMeAPI';

  final String apiKey;
  final http.Client _client;

  SignMeService({required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  Future<String> uploadImage(File imageFile, {SignMeIdType idType = SignMeIdType.idFront}) async {
    final uri = Uri.parse('$_baseUrl/uploadImage?ID_type=${idType.value}');
    final response = await _sendWithRetry(() async {
      final request = http.MultipartRequest('POST', uri)
        ..headers['APIKEY'] = apiKey
        ..files.add(await http.MultipartFile.fromPath('file', imageFile.path));
      return http.Response.fromStream(await _client.send(request));
    });
    final body = _decode(response);

    if (response.statusCode != 200 || body['id'] == null) {
      throw SignMeException(body['message']?.toString() ?? 'Upload failed (${response.statusCode}).');
    }
    return body['id'].toString();
  }

  Future<SignMeResult?> readImage(String id) async {
    final uri = Uri.parse('$_baseUrl/ReadImage?id=$id&isBlocked=false');
    final response = await _sendWithRetry(() => _client.get(uri, headers: {'APIKEY': apiKey}));
    final body = _decode(response);

    if (response.statusCode != 200) {
      throw SignMeException(body['message']?.toString() ?? 'Read failed (${response.statusCode}).');
    }

    final data = body['data'];
    if (data is! Map<String, dynamic> || data.isEmpty) {
      return null; // still processing
    }
    return SignMeResult.fromJson(data);
  }

  /// SignMe's backend is fronted by a load balancer where some instances
  /// intermittently return a bare IIS 403 ("Access is denied") page instead
  /// of routing to the API - unrelated to the request itself. Retrying a
  /// couple of times clears it up.
  Future<http.Response> _sendWithRetry(
    Future<http.Response> Function() send, {
    int maxAttempts = 6,
  }) async {
    http.Response? last;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final response = await send();
      final isJson = response.headers['content-type']?.contains('application/json') ?? false;
      if (isJson || response.statusCode == 200) return response;
      last = response;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return last!;
  }

  /// Uploads the image, then polls ReadImage until a result is available.
  Future<SignMeResult> scan(
    File imageFile, {
    SignMeIdType idType = SignMeIdType.idFront,
    int maxAttempts = 12,
    Duration initialDelay = const Duration(seconds: 2),
    Duration pollInterval = const Duration(milliseconds: 1500),
  }) async {
    final id = await uploadImage(imageFile, idType: idType);

    await Future.delayed(initialDelay);
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final result = await readImage(id);
      if (result != null) return result;
      await Future.delayed(pollInterval);
    }
    throw SignMeException('Timed out waiting for OCR result.');
  }

  /// Scans one photo without asking the user which side it is: uploads it
  /// under both front and back modes in parallel and merges the two reads
  /// via [SignMeResult.mergeFrontAndBack], so name/address never show up
  /// contaminated by a back-of-card photo. Costs two API calls instead of
  /// one - SignMe has no single "auto" mode that reads both.
  Future<SignMeResult> scanAuto(
    File imageFile, {
    int maxAttempts = 12,
    Duration initialDelay = const Duration(seconds: 2),
    Duration pollInterval = const Duration(milliseconds: 1500),
  }) async {
    final results = await Future.wait([
      scan(
        imageFile,
        idType: SignMeIdType.idFront,
        maxAttempts: maxAttempts,
        initialDelay: initialDelay,
        pollInterval: pollInterval,
      ),
      scan(
        imageFile,
        idType: SignMeIdType.idBack,
        maxAttempts: maxAttempts,
        initialDelay: initialDelay,
        pollInterval: pollInterval,
      ),
    ]);
    return SignMeResult.mergeFrontAndBack(results[0], results[1]);
  }

  Map<String, dynamic> _decode(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      return {};
    } on FormatException {
      throw SignMeException('Unexpected response from server (${response.statusCode}).');
    }
  }

  void dispose() => _client.close();
}
