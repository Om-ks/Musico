import 'dart:io';

void main() {
  final file = File('lib/screens/home_screen.dart');
  var content = file.readAsStringSync();
  
  final oldLogic = '''                  if (section.playlists.isNotEmpty && section.songs.isEmpty)
                    SliverToBoxAdapter(
                      child: _buildPlaylistCards(section.playlists),
                    )
                  else if (section.songs.isNotEmpty)
                    SliverToBoxAdapter(
                      child: section.songs.length > 8 
                          ? _buildGridCards(section.songs)
                          : _buildHorizontalCards(section.songs),
                    ),''';
                    
  final newLogic = '''                  if (section.playlists.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _buildPlaylistCards(section.playlists),
                    ),
                  if (section.songs.isNotEmpty)
                    SliverToBoxAdapter(
                      child: section.songs.length > 8 
                          ? _buildGridCards(section.songs)
                          : _buildHorizontalCards(section.songs),
                    ),''';
                    
  content = content.replaceFirst(oldLogic, newLogic);
  file.writeAsStringSync(content);
}
