class Channel {
  const Channel({
    required this.name,
    required this.url,
    this.logoUrl,
    this.group,
    this.tvgId,
    this.epgTitle,
    this.epgStart,
    this.epgEnd,
    this.headers = const {},
  });

  final String name;
  final String url;
  final String? logoUrl;
  final String? group;
  final String? tvgId;
  final String? epgTitle;
  final DateTime? epgStart;
  final DateTime? epgEnd;
  final Map<String, String> headers;

  String get id => tvgId?.isNotEmpty == true ? tvgId! : url;

  Channel copyWith({String? epgTitle, DateTime? epgStart, DateTime? epgEnd}) =>
      Channel(name: name, url: url, logoUrl: logoUrl, group: group, tvgId: tvgId, headers: headers,
        epgTitle: epgTitle ?? this.epgTitle, epgStart: epgStart ?? this.epgStart,
        epgEnd: epgEnd ?? this.epgEnd);

  Map<String, Object?> toJson() => {
        'name': name,
        'url': url,
        'logoUrl': logoUrl,
        'group': group,
        'tvgId': tvgId,
        'headers': headers,
      };

  factory Channel.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final url = json['url'];
    if (name is! String || url is! String || name.isEmpty || url.isEmpty) {
      throw const FormatException('Canal salvo inválido.');
    }
    return Channel(
      name: name,
      url: url,
      logoUrl: json['logoUrl'] as String?,
      group: json['group'] as String?,
      tvgId: json['tvgId'] as String?,
      headers: (json['headers'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          const {},
    );
  }
}
