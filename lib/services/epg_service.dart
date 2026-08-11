import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';
import '../models/channel.dart';

class EpgService {
  Future<Map<String, ({String title, DateTime start, DateTime end})>> loadNow(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.hasScheme) throw const FormatException('URL de EPG inválida.');
    final response = await http.get(uri).timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) throw Exception('EPG respondeu HTTP ${response.statusCode}.');
    final now = DateTime.now();
    final result = <String, ({String title, DateTime start, DateTime end})>{};
    final document = XmlDocument.parse(response.body);
    for (final node in document.findAllElements('programme')) {
      final channel = node.getAttribute('channel');
      final start = _date(node.getAttribute('start'));
      final end = _date(node.getAttribute('stop'));
      if (channel == null || start == null || end == null || now.isBefore(start) || !now.isBefore(end)) continue;
      result[channel] = (title: node.getElement('title')?.innerText.trim() ?? 'No ar', start: start, end: end);
    }
    return result;
  }
  DateTime? _date(String? value) {
    if (value == null || value.length < 14) return null;
    final base = value.substring(0, 14);
    final parsed = DateTime.tryParse('${base.substring(0,4)}-${base.substring(4,6)}-${base.substring(6,8)}T${base.substring(8,10)}:${base.substring(10,12)}:${base.substring(12,14)}');
    return parsed;
  }
  List<Channel> apply(List<Channel> channels, Map<String, ({String title, DateTime start, DateTime end})> programmes) => channels.map((c) {
    final p = c.tvgId == null ? null : programmes[c.tvgId];
    return p == null ? c : c.copyWith(epgTitle: p.title, epgStart: p.start, epgEnd: p.end);
  }).toList();
}
