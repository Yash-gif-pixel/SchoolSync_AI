import 'package:flutter_test/flutter_test.dart';
import 'package:smart_school/core/dates.dart';

void main() {
  group('isoToDisplay', () {
    test('renders ISO as day/month/year', () {
      expect(Dates.isoToDisplay('2014-03-10'), '10/03/2014');
      expect(Dates.isoToDisplay('2007-04-09'), '09/04/2007');
    });

    test('pads single digits', () {
      expect(Dates.isoToDisplay('2020-07-05'), '05/07/2020');
    });

    test('empty and null become empty', () {
      expect(Dates.isoToDisplay(null), '');
      expect(Dates.isoToDisplay(''), '');
    });

    test('passes through anything that is not ISO', () {
      expect(Dates.isoToDisplay('not a date'), 'not a date');
    });
  });

  group('displayToIso', () {
    test('reads day/month/year', () {
      expect(Dates.displayToIso('10/03/2014'), '2014-03-10');
      expect(Dates.displayToIso('9/4/2007'), '2007-04-09');
    });

    test('accepts dash, dot and pipe separators', () {
      expect(Dates.displayToIso('10-03-2014'), '2014-03-10');
      expect(Dates.displayToIso('10.03.2014'), '2014-03-10');
      expect(Dates.displayToIso('10|03|2014'), '2014-03-10');
    });

    test('tolerates surrounding and inner spaces', () {
      expect(Dates.displayToIso('  10 / 03 / 2014 '), '2014-03-10');
    });

    test('accepts ISO already, so a pasted value still works', () {
      expect(Dates.displayToIso('2014-03-10'), '2014-03-10');
    });

    test('round-trips with isoToDisplay', () {
      for (final iso in ['2014-03-10', '2007-04-09', '2020-12-31', '1999-01-01']) {
        expect(Dates.displayToIso(Dates.isoToDisplay(iso)), iso);
      }
    });

    test('day and month are never swapped', () {
      // The whole point: 10/03 is 10 March, not 3 October.
      expect(Dates.displayToIso('10/03/2014'), '2014-03-10');
      expect(Dates.displayToIso('03/10/2014'), '2014-10-03');
    });

    group('two-digit years', () {
      test('recent years read as 20xx', () {
        expect(Dates.displayToIso('10/04/26'), '2026-04-10');
      });

      test('distant years read as 19xx', () {
        expect(Dates.displayToIso('10/03/79'), '1979-03-10');
      });
    });

    group('rejects rather than guessing', () {
      test('impossible calendar dates', () {
        expect(Dates.displayToIso('31/02/2014'), isNull);
        expect(Dates.displayToIso('30/02/2014'), isNull);
        expect(Dates.displayToIso('32/01/2014'), isNull);
      });

      test('month out of range', () {
        expect(Dates.displayToIso('10/13/2014'), isNull);
        expect(Dates.displayToIso('10/00/2014'), isNull);
      });

      test('day zero', () {
        expect(Dates.displayToIso('00/03/2014'), isNull);
      });

      test('nonsense input', () {
        expect(Dates.displayToIso('hello'), isNull);
        expect(Dates.displayToIso('10/03'), isNull);
        expect(Dates.displayToIso('10/03/2014/extra'), isNull);
      });

      test('empty is null, not an error', () {
        expect(Dates.displayToIso(null), isNull);
        expect(Dates.displayToIso('   '), isNull);
      });
    });

    test('leap days behave', () {
      expect(Dates.displayToIso('29/02/2024'), '2024-02-29'); // leap year
      expect(Dates.displayToIso('29/02/2023'), isNull);       // not a leap year
    });
  });

  group('isDateField', () {
    test('identifies the two date fields', () {
      expect(Dates.isDateField('date_of_birth'), isTrue);
      expect(Dates.isDateField('admission_date'), isTrue);
    });

    test('and nothing else', () {
      for (final f in ['full_name', 'gender', 'guardian_phone', 'address']) {
        expect(Dates.isDateField(f), isFalse);
      }
    });
  });
}
