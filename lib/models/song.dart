class Song {
  static const String fallbackArtUrl = 'https://picsum.photos/300';

  final String id;
  final String title;
  final String artist;
  final String album;
  final String thumbnailUrl;
  final int duration;
  final String source;

  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.thumbnailUrl,
    required this.duration,
    required this.source,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: _clean(json['id']) ?? '',
      title: _clean(json['title']) ?? 'Unknown Track',
      artist: _clean(json['artist']) ?? 'Unknown Artist',
      album: _clean(json['album']) ?? 'Single',
      thumbnailUrl: _clean(json['thumbnailUrl']) ?? '',
      duration: int.tryParse(json['duration']?.toString() ?? '0') ?? 0,
      source: _clean(json['source']) ?? 'youtube',
    );
  }

  factory Song.fromMap(Map<String, dynamic> map) => Song.fromJson(map);

  factory Song.fromSaavnJson(Map<String, dynamic> json) {
    return Song(
      id: _clean(json['id']) ?? '',
      title: _clean(json['name']) ?? _clean(json['title']) ?? 'Unknown Track',
      artist: _extractSaavnArtist(json),
      album: _extractSaavnAlbum(json),
      thumbnailUrl: _extractSaavnImage(json),
      duration: int.tryParse(json['duration']?.toString() ?? '0') ?? 0,
      source: 'saavn',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'thumbnailUrl': thumbnailUrl,
      'duration': duration,
      'source': source,
    };
  }

  Map<String, dynamic> toMap() => toJson();

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    String? thumbnailUrl,
    int? duration,
    String? source,
  }) {
    return Song(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      duration: duration ?? this.duration,
      source: source ?? this.source,
    );
  }

  static String _extractSaavnImage(Map<String, dynamic> json) {
    final image = json['image'];
    if (image is List && image.isNotEmpty) {
      for (final item in image.reversed) {
        if (item is Map<String, dynamic>) {
          final url = _clean(item['url']);
          if (url != null && url.isNotEmpty) return url;
        }
      }
    }

    final rawImage = _clean(image);
    if (rawImage != null && rawImage.isNotEmpty) return rawImage;
    return fallbackArtUrl;
  }

  static String _extractSaavnArtist(Map<String, dynamic> json) {
    final primaryArtists = _clean(json['primaryArtists']);
    if (primaryArtists != null && primaryArtists.isNotEmpty) {
      return primaryArtists;
    }

    final primaryArtistsText = _clean(json['primary_artists']);
    if (primaryArtistsText != null && primaryArtistsText.isNotEmpty) {
      return primaryArtistsText;
    }

    final artists = json['artists'];
    if (artists is Map<String, dynamic>) {
      final primary = artists['primary'];
      if (primary is List && primary.isNotEmpty) {
        final names = primary
            .whereType<Map<String, dynamic>>()
            .map((artist) => _clean(artist['name']))
            .whereType<String>()
            .where((name) => name.isNotEmpty)
            .toList();
        if (names.isNotEmpty) return names.join(', ');
      }

      final all = artists['all'];
      if (all is List && all.isNotEmpty) {
        final names = all
            .whereType<Map<String, dynamic>>()
            .map((artist) => _clean(artist['name']))
            .whereType<String>()
            .where((name) => name.isNotEmpty)
            .toList();
        if (names.isNotEmpty) return names.join(', ');
      }
    }

    final singers = _clean(json['singers']);
    if (singers != null && singers.isNotEmpty) return singers;
    return 'Unknown Artist';
  }

  static String _extractSaavnAlbum(Map<String, dynamic> json) {
    final album = json['album'];
    if (album is Map<String, dynamic>) {
      return _clean(album['name']) ?? 'Single';
    }

    return _clean(album) ?? 'Single';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          source == other.source;

  @override
  int get hashCode => id.hashCode ^ source.hashCode;

  static String? _clean(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty || text == 'null') return null;
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
  }
}
