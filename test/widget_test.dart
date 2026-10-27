import 'package:flutter_test/flutter_test.dart';
import 'package:background_sync_demo/main.dart';

void main() {
  testWidgets('renders start button', (tester) async {
    await tester.pumpWidget(const SyncApp());
    expect(find.text('Background Sync Demo'), findsOneWidget);
  });
}
