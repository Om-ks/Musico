import urllib.request
import json
req = urllib.request.Request(
    'https://music.youtube.com/youtubei/v1/account/account_menu?key=AIzaSyC1nBR9Gs1m4Hnbp6Ur0qa9Ta1IO9oPras&prettyPrint=false',
    data=json.dumps({
        "context": {
            "client": {
                "clientName": "WEB_REMIX",
                "clientVersion": "1.20240610.01.00",
                "hl": "en",
                "gl": "US",
                "timeZone": "UTC"
            }
        }
    }).encode('utf-8'),
    headers={"Content-Type": "application/json"}
)
try:
    res = urllib.request.urlopen(req)
    data = json.loads(res.read().decode('utf-8'))
    print(list(data.keys()))
except Exception as e:
    print("Error:", e)
