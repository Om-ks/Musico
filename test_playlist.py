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
        "browseId": "VLPLw-VjHDlEOgs658kAHR_LAaILBXb-sILT"
    }).encode('utf-8'),
    headers={"Content-Type": "application/json"}
)
try:
    res = urllib.request.urlopen(req)
    data = json.loads(res.read().decode('utf-8'))
    print("Fetched playlist")
    
    def find_continuation(node, path=""):
        if isinstance(node, dict):
            for k, v in node.items():
                if k in ('continuationCommand', 'nextContinuationData', 'reloadContinuationData'):
                    print("Found token at:", path + "." + k)
                find_continuation(v, path + "." + k)
        elif isinstance(node, list):
            for i, item in enumerate(node):
                find_continuation(item, path + f"[{i}]")
                
    find_continuation(data)
except Exception as e:
    print(e)
