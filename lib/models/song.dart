// Represents an individual audio track (song) in the application.
// 
// This data model stores all essential metadata about a song—such as its title,
// artist, album, thumbnail, duration, and audio source (e.g., YouTube or JioSaavn).
// It also handles serialization to/from JSON and equality comparisons.
class Song {
  // A default placeholder image URL used when a song does not have any album art available.
  static const String fallbackArtUrl = 'https://picsum.photos/300';

  // Unique identifier for the song (e.g., YouTube video ID or JioSaavn song ID).
  final String id;

  // The title or name of the song.
  final String title;

  // The name of the artist or band who performed the song.
  final String artist;

  // The album name or collection this song belongs to (defaults to 'Single' if unknown).
  final String album;

  // URL pointing to the album cover image or video thumbnail.
  final String thumbnailUrl;

  // Total duration of the song in seconds.
  final int duration;

  // The platform or service where the song originates (e.g., 'youtube' or 'saavn').
  final String source;

  // An optional video ID used when playing a specific video version in YouTube playlists.
  final String? setVideoId;

  // Default constructor for creating a Song object with all required fields.
  const Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.thumbnailUrl,
    required this.duration,
    required this.source,
    this.setVideoId,
  });

  // Factory constructor to create a Song object from a standard JSON Map.
  // This is commonly used when reading saved songs from local storage or generic APIs.
  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      // Clean and sanitize string fields, providing sensible defaults if missing.
      id: _clean(json['id']) ?? '',
      title: _clean(json['title']) ?? 'Unknown Track',
      artist: _clean(json['artist']) ?? 'Unknown Artist',
      album: _clean(json['album']) ?? 'Single',
      thumbnailUrl: _clean(json['thumbnailUrl']) ?? '',
      // Safely parse duration from whatever type it is (int or string) to an integer.
      duration: int.tryParse(json['duration']?.toString() ?? '0') ?? 0,
      source: _clean(json['source']) ?? 'youtube',
    );
  }

  // Alias for fromJson to allow converting from standard Dart Maps interchangeably.
  factory Song.fromMap(Map<String, dynamic> map) => Song.fromJson(map);


  // Factory constructor specifically designed to parse JioSaavn API responses.
  // JioSaavn has its own distinct JSON structure with nested artist, album, and image fields.
  factory Song.fromSaavnJson(Map<String, dynamic> json) {
    return Song(
      id: _clean(json['id']) ?? '',
      // Saavn uses 'name' for track title; fallback to 'title' or 'Unknown Track' if missing.
      title: _clean(json['name']) ?? _clean(json['title']) ?? 'Unknown Track',
      artist: _extractSaavnArtist(json),
      album: _extractSaavnAlbum(json),
      thumbnailUrl: _extractSaavnImage(json),
      // Duration in Saavn is often sent as a string of seconds.
      duration: int.tryParse(json['duration']?.toString() ?? '0') ?? 0,
      source: 'saavn',
      setVideoId: _clean(json['setVideoId']),
    );
  }

  // Converts the Song object into a standard JSON-compatible Map.
  // Used when saving to SharedPreferences, local cache, or sending over network.
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> map = {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'thumbnailUrl': thumbnailUrl,
      'duration': duration,
      'source': source,
    };
    // Only include setVideoId if present to avoid storing unnecessary null keys.
    if (setVideoId != null) {
      map['setVideoId'] = setVideoId;
    }
    return map;
  }

  // Alias method for toJson() to adhere to Dart map serialization conventions.
  Map<String, dynamic> toMap() => toJson();

  // Returns a new Song instance with updated values for specified fields while keeping
  // all other properties unchanged. This pattern supports immutable state updates.
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

  // Extracts the highest quality image URL from JioSaavn's image array or string.
  // JioSaavn provides images in multiple qualities; iterating in reverse finds the highest resolution.
  static String _extractSaavnImage(Map<String, dynamic> json) {
    final image = json['image'];
    // When image is an array of quality objects (e.g., 50x50, 150x150, 500x500):
    if (image is List && image.isNotEmpty) {
      // Loop backwards through images to get the highest resolution available.
      for (final item in image.reversed) {
        if (item is Map<String, dynamic>) {
          final url = _clean(item['url']);
          if (url != null && url.isNotEmpty) return url;
        }
      }
    }

    // When image is already a direct URL string.
    final rawImage = _clean(image);
    if (rawImage != null && rawImage.isNotEmpty) return rawImage;
    // Fall back to the default placeholder image if no valid image was found.
    return fallbackArtUrl;
  }

  // Extracts and formats artist names from various JioSaavn JSON formats into a single clean string.
  static String _extractSaavnArtist(Map<String, dynamic> json) {
    // Check for direct primaryArtists string field first.
    final primaryArtists = _clean(json['primaryArtists']);
    if (primaryArtists != null && primaryArtists.isNotEmpty) {
      return primaryArtists;
    }

    // Check alternative snake_case key name.
    final primaryArtistsText = _clean(json['primary_artists']);
    if (primaryArtistsText != null && primaryArtistsText.isNotEmpty) {
      return primaryArtistsText;
    }

    // Check nested artists map containing primary and all artist lists.
    final artists = json['artists'];
    if (artists is Map<String, dynamic>) {
      final primary = artists['primary'];
      if (primary is List && primary.isNotEmpty) {
        // Collect names of primary artists into a comma-separated string.
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
        // Fallback: collect names of all artists if primary was empty.
        final names = all
            .whereType<Map<String, dynamic>>()
            .map((artist) => _clean(artist['name']))
            .whereType<String>()
            .where((name) => name.isNotEmpty)
            .toList();
        if (names.isNotEmpty) return names.join(', ');
      }
    }

    // Check legacy 'singers' field as fallback.
    final singers = _clean(json['singers']);
    if (singers != null && singers.isNotEmpty) return singers;
    return 'Unknown Artist';
  }

  // Safely extracts the album title from JioSaavn JSON.
  // Saavn sometimes nests album data inside a Map, or supplies it directly as a String.
  static String _extractSaavnAlbum(Map<String, dynamic> json) {
    final album = json['album'];
    if (album is Map<String, dynamic>) {
      return _clean(album['name']) ?? 'Single';
    }

    return _clean(album) ?? 'Single';
  }

  // Two songs are considered equal if they have the same ID and come from the same source.
  // This prevents identical songs from different platforms or duplicates in lists.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Song &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          source == other.source;

  // Generates a hash code combining the song ID and source.
  @override
  int get hashCode => id.hashCode ^ source.hashCode;

  // Cleans strings by trimming whitespace, checking for null/empty values,
  // and decoding common HTML character entities (like &amp; into &).
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
