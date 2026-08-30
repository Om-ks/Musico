with open('lib/screens/player_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

old_str = \"\"\"            onPressed: () {
              provider.toggleLike(account: context.read<AccountProvider>());
            },
              account: context.read<AccountProvider>(),
            ),
          ),
        ],\"\"\"

new_str = \"\"\"            onPressed: () {
              provider.toggleLike(account: context.read<AccountProvider>());
            },
          ),
        ],\"\"\"

content = content.replace(old_str, new_str)

with open('lib/screens/player_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)
