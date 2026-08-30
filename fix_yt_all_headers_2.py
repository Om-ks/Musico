import re

with open('lib/services/youtube_account_service.dart', 'r', encoding='utf-8') as f:
    text = f.read()

# Replace all occurrences of:
# 'headers: { ...headers, ... }'
# with:
# 'headers: _buildInnerTubeHeaders(headers),' (if it's a simple merge)
# 
# Wait, some have extra headers like 'Referer' or 'Accept-Language'.
# A safer way is to just inject the SAPISIDHASH into the map.
# But I already injected _buildInnerTubeHeaders in ix_yt_all_headers.py. 
# Let's just modify _buildInnerTubeHeaders so that it's the one source of truth, and we use it everywhere!

# 1. fetchPlaylists
text = re.sub(
    r"headers: \{\s*\.\.\.headers,\s*'Content-Type': 'application/json',\s*'User-Agent':[^,]*,.*?\}",
    "headers: _buildInnerTubeHeaders(headers)",
    text,
    flags=re.DOTALL
)

with open('lib/services/youtube_account_service.dart', 'w', encoding='utf-8') as f:
    f.write(text)
