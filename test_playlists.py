import urllib.request
import json
url = 'https://raw.githubusercontent.com/sigma67/ytmusicapi/master/ytmusicapi/mixins/playlists.py'
response = urllib.request.urlopen(url)
with open('playlists.py', 'w', encoding='utf-8') as f:
    f.write(response.read().decode('utf-8'))
