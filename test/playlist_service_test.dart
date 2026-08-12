import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:streambox/services/playlist_service.dart';

void main() {
  test('keeps TimeoutException available for friendly UI handling', () async {
    final client = MockClient((_) => Completer<http.Response>().future);
    final service = PlaylistService(
      client: client,
      timeout: const Duration(milliseconds: 1),
    );

    await expectLater(
      service.loadFromUrl('https://example.com/list.m3u'),
      throwsA(isA<TimeoutException>()),
    );
    service.dispose();
  });
}
