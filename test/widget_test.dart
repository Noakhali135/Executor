import 'package:executor/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('DevRunner App smoke test', (WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // Without this the shell's startup read of the saved working directory
    // throws MissingPluginException and the app never renders a frame.
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const DevRunnerApp());
    await tester.pumpAndSettle();

    expect(find.byType(DevRunnerApp), findsOneWidget);
    expect(find.text('EXECUTE SCRIPT'), findsOneWidget);
    expect(find.text('Runner'), findsOneWidget);
    expect(find.text('Explorer'), findsOneWidget);
  });
}
