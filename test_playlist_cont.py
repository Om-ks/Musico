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
        "browseId": "VLPLQwVIlKxHM6qv-o99iX9R85og7IzF9YS_"
    }).encode('utf-8'),
    headers={"Content-Type": "application/json"}
)
res = urllib.request.urlopen(req)
data = json.loads(res.read().decode('utf-8'))

def find_continuations(d):
    if isinstance(d, dict):
        if 'continuations' in d:
            print("Found continuations inside", list(d.keys()))
            print(json.dumps(d['continuations'])[:300])
        for k, v in d.items():
            find_continuations(v)
    elif isinstance(d, list):
        for item in d:
            find_continuations(item)

find_continuations(data)
