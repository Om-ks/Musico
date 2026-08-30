with open('lib/main.dart', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace('final user = account.user;', '')
text = text.replace('user?.photoUrl == null', 'account.photoUrl == null')
text = text.replace('user!.photoUrl!', 'account.photoUrl!')
text = text.replace('user?.email ?? ', '')
text = text.replace('onPressed: () => account.signIn(context),', 'onPressed: () { account.signIn(context); },')
text = text.replace('onPressed: account.connectYoutube,', 'onPressed: () { account.connectYoutube(context); },')

with open('lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(text)
