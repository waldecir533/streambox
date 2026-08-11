import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:streambox/main.dart';

void main() {
  testWidgets('shows the StreamBox welcome screen', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const StreamBoxApp());
    await tester.pumpAndSettle();

    expect(find.text('StreamBox'), findsOneWidget);
    expect(find.text('Adicionar acesso'), findsOneWidget);
  });
}
