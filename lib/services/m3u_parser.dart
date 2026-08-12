import 'dart:convert';

import '../models/channel.dart';

class M3uParser {
  const M3uParser();

  List<Channel> parse(String source) {
    final lines = source
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final channels = <Channel>[];
    String? pendingInfo;
    final pendingHeaders = <String, String>{};

    for (final line in lines) {
      if (line.startsWith('#EXTINF:')) {
        pendingInfo = line;
        pendingHeaders.clear();
        continue;
      }

      if (pendingInfo != null && line.startsWith('#EXTVLCOPT:')) {
        final option = line.substring('#EXTVLCOPT:'.length);
        final separator = option.indexOf('=');
        if (separator > 0) {
          final key = option.substring(0, separator).toLowerCase();
          final value = option.substring(separator + 1).trim();
          if (key == 'http-user-agent') pendingHeaders['User-Agent'] = value;
          if (key == 'http-referrer' || key == 'http-referer') {
            pendingHeaders['Referer'] = value;
          }
        }
        continue;
      }

      if (pendingInfo != null && line.startsWith('#EXTHTTP:')) {
        try {
          final decoded = jsonDecode(line.substring('#EXTHTTP:'.length));
          if (decoded is Map) {
            for (final entry in decoded.entries) {
              final name = entry.key.toString();
              if ({'user-agent', 'referer', 'authorization'}
                  .contains(name.toLowerCase())) {
                final canonical = name.toLowerCase() == 'user-agent'
                    ? 'User-Agent'
                    : name.toLowerCase() == 'referer'
                        ? 'Referer'
                        : 'Authorization';
                pendingHeaders[canonical] = entry.value.toString();
              }
            }
          }
        } on FormatException {
          // Ignore malformed optional header metadata and keep parsing.
        }
        continue;
      }

      if (line.startsWith('#')) {
        continue;
      }

      if (pendingInfo != null && _looksLikeUrl(line)) {
        channels.add(_buildChannel(pendingInfo, line, pendingHeaders));
        pendingInfo = null;
        pendingHeaders.clear();
      }
    }

    return channels;
  }

  Channel _buildChannel(
    String info,
    String url,
    Map<String, String> headers,
  ) {
    final commaIndex = info.lastIndexOf(',');
    final name = commaIndex >= 0 && commaIndex + 1 < info.length
        ? info.substring(commaIndex + 1).trim()
        : 'Canal';

    String? attribute(String key) {
      final match = RegExp('$key="([^"]*)"', caseSensitive: false)
          .firstMatch(info);
      final value = match?.group(1)?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    return Channel(
      name: name.isEmpty ? 'Canal' : name,
      url: url,
      logoUrl: attribute('tvg-logo'),
      group: attribute('group-title'),
      tvgId: attribute('tvg-id'),
      headers: Map.unmodifiable(headers),
    );
  }

  bool _looksLikeUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }
}
