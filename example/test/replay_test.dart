import 'package:ferrostar_flutter_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('replay reaches the exit banner and arrives', (tester) async {
    await tester.pumpWidget(const ExampleApp());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Start'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('EXIT 247'), findsOneWidget);
    // 700 fixes at 40 ms each.
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('ARRIVED'), findsOneWidget);
  });
}
