import 'package:flutter_test/flutter_test.dart';
import 'package:signme/signme_service.dart';

SignMeResult _result({
  String nationalId = '',
  String firstName = '',
  String lastName = '',
  String birthday = '',
  String gender = '',
  String city = '',
  String address1 = '',
  String address2 = '',
  String religion = '',
  String maritalStatus = '',
  String issueDate = '',
  String expiry = '',
  String job = '',
}) {
  return SignMeResult(
    firstName: firstName,
    lastName: lastName,
    nationalId: nationalId,
    birthday: birthday,
    gender: gender,
    city: city,
    address1: address1,
    address2: address2,
    issueDate: issueDate,
    expiry: expiry,
    plateNumber: '',
    passportType: '',
    job: job,
    religion: religion,
    maritalStatus: maritalStatus,
    raw: const {},
  );
}

void main() {
  group('documentType classification', () {
    test('a valid 14-digit national ID is recognized as a front read', () {
      final result = _result(nationalId: '29612160101819');
      expect(result.hasValidFrontId, isTrue);
      expect(result.documentType, SignMeDocumentType.nationalId);
    });

    test('known religion/marital-status values are recognized as a back read', () {
      final result = _result(religion: 'مسلم', maritalStatus: 'متزوج');
      expect(result.looksLikeIdBack, isTrue);
      expect(result.documentType, SignMeDocumentType.nationalId);
    });

    test('a matching issue/expiry date pair is recognized as a back read', () {
      final result = _result(issueDate: '01/01/2020', expiry: '01/01/2030');
      expect(result.looksLikeIdBack, isTrue);
    });

    test('OCR noise in a free-text field does not count as a back read', () {
      // Regression test for the club-card false positive: garbage OCR text
      // landing in `job` alone must not be treated as ID-back evidence.
      final result = _result(job: 'دبعاسه محي الحين محمع 040028285');
      expect(result.looksLikeIdBack, isFalse);
      expect(result.hasValidFrontId, isFalse);
      expect(result.documentType, SignMeDocumentType.unknown);
    });

    test('an unrelated card with no matching fields is unknown', () {
      final result = _result(firstName: 'Wadi', lastName: 'Degla Clubs');
      expect(result.documentType, SignMeDocumentType.unknown);
    });
  });

  group('mergeFrontAndBack', () {
    test('a back-of-card photo does not leak garbage name/address into the result', () {
      // Reproduces the reported bug: SignMe fed a back-of-card photo under
      // front mode still finds the ID number/birthday/gender (fixed layout)
      // but force-fits the qualification text into name/address instead of
      // erroring, since front mode has no job/religion slots for it.
      final frontRead = _result(
        nationalId: '29806300101597',
        firstName: 'حاصل علي بكالوريوس في',
        lastName: 'علوم الحاسب',
        birthday: '30/06/1998',
        gender: 'ذكر',
        address1: 'زكر مسلم متزوج',
      );
      // The same photo read under back mode correctly finds the real
      // back-of-card fields instead.
      final backRead = _result(
        religion: 'مسلم',
        maritalStatus: 'متزوج',
        issueDate: '10/10/2015',
        expiry: '10/10/2020',
      );

      final merged = SignMeResult.mergeFrontAndBack(frontRead, backRead);

      expect(merged.firstName, isEmpty, reason: 'front-mode name is garbage on a back photo');
      expect(merged.lastName, isEmpty);
      expect(merged.address1, isEmpty);
      expect(merged.nationalId, '29806300101597', reason: 'ID number is still trustworthy');
      expect(merged.birthday, '30/06/1998');
      expect(merged.gender, 'ذكر');
      expect(merged.expiry, '10/10/2020');
      expect(merged.isExpired, isTrue);
    });

    test('a genuine front read is passed through untouched', () {
      final frontRead = _result(
        nationalId: '29612160101819',
        firstName: 'محمود',
        lastName: 'عماد حسنين',
        city: 'القاهرة',
      );
      final backRead = _result(); // nothing back-like found

      final merged = SignMeResult.mergeFrontAndBack(frontRead, backRead);

      expect(merged.firstName, 'محمود');
      expect(merged.lastName, 'عماد حسنين');
      expect(merged.city, 'القاهرة');
      expect(merged.documentType, SignMeDocumentType.nationalId);
    });
  });

  group('expiry parsing', () {
    test('a past date is expired', () {
      final result = _result(expiry: '01/01/2000');
      expect(result.expiryDate, DateTime(2000, 1, 1));
      expect(result.isExpired, isTrue);
    });

    test('a future date is not expired', () {
      final result = _result(expiry: '01/01/2099');
      expect(result.isExpired, isFalse);
    });

    test('an empty expiry has no parsed date and is not "expired"', () {
      final result = _result();
      expect(result.expiryDate, isNull);
      expect(result.isExpired, isFalse);
    });

    test('a malformed date fails to parse instead of throwing', () {
      final result = _result(expiry: 'not-a-date');
      expect(result.expiryDate, isNull);
    });

    test('a dash-separated, year-first date is parsed too', () {
      // Regression test: SignMe doesn't always use the documented
      // dd/MM/yyyy format - this one came back as "2021-12-5" (dashes,
      // year first, no leading zero on the day) and used to silently fail
      // to parse, making the app claim "expiry date not found" while the
      // raw value was still visible elsewhere in the UI.
      final result = _result(expiry: '2021-12-5');
      expect(result.expiryDate, DateTime(2021, 12, 5));
      expect(result.isExpired, isTrue);
      expect(result.expiryDisplay, '05/12/2021');
    });

    test('expiryDisplay normalizes to dd/MM/yyyy regardless of input format', () {
      expect(_result(expiry: '01/01/2030').expiryDisplay, '01/01/2030');
      expect(_result(expiry: '2030-1-1').expiryDisplay, '01/01/2030');
    });

    test('expiryDisplay falls back to the raw string when unparseable', () {
      final result = _result(expiry: 'garbled');
      expect(result.expiryDisplay, 'garbled');
    });
  });
}
