import 'package:flutter_test/flutter_test.dart';
import 'package:executor/main.dart';

void main() {
  testWidgets('DevRunner App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const DevRunnerApp());
    expect(find.byType(DevRunnerApp), findsOneWidget);
  });
}