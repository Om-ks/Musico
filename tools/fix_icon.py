#!/usr/bin/env python3
import os, sys, shutil

# attempt to ensure Pillow is available
try:
    from PIL import Image
except Exception:
    try:
        import subprocess
        subprocess.check_call([sys.executable, '-m', 'pip', 'install', '--user', 'pillow'])
        from PIL import Image
    except Exception as e:
        print('ERROR: Unable to install Pillow:', e)
        sys.exit(1)

repo = os.getcwd()
output = os.path.join(repo, 'assets', 'app_icon.png')
wordmark_backup = os.path.join(repo, 'assets', 'app_icon_wordmark_backup.png')
fallback_backup = output + '.bak'
source = wordmark_backup if os.path.exists(wordmark_backup) else fallback_backup

if not os.path.exists(source):
    print('ERROR: no icon source found at', source)
    sys.exit(1)

if os.path.exists(output) and not os.path.exists(fallback_backup):
    shutil.copyfile(output, fallback_backup)

img = Image.open(source).convert('RGBA')

# The original launcher art is portrait and includes the MUSICO wordmark.
# Crop only the circular music badge so Android does not squeeze the text.
top_limit = int(img.height * 0.76)
badge = img.crop((0, 0, img.width, top_limit))

target = 1024
badge_size = int(target * 0.74)
badge.thumbnail((badge_size, badge_size), Image.LANCZOS)

icon = Image.new('RGBA', (target, target), (10, 10, 15, 255))
left = (target - badge.width) // 2
top = (target - badge.height) // 2
icon.paste(badge, (left, top), badge)

icon.save(output, format='PNG', optimize=True)
print('OK: launcher icon saved to', output)
