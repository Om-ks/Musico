import re

with open('lib/screens/player_screen.dart', 'r', encoding='utf-8') as f:
    content = f.read()

old_str = \"\"\"                              _buildActionButton(Icons.thumb_down_outlined, ''),
                              const SizedBox(width: 16),
                              _buildActionButton(Icons.thumb_up_outlined, ''),
                              const SizedBox(width: 16),\"\"\"

new_str = \"\"\"                              _buildActionButton(Icons.thumb_down_outlined, ''),
                              const SizedBox(width: 16),
                              GestureDetector(
                                onTap: () => provider.toggleLike(account: context.read<AccountProvider>()),
                                child: _buildActionButton(
                                  provider.isLiked ? Icons.thumb_up : Icons.thumb_up_outlined, 
                                  '',
                                  active: provider.isLiked,
                                ),
                              ),
                              const SizedBox(width: 16),\"\"\"

content = content.replace(old_str, new_str)

with open('lib/screens/player_screen.dart', 'w', encoding='utf-8') as f:
    f.write(content)
