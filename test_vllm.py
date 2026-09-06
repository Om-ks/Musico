import json
import urllib.request
import urllib.parse
from unittest.mock import patch

def test_pagination():
    # We will just print the exact URL and body ytmusicapi uses for continuation
    # We don't need valid cookies to see what the library constructs.
    import ytmusicapi
    yt = ytmusicapi.YTMusic()
    # It sends a POST to browse
    # Let's see what endpoints it uses
    print("Test ready")
