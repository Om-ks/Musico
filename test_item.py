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

def find_item_section(d, path=""):
    if isinstance(d, dict):
        if 'itemSectionRenderer' in d:
            print("Found itemSectionRenderer at", path)
        for k, v in d.items():
            find_item_section(v, path + "." + str(k))
    elif isinstance(d, list):
        for i, item in enumerate(d):
            find_item_section(item, path + f"[{i}]")

find_item_section(data)
