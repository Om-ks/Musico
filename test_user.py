import urllib.request
import json
url = 'https://raw.githubusercontent.com/sigma67/ytmusicapi/master/ytmusicapi/mixins/browsing.py'
response = urllib.request.urlopen(url)
with open('browsing.py', 'w', encoding='utf-8') as f:
    f.write(response.read().decode('utf-8'))
