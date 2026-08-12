import 'package:flutter/material.dart';
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

  testWidgets('opens visible DLNA test screen from overflow menu',
      (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const StreamBoxApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('Teste DLNA'), findsOneWidget);
    await tester.tap(find.text('Teste DLNA'));
    await tester.pumpAndSettle();

    expect(find.text('Buscar TVs'), findsOneWidget);
    expect(find.text('Reproduzir vídeo MP4 de teste'), findsOneWidget);
    expect(find.textContaining('lista IPTV'), findsOneWidget);
  });
}
