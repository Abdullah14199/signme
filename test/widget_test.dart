// Basic smoke test for the SignMe ID scan prototype.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:signme/main.dart';

void main() {
  testWidgets('ID scan page renders its core controls', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    await tester.pumpWidget(const SignMeApp());

    expect(find.text('SignMe · Egyptian ID Scan'), findsOneWidget);
    expect(find.text('SignMe API key'), findsOneWidget);
    expect(find.text('Scan ID'), findsOneWidget);
  });

  testWidgets('Scanning without an API key shows a validation error', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1400));
    await tester.pumpWidget(const SignMeApp());

    await tester.tap(find.text('Scan ID'));
    await tester.pump();

    expect(find.text('Enter your SignMe API key first.'), findsOneWidget);
  });
}
