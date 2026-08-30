class MusicPlaylist {
  final String id;
  final String title;
  final String owner;
  final String thumbnailUrl;
  final int itemCount;
  final String source;

  const MusicPlaylist({
    required this.id,
    required this.title,
    required this.owner,
    required this.thumbnailUrl,
    required this.itemCount,
    required this.source,
  });

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

  factory MusicPlaylist.fromMap(Map<String, dynamic> map) {
    return MusicPlaylist(
      id: map['id'] ?? '',
      title: map['title'] ?? 'Unknown Playlist',
      owner: map['owner'] ?? 'Unknown Owner',
      thumbnailUrl: map['thumbnailUrl'] ?? '',
      itemCount: map['itemCount'] ?? 0,
      source: map['source'] ?? 'youtube',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MusicPlaylist &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          source == other.source;

  @override
  int get hashCode => id.hashCode ^ source.hashCode;
}
