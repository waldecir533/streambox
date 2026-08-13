import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/models/channel.dart';
import 'package:streambox/widgets/channel_list_tile.dart';

void main() {
  testWidgets('ChannelListTile exibe nome, subtítulo e favorito', (tester) async {
    final channel = Channel(
      name: 'Globo SP',
      group: 'Abertos',
      epgTitle: 'TV Globo - São Paulo',
      url: 'http://exemplo.local/hls/globo.m3u8',
    );

    bool favoriteToggled = false;
    bool opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChannelListTile(
            channel: channel,
            isFavorite: true,
            onToggleFavorite: () => favoriteToggled = true,
            onOpen: () => opened = true,
          ),
        ),
      ),
    );

    expect(find.text('Globo SP'), findsOneWidget);
    expect(find.text('TV Globo - São Paulo'), findsOneWidget);
    expect(find.byIcon(Icons.star), findsOneWidget);
    expect(find.byIcon(Icons.star_border), findsNothing);

    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(favoriteToggled, isTrue);

    await tester.tap(find.text('Globo SP'));
    await tester.pump();
    expect(opened, isTrue);
  });
}
