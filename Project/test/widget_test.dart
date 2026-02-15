import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easy_gui_flash_tool/main.dart';

void main() {
  testWidgets('Flash tool screen renders correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // Title
    expect(find.text('EasyGUI Flash Tool'), findsOneWidget);

    // Action buttons
    expect(find.text('Backup & Flash'), findsOneWidget);
    expect(find.text('Backup (Read) Only'), findsOneWidget);
    expect(find.text('Write Firmware'), findsOneWidget);

    // Platform dropdown
    expect(find.text('Platform:'), findsOneWidget);

    // Firmware section
    expect(find.text('Firmware:'), findsOneWidget);
  });
}
