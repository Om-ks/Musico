import sys
import re

file_path = 'lib/services/youtube_account_service.dart'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

pattern = r"final titleRuns = carousel\['header'\]\?\['musicCarouselShelfBasicHeaderRenderer'\]\?\['title'\]\?\['runs'\] as List\?;\s*final title = titleRuns\?\.map\(\(r\) => r\['text'\]\?\.toString\(\) \?\? ''\)\.join\(''\) \?\? 'Recommended';"

replacement = '''
              final header = carousel['header']?['musicCarouselShelfBasicHeaderRenderer'];
              final titleRuns = header?['title']?['runs'] as List?;
              final straplineRuns = header?['strapline']?['runs'] as List?;
              
              String title = titleRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? 'Recommended';
              final strapline = straplineRuns?.map((r) => r['text']?.toString() ?? '').join('') ?? '';
              
              if (strapline.isNotEmpty) {
                title = strapline + ' ' + title;
              }
'''

content = re.sub(pattern, replacement, content)

with open(file_path, 'w', encoding='utf-8') as f:
    f.write(content)
print('Patched successfully')
