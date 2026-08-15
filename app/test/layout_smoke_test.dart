/// Renders every dashboard card inside a scroll view and fails if any of them
/// throws during layout.
///
/// This exists because of a real bug: the timetable grid used
/// `CrossAxisAlignment.stretch` in a Row, which demands a bounded height and
/// therefore throws inside any scroll view. In a **release** build a thrown
/// widget renders nothing at all — no red box — so the page simply looked
/// empty and the fault survived three phases unnoticed.
///
/// Unbounded height is the condition that triggers that whole class of bug, so
/// every card is pumped inside a SingleChildScrollView, at both a wide and a
/// narrow viewport.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_school/core/api_client.dart';
import 'package:smart_school/core/documents_repository.dart';
import 'package:smart_school/core/forecast_repository.dart';
import 'package:smart_school/core/operations_repository.dart';
import 'package:smart_school/core/events_repository.dart';
import 'package:smart_school/core/seating_repository.dart';
import 'package:smart_school/core/timetable_repository.dart';
import 'package:smart_school/models/document_template.dart';
import 'package:smart_school/models/extracted_document.dart';
import 'package:smart_school/models/forecast.dart';
import 'package:smart_school/models/operations.dart';
import 'package:smart_school/models/timetable.dart';
import 'package:smart_school/screens/demo_setup_screen.dart';
import 'package:smart_school/screens/document_review_screen.dart';
import 'package:smart_school/screens/template_editor_screen.dart';
import 'package:smart_school/theme/app_theme.dart';
import 'package:smart_school/widgets/review_field_row.dart';
import 'package:smart_school/widgets/action_board_card.dart';
import 'package:smart_school/widgets/document_queue_card.dart';
import 'package:smart_school/widgets/event_row.dart';
import 'package:smart_school/widgets/exam_calendar.dart';
import 'package:smart_school/widgets/forecast_card.dart';
import 'package:smart_school/widgets/hod_approvals_card.dart';
import 'package:smart_school/widgets/leave_card.dart';
import 'package:smart_school/widgets/my_timetable_card.dart';
import 'package:smart_school/widgets/seating_room_grid.dart';
import 'package:smart_school/widgets/timetable_summary_card.dart';
import 'package:smart_school/widgets/today_periods_card.dart';
import 'package:smart_school/widgets/ui/primitives.dart';

// ----------------------------------------------------------------- fixtures
Timetable _week() => Timetable(
      version: null,
      entries: [
        for (var d = 1; d <= 6; d++)
          for (final s in [1, 2, 4])
            TimetableEntry(
              id: '$d-$s',
              dayOfWeek: d,
              slotIndex: s,
              className: '${d + 5}A',
              classId: 'c$d',
              subjectName: 'Science',
              subjectCode: 'SCI',
              teacherName: 'Isha Singh',
              teacherId: 't1',
              roomName: 'Room 1',
              startTime: '08:00:00',
              endTime: '08:45:00',
            ),
      ],
    );

final _periods = [
  TodayPeriod.fromMap({
    'slot_id': 's1', 'slot_index': 1, 'class_id': 'c1', 'class_name': '9A',
    'subject_name': 'Science', 'marked': false, 'start_time': '08:00:00',
    'room': 'Room 9A',
  }),
  TodayPeriod.fromMap({
    'slot_id': 's2', 'slot_index': 2, 'class_id': 'c2', 'class_name': '10B',
    'subject_name': 'Science', 'marked': true, 'start_time': '08:45:00',
  }),
];

final _leave = [
  LeaveRequest.fromMap({
    'id': 'l1', 'from_date': '2026-09-01', 'to_date': '2026-09-02',
    'status': 'approved', 'reason': 'Medical',
    'teacher': {'id': 't1', 'full_name': 'Isha Singh',
                'department_id': 'd1', 'departments': {'name': 'Science'}},
  }),
  LeaveRequest.fromMap({
    'id': 'l2', 'from_date': '2026-09-10', 'to_date': '2026-09-10',
    'status': 'pending_incharge', 'reason': 'Family function',
    'teacher': {'id': 't2', 'full_name': 'Rahul Verma',
                'department_id': 'd1', 'departments': {'name': 'Science'}},
  }),
];

final _board = ActionBoard.fromMap({
  'total_periods': 4,
  'needs_action': 3,
  'groups': [
    {
      'leave_id': 'l1', 'absent_teacher': 'Isha Singh',
      'absent_department': 'Science', 'from_date': '2026-09-01',
      'to_date': '2026-09-01', 'reason': 'Medical', 'unconfirmed': 3,
      'periods': [
        {
          'date': '2026-09-01', 'class_name': '9A', 'subject_name': 'Science',
          'slot_index': 1, 'status': 'suggested', 'room': 'Room 9A',
          'timetable_entry_id': 'e1',
          'candidates': [
            {'substitution_id': 'x1', 'teacher_id': 't9',
             'teacher_name': 'Priya Sharma', 'department': 'Science',
             'rank': 1, 'rationale': 'free this period · same department',
             'status': 'suggested'},
            {'substitution_id': 'x2', 'teacher_id': 't8',
             'teacher_name': 'Rahul Verma', 'department': 'Maths',
             'rank': 2, 'rationale': 'free this period · other department',
             'status': 'suggested'},
          ],
        },
      ],
    },
  ],
});

final _forecast = StaffingForecast.fromMap({
  'critical_count': 1,
  'warning_count': 1,
  'method': 'base rate x weekday x seasonal x headcount',
  'has_timetable': true,
  'rates': {
    'observed_days': 78, 'observed_absences': 433,
    'overall_daily_rate': 0.077,
    'by_weekday': {'Monday': 1.27, 'Friday': 0.78, 'Saturday': 1.2},
  },
  'days': [
    for (var i = 0; i < 8; i++)
      {
        'date': '2026-09-0${i + 1}', 'weekday': 'Monday',
        'expected_absences': 2.0 + i * 0.3, 'weekday_multiplier': 1.1,
        'event_teachers': i == 3 ? 12 : 0, 'events': i == 3 ? ['Sports Day'] : [],
        'departments': [
          {'department': 'Science', 'expected_absences': 0.6,
           'absorbable': 1, 'free_periods': 8, 'teachers': 9,
           'shortage_probability': 0.12},
        ],
      },
  ],
  'cards': [
    {'severity': 'critical', 'date': '2026-09-04', 'weekday': 'Thursday',
     'event': 'Sports Day', 'headline': 'Sports Day pulls 12 teachers off timetable',
     'because': 'Covering their lessons needs about 53 periods.'},
    {'severity': 'warning', 'date': '2026-09-01', 'department': 'PE',
     'recurring': true, 'weekdays': ['Thursday', 'Friday'],
     'headline': 'PE has no spare capacity on Thursday and Friday',
     'because': '6 staff share only 2 free periods.'},
  ],
});

final _docs = [
  ExtractedDocument.fromMap({
    'id': 'd1', 'status': 'needs_review', 'storage_path': 'scans/a.jpg',
    'confidence': 0.91,
    'template': {
      'id': 'tpl', 'name': 'Standard Admission Form', 'target': 'student',
      'fields': [
        {'key': 'full_name', 'label': 'Student Name', 'type': 'text',
         'required': true, 'maps_to': 'full_name'},
      ],
    },
    'extracted_json': {
      'error_count': 0, 'warning_count': 2, 'document_quality': 'good',
      'fields': [
        {'field': 'full_name', 'value': 'Manjeet Singh', 'raw_text': 'manJeet',
         'present_on_form': true, 'confidence': 0.95},
      ],
      'issues': [],
    },
  }),
];

DocumentTemplate _template() => DocumentTemplate.fromMap({
      'id': 'tpl', 'name': 'Standard Admission Form', 'target': 'student',
      'description': 'The default nine-field form.',
      'is_builtin': false, 'is_active': true,
      'fields': [
        {'key': 'full_name', 'label': 'Student Name', 'type': 'text',
         'required': true, 'maps_to': 'full_name'},
        {'key': 'date_of_birth', 'label': 'Date of Birth', 'type': 'date',
         'required': true, 'maps_to': 'date_of_birth'},
        {'key': 'gender', 'label': 'Gender', 'type': 'choice',
         'required': false, 'maps_to': 'gender', 'options': ['M', 'F']},
        {'key': 'klass', 'label': 'Class Applying For', 'type': 'grade',
         'required': true, 'maps_to': '__class'},
      ],
    });

// ------------------------------------------------------------------ harness
final _overrides = [
  myTimetableProvider.overrideWith((ref) async => _week()),
  activeTimetableProvider.overrideWith((ref) async => _week()),
  periodsTodayProvider.overrideWith((ref) async => _periods),
  myLeaveProvider.overrideWith((ref) async => _leave),
  pendingApprovalsProvider.overrideWith((ref) async => _leave),
  actionBoardProvider.overrideWith((ref) async => _board),
  staffingForecastProvider.overrideWith((ref) async => _forecast),
  documentQueueProvider.overrideWith((ref) async => _docs),
  backendHealthProvider.overrideWith((ref) async => {
        'connected': true,
        'row_counts': {
          'students': 1800, 'profiles': 56, 'classes': 40,
          'teaching_assignments': 320, 'attendance': 18000,
        },
      }),
  coverChangesProvider.overrideWith((ref) => Stream.value(1)),
];

/// Pumps [child] with an **unbounded height** above it, which is the condition
/// that surfaces this class of bug.
Future<void> pumpInScroll(
  WidgetTester tester,
  Widget child, {
  double width = 1180,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [child],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  final cards = <String, Widget>{
    'MyTimetableCard': const MyTimetableCard(),
    'TodayPeriodsCard': const TodayPeriodsCard(),
    'LeaveCard': const LeaveCard(),
    'HodApprovalsCard': const HodApprovalsCard(),
    'ActionBoardCard': const ActionBoardCard(),
    'ForecastSummaryCard': const ForecastSummaryCard(),
    'DocumentQueueCard': const DocumentQueueCard(),
    'TimetableSummaryCard': const TimetableSummaryCard(),
  };

  // 1180 is a typical desktop content width; 520 forces every narrow-layout
  // branch, which is where fallbacks live and therefore where they break; 380
  // is a phone, where any fixed-width chrome finally runs out of room.
  for (final width in [1180.0, 520.0, 380.0]) {
    group('renders with unbounded height at ${width.toInt()}px', () {
      cards.forEach((name, widget) {
        testWidgets(name, (tester) async {
          await pumpInScroll(tester, widget, width: width);
          expect(tester.takeException(), isNull,
              reason: '$name threw during layout — in release this renders '
                  'as a blank area with no error shown');
        });
      });
    });
  }

  // These two are full-screen pushed routes rather than dashboard cards, so
  // they get a bounded height from their own Scaffold. Pumped directly at
  // three widths — the review screen and the editor both switch between a
  // side-by-side and a stacked layout, and the stacked branch is where the
  // narrow bugs live.
  group('full-screen editors', () {
    for (final width in [1180.0, 760.0, 380.0]) {
      testWidgets('DocumentReviewScreen at ${width.toInt()}px', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(ProviderScope(
          overrides: _overrides,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: DocumentReviewScreen(document: _docs.first),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('TemplateEditorScreen at ${width.toInt()}px', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(ProviderScope(
          overrides: _overrides,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: TemplateEditorScreen(template: _template()),
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('review row shows all four field states', (tester) async {
      tester.view.physicalSize = const Size(700, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final controllers = List.generate(4, (_) => TextEditingController());
      addTearDown(() {
        for (final c in controllers) {
          c.dispose();
        }
      });

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(children: [
              // ok
              ReviewFieldRow(
                spec: TemplateField(
                    key: 'a', label: 'Student name', type: FieldType.text),
                extracted: ExtractedField.fromMap({
                  'field': 'a', 'value': 'Manjeet', 'raw_text': 'Manjeet',
                  'present_on_form': true, 'confidence': 0.97,
                }),
                controller: controllers[0],
                issues: const [],
                onChanged: () {},
              ),
              // needs review, with an error
              ReviewFieldRow(
                spec: TemplateField(
                    key: 'b', label: 'Class', type: FieldType.grade),
                extracted: ExtractedField.fromMap({
                  'field': 'b', 'value': '12', 'raw_text': '12th',
                  'present_on_form': true, 'confidence': 0.95,
                }),
                controller: controllers[1],
                issues: const [
                  ValidationIssue(
                      field: 'b',
                      severity: 'error',
                      code: 'grade_out_of_range',
                      message: 'Class 12 does not exist at this school.',
                      suggestion: 'Correct it to 1–10.'),
                ],
                onChanged: () {},
              ),
              // unreadable
              ReviewFieldRow(
                spec: TemplateField(
                    key: 'c', label: 'Previous school', type: FieldType.text),
                extracted: ExtractedField.fromMap({
                  'field': 'c', 'value': null, 'raw_text': null,
                  'present_on_form': true, 'confidence': 0.2,
                }),
                controller: controllers[2],
                issues: const [],
                onChanged: () {},
              ),
              // absent from the form
              ReviewFieldRow(
                spec: TemplateField(
                    key: 'd', label: 'Address', type: FieldType.longtext),
                extracted: ExtractedField.missing('d'),
                controller: controllers[3],
                issues: const [],
                onChanged: () {},
              ),
            ]),
          ),
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('must fix'), findsOneWidget);
      expect(find.text('unreadable'), findsOneWidget);
      expect(find.text('not on form'), findsOneWidget);
    });
  });

  group('primitives survive unbounded height', () {
    testWidgets('SectionCard with content', (tester) async {
      await pumpInScroll(
        tester,
        const SectionCard(
          title: 'A section',
          subtitle: 'with a subtitle',
          icon: Icons.school,
          child: Text('body'),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('A section'), findsOneWidget);
    });

    testWidgets('StatTile row wraps rather than overflowing', (tester) async {
      await pumpInScroll(
        tester,
        const Wrap(children: [
          StatTile(value: '1800', label: 'Students'),
          StatTile(value: '56', label: 'Staff'),
          StatTile(value: '1,440', label: 'Periods scheduled'),
        ]),
        width: 400,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Callout, StatusPill, EmptyState', (tester) async {
      await pumpInScroll(
        tester,
        const Column(children: [
          Callout(message: 'Something to check', detail: 'because of a reason'),
          StatusPill(label: 'live', tone: Tone.success),
          EmptyState(
              icon: Icons.inbox_outlined,
              title: 'Nothing here',
              message: 'Yet.'),
        ]),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Nothing here'), findsOneWidget);
    });
  });

  // An event row renders a Wrap of teacher chips inside another Wrap of
  // status pills. Twelve names at 380px is the case that would overflow.
  group('event row', () {
    SchoolEvent event({int staff = 12, int days = 3}) {
      final start = DateTime(2026, 9, 7);
      return SchoolEvent(
        id: 'e1',
        name: 'Annual Day 2026',
        startsOn: start,
        endsOn: start.add(Duration(days: days - 1)),
        days: days,
        eventType: 'annual_day',
        notes: 'Rehearsals in the main hall from second period.',
        teachers: [
          for (var i = 0; i < staff; i++)
            EventTeacher(id: 't$i', name: 'Teacher Number $i'),
        ],
      );
    }

    for (final width in [1180.0, 760.0, 380.0]) {
      testWidgets('busy event at ${width.toInt()}px', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await pumpInScroll(tester, EventRow(event: event(), onDelete: () {}));
        expect(tester.takeException(), isNull);
        expect(find.text('Annual Day 2026'), findsOneWidget);
      });
    }

    testWidgets('single day with nobody assigned', (tester) async {
      await pumpInScroll(
        tester,
        EventRow(event: event(staff: 0, days: 1), onDelete: () {}),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('No staff assigned'), findsOneWidget);
    });
  });

  // The whole point of SlowLoader is what it does after a delay, which is the
  // easiest kind of behaviour to break without noticing.
  group('SlowLoader', () {
    testWidgets('stays quiet for a normal-length load', (tester) async {
      await pumpInScroll(tester, const SlowLoader());
      await tester.pump(const Duration(seconds: 2));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Waking the server'), findsNothing,
          reason: 'a fast load must not flash an explanation');

      // Let the timer expire so the test does not end with it pending.
      await tester.pump(SlowLoader.explainAfter);
    });

    testWidgets('explains itself once the wait gets long', (tester) async {
      await pumpInScroll(tester, const SlowLoader());
      await tester.pump(SlowLoader.explainAfter + const Duration(seconds: 1));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Waking the server'), findsOneWidget);
      expect(find.textContaining('sleeps when idle'), findsOneWidget);
    });

    testWidgets('does not fire after being disposed', (tester) async {
      await pumpInScroll(tester, const SlowLoader());
      // Replace it before the timer would fire — a setState on a dead State
      // throws, and this is exactly how that bug reaches production.
      await pumpInScroll(tester, const Text('gone'));
      await tester.pump(SlowLoader.explainAfter + const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
    });

    testWidgets('fits a narrow screen', (tester) async {
      tester.view.physicalSize = const Size(380, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpInScroll(tester, const SlowLoader());
      await tester.pump(SlowLoader.explainAfter + const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  });

  // A month grid is a GridView with shrinkWrap inside a scroll view, and the
  // wide layout puts two months in a Wrap — which hands its children unbounded
  // width. Both have bitten this codebase before.
  group('exam calendar', () {
    Sitting sitting(int day, List<int> grades, {bool planned = false}) =>
        Sitting(
          id: 's$day',
          sitsOn: DateTime(2026, 9, day),
          grades: grades,
          paper: 'Paper $day',
          planStats: planned ? const {'seated': 180} : null,
        );

    for (final width in [1180.0, 760.0, 380.0]) {
      testWidgets('populated month at ${width.toInt()}px', (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await pumpInScroll(
          tester,
          ExamCalendar(
            initialMonth: DateTime(2026, 9),
            sittings: [
              sitting(7, [1, 2], planned: true),
              sitting(9, [1, 2]),
              // Three grades on one day exercises the "N grades" label.
              sitting(10, [1, 2, 3]),
              sitting(30, [3]),
            ],
            onPickDay: (_) {},
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('empty calendar still renders', (tester) async {
      await pumpInScroll(
        tester,
        ExamCalendar(
          initialMonth: DateTime(2026, 9),
          sittings: const [],
          onPickDay: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('February in a leap year', (tester) async {
      await pumpInScroll(
        tester,
        ExamCalendar(
          initialMonth: DateTime(2028, 2),
          sittings: [sitting(29, [1])],
          onPickDay: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  // A seat grid is a Row inside a horizontal scroll view — the same family as
  // the bug that rendered the timetable blank in release. Ten columns will not
  // fit 380px, and that is fine; what must not happen is a throw.
  group('seating room grid', () {
    RoomPlan room({int rows = 5, int cols = 10, int fill = 45}) {
      const classes = ['1A', '1B', '1C', '1D'];
      final seats = <SeatEntry>[];
      var n = 0;
      for (var r = 1; r <= rows && n < fill; r++) {
        for (var c = 1; c <= cols && n < fill; c++) {
          seats.add(SeatEntry(
            row: r,
            col: c,
            studentName: 'Student $n',
            rollNo: n + 1,
            // Cycles so no two neighbours match, as the engine produces.
            className: classes[(r + c) % classes.length],
          ));
          n++;
        }
      }
      return RoomPlan(
        roomId: 'r1',
        roomName: 'A-101',
        rows: rows,
        cols: cols,
        block: 'A',
        floorNo: 1,
        classes: classes,
        seats: seats,
      );
    }

    for (final width in [1180.0, 760.0, 380.0]) {
      testWidgets('full room at ${width.toInt()}px', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await pumpInScroll(tester, SeatingRoomGrid(room: room()));
        expect(tester.takeException(), isNull);
        expect(find.text('A-101'), findsOneWidget);
      });
    }

    testWidgets('half-empty room leaves blank seats', (tester) async {
      await pumpInScroll(tester, SeatingRoomGrid(room: room(fill: 12)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('room with no seats at all', (tester) async {
      await pumpInScroll(tester, SeatingRoomGrid(room: room(fill: 0)));
      expect(tester.takeException(), isNull);
    });
  });

  // The onboarding preview builds its own state as you use it, so an empty
  // render proves very little — the crowded state is where a Wrap or a Row
  // runs out of width.
  group('Admin (new) setup preview', () {
    for (final width in [1180.0, 760.0, 380.0]) {
      testWidgets('empty at ${width.toInt()}px', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(
          theme: buildAppTheme(),
          home: const DemoSetupScreen(),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('populated at ${width.toInt()}px', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(
          theme: buildAppTheme(),
          home: const DemoSetupScreen(),
        ));
        await tester.pump();

        // ensureVisible before each tap: at 380px these controls start below
        // the fold, and a tap on an off-screen widget silently does nothing.
        Future<void> tapText(String label) async {
          final f = find.text(label);
          await tester.ensureVisible(f);
          await tester.pumpAndSettle();
          await tester.tap(f);
          await tester.pump();
        }

        await tapText('Add classes');
        expect(tester.takeException(), isNull);
        expect(find.text('Class 6A'), findsOneWidget);

        await tapText('Generate invite link');
        expect(tester.takeException(), isNull);

        // Expand a class and name a student — the chip Wrap under a narrow
        // viewport is the part most likely to overflow.
        await tapText('Class 6A');
        await tester.enterText(
            find.widgetWithText(TextField, 'Student name'), 'Aarav Menon');
        await tester.tap(find.widgetWithText(FilledButton, 'Add'));
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('Aarav Menon'), findsOneWidget);
      });
    }
  });
}
