import re
with open('lib/screens/home_screen.dart', 'r') as f:
    text = f.read()

text = text.replace('],]', '],')
text = text.replace('),)', '),')

with open('lib/screens/home_screen.dart', 'w') as f:
    f.write(text)

with open('lib/widgets/mini_player.dart', 'r') as f:
    m = f.read()
m = m.replace('\'\\${', '\'${')
m = m.replace('`$', '$')
m = m.replace('\${', '${')
with open('lib/widgets/mini_player.dart', 'w') as f:
    f.write(m)
