import urllib.request
import json
req1 = urllib.request.Request(
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
res1 = urllib.request.urlopen(req1)
data1 = json.loads(res1.read().decode('utf-8'))

def find_continuation(d):
    if isinstance(d, dict):
        if 'musicPlaylistShelfRenderer' in d:
            if 'continuations' in d['musicPlaylistShelfRenderer']:
                return d['musicPlaylistShelfRenderer']['continuations'][0]['nextContinuationData']['continuation']
        for v in d.values():
            res = find_continuation(v)
            if res: return res
    elif isinstance(d, list):
        for item in d:
            res = find_continuation(item)
            if res: return res
    return None

continuation = find_continuation(data1)

req2 = urllib.request.Request(
    f'https://music.youtube.com/youtubei/v1/browse?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false&ctoken={continuation}&continuation={continuation}',
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
res2 = urllib.request.urlopen(req2)
data2 = json.loads(res2.read().decode('utf-8'))
if 'continuationContents' in data2:
    print(list(data2['continuationContents'].keys()))
else:
    print("NO continuationContents. Keys:", list(data2.keys()))
