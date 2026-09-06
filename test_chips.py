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
        "browseId": "FEmusic_home"
    }).encode('utf-8'),
    headers={"Content-Type": "application/json"}
)
res = urllib.request.urlopen(req)
data = json.loads(res.read().decode('utf-8'))

tabs = data.get('contents', {}).get('singleColumnBrowseResultsRenderer', {}).get('tabs', [])
sectionList = tabs[0].get('tabRenderer', {}).get('content', {}).get('sectionListRenderer', {})

chips = sectionList.get('header', {}).get('chipCloudRenderer', {}).get('chips', [])

for chip in chips[:1]:
    first_chip = chip.get('chipCloudChipRenderer', {})
    text = first_chip.get('text', {}).get('runs', [{}])[0].get('text')
    print(json.dumps(first_chip['navigationEndpoint']))
