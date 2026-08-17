import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_school/widgets/student_avatar.dart';

/// A pupil's face, or their initials.
///
/// The fallback is not only "no photo yet": the URL is signed and expires, so
/// a register left open on a desk all morning eventually fails to load
/// pictures it loaded fine an hour earlier. It has to land on initials rather
/// than a broken-image icon.

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Center(child: child)),
  ));
}

void main() {
  testWidgets('shows initials when there is no photo', (tester) async {
    await pump(tester, const StudentAvatar(initials: 'MS'));
    expect(find.text('MS'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('falls back to initials when the photo will not load',
      (tester) async {
    // No HTTP in a widget test, so the network image always errors — which is
    // precisely the case being checked.
    await pump(tester, const StudentAvatar(
      initials: 'MS',
      photoUrl: 'https://example.invalid/expired.jpg',
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('MS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('strikes the initials through for an absent pupil',
      (tester) async {
    await pump(tester, const StudentAvatar(initials: 'MS', struckThrough: true));

    final text = tester.widget<Text>(find.text('MS'));
    expect(text.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('never draws a line across a face', (tester) async {
    // Dimmed instead. A line through a child's photograph says something
    // considerably worse than "off school today".
    await pump(tester, const StudentAvatar(
      initials: 'MS',
      photoUrl: 'https://example.invalid/p.jpg',
      struckThrough: true,
    ));
    await tester.pump();

    expect(find.byType(Opacity), findsWidgets);
  });

  testWidgets('honours the radius it is given', (tester) async {
    await pump(tester, const StudentAvatar(initials: 'MS', radius: 32));

    final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
    expect(avatar.radius, 32);
  });

  testWidgets('survives an empty name without throwing', (tester) async {
    await pump(tester, const StudentAvatar(initials: ''));
    expect(tester.takeException(), isNull);
  });
}
