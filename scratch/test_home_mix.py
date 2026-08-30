import json
from ytmusicapi import YTMusic

yt = YTMusic()
home = yt.get_home(limit=3)
for section in home:
    print(f"Section: {section.get('title')}")
    for item in section.get('contents', []):
        if 'My Mix' in item.get('title', '') or 'Mix' in item.get('title', ''):
            print(json.dumps(item))
