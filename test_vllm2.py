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

def find_continuation(d, path=""):
    if isinstance(d, dict):
        for k, v in d.items():
            if k == 'nextContinuationData' and isinstance(v, dict) and 'continuation' in v:
                print("Found at:", path + "." + k)
                return v['continuation']
            r = find_continuation(v, path+"."+k)
            if r: return r
    elif isinstance(d, list):
        for i, item in enumerate(d):
            r = find_continuation(item, path+f"[{i}]")
            if r: return r
    return None

# First count items
def count_items(d):
    if isinstance(d, dict):
        if 'musicResponsiveListItemRenderer' in d:
            return 1
        return sum(count_items(v) for v in d.values())
    elif isinstance(d, list):
        return sum(count_items(item) for item in d)
    return 0

total = count_items(data1)
print("Items on page 1:", total)
cont = find_continuation(data1)
print("First page continuation:", cont[:30] if cont else "NONE")
