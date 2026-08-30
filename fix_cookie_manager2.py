import re

path = r'C:\Users\sach2\AppData\Local\Pub\Cache\hosted\pub.dev\webview_cookie_manager-2.0.6\android\build.gradle'
with open(path, 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace('compileSdkVersion 28', 'compileSdkVersion 34')

with open(path, 'w', encoding='utf-8') as f:
    f.write(text)
