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

    for (final line in lines) {
      if (line.startsWith('#EXTINF:')) {
        pendingInfo = line;
        continue;
      }

      if (line.startsWith('#')) {
        continue;
      }

      if (pendingInfo != null && _looksLikeUrl(line)) {
        channels.add(_buildChannel(pendingInfo, line));
        pendingInfo = null;
      }
    }

    return channels;
  }

  Channel _buildChannel(String info, String url) {
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
    );
  }

  bool _looksLikeUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https');
  }
}
