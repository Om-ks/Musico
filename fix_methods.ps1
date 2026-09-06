$content = Get-Content -Raw "lib\services\youtube_account_service.dart"

$oldCreate = @"
  Future<String?> createPlaylist(
      Map<String, String> headers, String title) async {
    try {
      final response = await http
          .post(
            Uri.parse('${_base}playlists?part=snippet,status'),
            headers: {
              ...headers,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'snippet': {'title': title},
              'status': {'privacyStatus': 'private'},
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return data['id'];
      }
    } catch (e) {
      debugPrint('YouTube createPlaylist failed: $e');
    }
    return null;
  }
"@

$newCreate = @"
  Future<String?> createPlaylist(
      Map<String, String> headers, String title) async {
    try {
      final requestHeaders = _buildInnerTubeHeaders(headers);
      final body = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240610.01.00',
          }
        },
        'title': title,
        'description': '',
        'privacyStatus': 'PRIVATE'
      };

      final response = await http
          .post(
            Uri.parse('https://music.youtube.com/youtubei/v1/playlist/create?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false'),
            headers: requestHeaders,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['playlistId'];
      }
    } catch (e) {
      debugPrint('YouTube createPlaylist failed: `$e');
    }
    return null;
  }
"@

$content = $content.Replace($oldCreate, $newCreate)

$oldDelete = @"
  Future<bool> deletePlaylist(Map<String, String> headers, String playlistId) async {
    try {
      final response = await http.delete(
        Uri.parse('${_base}playlists?id=$playlistId'),
        headers: headers,
      );
      if (response.statusCode == 204 || response.statusCode == 200) {
        return true;
      } else {
        debugPrint('YouTube deletePlaylist err: ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('YouTube deletePlaylist failed: $e');
      return false;
    }
  }
"@

$newDelete = @"
  Future<bool> deletePlaylist(Map<String, String> headers, String playlistId) async {
    try {
      final requestHeaders = _buildInnerTubeHeaders(headers);
      final body = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240610.01.00',
          }
        },
        'playlistId': playlistId.startsWith('VL') ? playlistId.substring(2) : playlistId,
      };

      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/playlist/delete?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false'),
        headers: requestHeaders,
        body: jsonEncode(body),
      );
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['status'] == 'STATUS_SUCCEEDED';
      }
      return false;
    } catch (e) {
      debugPrint('YouTube deletePlaylist failed: `$e');
      return false;
    }
  }
"@

$content = $content.Replace($oldDelete, $newDelete)

$oldEdit = @"
  Future<bool> editPlaylist(Map<String, String> headers, String id, String newTitle) async {
    try {
      final response = await http.put(
        Uri.parse('${_base}playlists?part=snippet'),
        headers: {
          ...headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'id': id,
          'snippet': {'title': newTitle},
        }),
      );
      return response.statusCode == 200 || response.statusCode == 204;
    } catch (e) {
      debugPrint('YouTube editPlaylist failed: $e');
      return false;
    }
  }
"@

$newEdit = @"
  Future<bool> editPlaylist(Map<String, String> headers, String id, String newTitle) async {
    try {
      final requestHeaders = _buildInnerTubeHeaders(headers);
      final body = {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': '1.20240610.01.00',
          }
        },
        'playlistId': id.startsWith('VL') ? id.substring(2) : id,
        'actions': [
          {
            'action': 'ACTION_SET_PLAYLIST_NAME',
            'playlistName': newTitle
          }
        ]
      };

      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/browse/edit_playlist?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false'),
        headers: requestHeaders,
        body: jsonEncode(body),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['status'] == 'STATUS_SUCCEEDED';
      }
      return false;
    } catch (e) {
      debugPrint('YouTube editPlaylist failed: `$e');
      return false;
    }
  }
"@

$content = $content.Replace($oldEdit, $newEdit)

Set-Content -Value $content -Path "lib\services\youtube_account_service.dart"
