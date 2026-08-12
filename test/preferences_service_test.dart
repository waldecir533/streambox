import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:streambox/models/channel.dart';
import 'package:streambox/services/preferences_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persists and restores the cached channel list', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = PreferencesService();
    const channels = [
      Channel(
        name: 'Canal salvo',
        url: 'https://example.com/live.m3u8',
        group: 'Notícias',
        tvgId: 'news',
        headers: {'Authorization': 'Bearer test-token'},
      ),
    ];

    await preferences.saveChannels(channels);
    final restored = await preferences.cachedChannels();

    expect(restored, hasLength(1));
    expect(restored.single.name, 'Canal salvo');
    expect(restored.single.url, channels.single.url);
    expect(restored.single.group, 'Notícias');
    expect(restored.single.headers['Authorization'], 'Bearer test-token');
  });

  test('ignores an invalid cached list without deleting saved access', () async {
    SharedPreferences.setMockInitialValues({
      'playlist_url': 'https://example.com/list.m3u',
      'cached_channels': 'invalid-json',
    });
    final preferences = PreferencesService();

    expect(await preferences.cachedChannels(), isEmpty);
    expect(await preferences.playlistUrl(), 'https://example.com/list.m3u');
  });
}
