// Represents a curated collection or playlist of songs in the application.
// 
// This model stores playlist metadata—such as its name, owner, thumbnail image,
// number of items, and provider source (e.g., YouTube or local storage).
// It supports conversion to/from Maps for local caching and equality comparisons.
class MusicPlaylist {
  // Unique identifier for the playlist (e.g., YouTube playlist ID or local ID).
  final String id;

  // The title or name of the playlist.
  final String title;

  // The creator or owner of the playlist (e.g., 'Me', user's channel name).
  final String owner;

  // Web URL pointing to the playlist cover art or preview thumbnail.
  final String thumbnailUrl;

  // Total count of tracks/songs contained within this playlist.
  final int itemCount;

  // The provider platform where this playlist lives (e.g., 'youtube' or 'local').
  final String source;

  // Default constructor for creating a MusicPlaylist instance with all required metadata.
  const MusicPlaylist({
    required this.id,
    required this.title,
    required this.owner,
    required this.thumbnailUrl,
    required this.itemCount,
    required this.source,
  });

  // Converts this MusicPlaylist instance into a Map for JSON serialization and local storage.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'owner': owner,
      'thumbnailUrl': thumbnailUrl,
      'itemCount': itemCount,
      'source': source,
    };
  }

  // Factory constructor to recreate a MusicPlaylist instance from a serialized Map.
  // Provides sensible fallback default values in case any map key is null or missing.
  factory MusicPlaylist.fromMap(Map<String, dynamic> map) {
    return MusicPlaylist(
      // Default to an empty string if ID is missing.
      id: map['id'] ?? '',
      // Default to 'Unknown Playlist' if no title is present.
      title: map['title'] ?? 'Unknown Playlist',
      // Default to 'Unknown Owner' if owner is absent.
      owner: map['owner'] ?? 'Unknown Owner',
      // Default to empty string if no thumbnail URL is provided.
      thumbnailUrl: map['thumbnailUrl'] ?? '',
      // Default to 0 tracks if count is missing.
      itemCount: map['itemCount'] ?? 0,
      // Default source to 'youtube' if not explicitly defined.
      source: map['source'] ?? 'youtube',
    );
  }

  // Two playlists are considered equal if they share the same ID and originating source.
  // This allows Flutter to detect duplicates and optimize list re-renders.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MusicPlaylist &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          source == other.source;

  // Generates a hash code combining the playlist ID and source for set/map lookups.
  @override
  int get hashCode => id.hashCode ^ source.hashCode;
}
