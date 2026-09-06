import urllib.request
import json
req = urllib.request.Request(
    'https://music.youtube.com/youtubei/v1/browse?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false',
    data=json.dumps({
        "context": {
            "client": {
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20240610.01.00",
                "hl": "en",
                "gl": "US",
                "timeZone": "UTC"
            }
        },
        "browseId": "FEmusic_liked_playlists"
    }).encode('utf-8'),
    headers={"Content-Type": "application/json"}
)
res = urllib.request.urlopen(req)
data = json.loads(res.read().decode('utf-8'))
def find_keys(d, target="items"):
    if isinstance(d, dict):
        if target in d:
            print("Found", target, "inside", list(d.keys()))
        for k, v in d.items():
            find_keys(v, target)
    elif isinstance(d, list):
        for item in d:
            find_keys(item, target)
find_keys(data, "musicTwoRowItemRenderer")
