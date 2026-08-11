import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_school/models/timetable.dart';
import 'package:smart_school/widgets/timetable_grid.dart';

TimetableEntry entry({
  required int day,
  required int slot,
  String subject = 'Science',
  String code = 'SCI',
  String className = '9A',
  String teacher = 'Isha Singh',
  String teacherId = 't1',
}) =>
    TimetableEntry(
      id: '$day-$slot',
      dayOfWeek: day,
      slotIndex: slot,
      className: className,
      classId: 'c-$className',
      subjectName: subject,
      subjectCode: code,
      teacherName: teacher,
      teacherId: teacherId,
      roomName: 'Room $className',
      startTime: '08:00:00',
      endTime: '08:45:00',
    );

/// A teacher's own week: scattered periods across six days, exactly the shape
/// /timetable/me returns.
Timetable teacherWeek() => Timetable(
      version: null,
      entries: [
        entry(day: 1, slot: 1),
        entry(day: 1, slot: 4, className: '1B'),
        entry(day: 2, slot: 2, subject: 'Maths', code: 'MATH'),
        entry(day: 3, slot: 5, className: '8C'),
        entry(day: 5, slot: 7, className: '10D'),
        entry(day: 6, slot: 8, className: '7A'),
      ],
    );

Future<void> pump(WidgetTester tester, Widget child, {double width = 1100}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  group('TimetableGrid renders a teacher week', () {
    testWidgets('shows the lessons, wide', (tester) async {
      await pump(tester, TimetableGrid(timetable: teacherWeek()));

      expect(find.text('Science'), findsWidgets);
      expect(find.text('Maths'), findsOneWidget);
      expect(find.text('Nothing scheduled'), findsNothing);
    });

    testWidgets('shows the lessons, narrow (day-list fallback)',
        (tester) async {
      await pump(tester, TimetableGrid(timetable: teacherWeek()), width: 520);

      expect(find.text('Science'), findsWidgets);
      expect(find.text('Nothing scheduled'), findsNothing);
    });

    testWidgets('renders every day that has a lesson', (tester) async {
      await pump(tester, TimetableGrid(timetable: teacherWeek()));
      // Six distinct days appear in the data, so six columns.
      for (final d in ['Mon', 'Tue', 'Wed', 'Fri', 'Sat']) {
        expect(find.text(d), findsWidgets, reason: '$d column missing');
      }
    });

    testWidgets('an empty timetable says so rather than rendering blank',
        (tester) async {
      await pump(tester, TimetableGrid(timetable: Timetable(version: null, entries: [])));
      expect(find.text('Nothing scheduled'), findsOneWidget);
    });
  });

  group('lookup index', () {
    test('finds an entry with no filter', () {
      final tt = teacherWeek();
      expect(tt.at(1, 1)?.subjectName, 'Science');
      expect(tt.at(2, 2)?.subjectName, 'Maths');
      expect(tt.at(4, 3), isNull, reason: 'nothing scheduled that slot');
    });

    test('finds an entry filtered by class', () {
      final tt = teacherWeek();
      expect(tt.at(1, 4, className: '1B')?.className, '1B');
      expect(tt.at(1, 4, className: '9A'), isNull);
    });

    test('finds an entry filtered by teacher', () {
      final tt = teacherWeek();
      expect(tt.at(1, 1, teacherId: 't1')?.teacherName, 'Isha Singh');
      expect(tt.at(1, 1, teacherId: 'nobody'), isNull);
    });

    test('days and periods come back sorted and de-duplicated', () {
      final tt = teacherWeek();
      expect(tt.days, [1, 2, 3, 5, 6]);
      expect(tt.periods, [1, 2, 4, 5, 7, 8]);
    });
  });
}
