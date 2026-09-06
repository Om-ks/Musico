import urllib.request
import json

context = {
    "context": {
        "client": {
            "clientName": "WEB_REMIX",
            "clientVersion": "1.20240610.01.00",
            "hl": "en",
            "gl": "US",
            "timeZone": "UTC"
        }
    },
    "browseId": "VLLM"
}

req1 = urllib.request.Request(
    'https://music.youtube.com/youtubei/v1/browse?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false',
    data=json.dumps(context).encode('utf-8'),
    headers={"Content-Type": "application/json"}
)
res1 = urllib.request.urlopen(req1)
data1 = json.loads(res1.read().decode('utf-8'))
print(json.dumps(data1)[:500])
