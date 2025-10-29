// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:safecopy_mobile/main.dart';

void main() {
  testWidgets('App shows title and empty job list',
      (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());

    // Verify the app title appears in the AppBar.
    expect(find.text('SafeCopy Mobile'), findsOneWidget);

    // The initial UI shows 'No jobs yet' when the job list is empty.
    expect(find.text('No jobs yet'), findsOneWidget);
  });
}
