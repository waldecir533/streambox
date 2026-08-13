/// Tipo de conteúdo identificado pela fonte (playlist, stream individual,
/// etc.). Mantém cada canal com o tipo do fluxo em que entrou, sem misturar
/// importações diferentes.
enum SourceKind {
  /// Canal de uma playlist M3U/M3U8.
  playlist,

  /// Stream individual adicionado pelo usuário (HLS, MPEG-TS, MP4...).
  individual,
}

class Channel {
  const Channel({
    required this.name,
    required this.url,
    this.logoUrl,
    this.group,
    this.tvgId,
    this.tvgName,
    this.tvgLanguage,
    this.tvgCountry,
    this.tvgUrl,
    this.epgTitle,
    this.epgStart,
    this.epgEnd,
    this.headers = const {},
    this.sourceKind = SourceKind.playlist,
    this.contentType,
  });

  final String name;
  final String url;
  final String? logoUrl;
  final String? group;
  final String? tvgId;
  final String? tvgName;
  final String? tvgLanguage;
  final String? tvgCountry;
  final String? tvgUrl;
  final String? epgTitle;
  final DateTime? epgStart;
  final DateTime? epgEnd;
  final Map<String, String> headers;
  final SourceKind sourceKind;

  /// Tipo de mídia sugerido pelo conteúdo (ex.: video/mp2t, application/x-mpegURL,
  /// video/mp4). Usado pelo player e pelo servidor de transmissão local.
  final String? contentType;

  String get id => tvgId?.isNotEmpty == true ? tvgId! : url;

  bool get isHls => contentType?.contains('mpegurl') == true ||
      url.toLowerCase().endsWith('.m3u8');
  bool get isMpegTs => contentType?.contains('mp2t') == true ||
      url.toLowerCase().endsWith('.ts');
  bool get isMp4 => contentType?.contains('mp4') == true ||
      url.toLowerCase().endsWith('.mp4');

  Channel copyWithEpg({String? epgTitle, DateTime? epgStart, DateTime? epgEnd}) =>
      Channel(name: name, url: url, logoUrl: logoUrl, group: group, tvgId: tvgId, headers: headers,
        epgTitle: epgTitle ?? this.epgTitle, epgStart: epgStart ?? this.epgStart,
        epgEnd: epgEnd ?? this.epgEnd);

  Map<String, Object?> toJson() => {
        'name': name,
        'url': url,
        'logoUrl': logoUrl,
        'group': group,
        'tvgId': tvgId,
        'tvgName': tvgName,
        'tvgLanguage': tvgLanguage,
        'tvgCountry': tvgCountry,
        'tvgUrl': tvgUrl,
        'headers': headers,
        'sourceKind': sourceKind.name,
        'contentType': contentType,
      };

  /// Constrói a partir de um mapa bruto gerado pelo parser (aceita o mesmo
  /// formato de [fromJson], mas com valores opcionais sempre válidos).
  factory Channel.fromJsonMap(Map<String, dynamic> json) {
    final raw = json.map((key, value) => MapEntry(key.toString(), value));
    return Channel.fromJson(Map<String, dynamic>.unmodifiable(raw));
  }

  factory Channel.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final url = json['url'];
    if (name is! String || url is! String || name.isEmpty || url.isEmpty) {
      throw const FormatException('Canal salvo inválido.');
    }
    SourceKind kind = SourceKind.playlist;
    final rawKind = json['sourceKind'];
    if (rawKind is String) {
      kind = SourceKind.values.firstWhere(
        (v) => v.name == rawKind,
        orElse: () => SourceKind.playlist,
      );
    }
    return Channel(
      name: name,
      url: url,
      logoUrl: json['logoUrl'] as String?,
      group: json['group'] as String?,
      tvgId: json['tvgId'] as String?,
      tvgName: json['tvgName'] as String?,
      tvgLanguage: json['tvgLanguage'] as String?,
      tvgCountry: json['tvgCountry'] as String?,
      tvgUrl: json['tvgUrl'] as String?,
      headers: (json['headers'] as Map?)?.map(
            (key, value) => MapEntry(key.toString(), value.toString()),
          ) ??
          const {},
      sourceKind: kind,
      contentType: json['contentType'] as String?,
    );
  }

  Channel copyWithChannel({
    String? name,
    String? url,
    String? logoUrl,
    String? group,
    String? tvgId,
    SourceKind? sourceKind,
    String? contentType,
  }) =>
      Channel(
        name: name ?? this.name,
        url: url ?? this.url,
        logoUrl: logoUrl ?? this.logoUrl,
        group: group ?? this.group,
        tvgId: tvgId ?? this.tvgId,
        tvgName: tvgName,
        tvgLanguage: tvgLanguage,
        tvgCountry: tvgCountry,
        tvgUrl: tvgUrl,
        epgTitle: epgTitle,
        epgStart: epgStart,
        epgEnd: epgEnd,
        headers: headers,
        sourceKind: sourceKind ?? this.sourceKind,
        contentType: contentType ?? this.contentType,
      );
}
