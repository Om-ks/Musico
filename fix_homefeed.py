with open('lib/screens/home_screen.dart', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace(
    'final data = await ApiService.getRecommendedSections(history);\n        if (mounted) setState(() => _feedData = data);',
    'final sections = await ApiService.getRecommendedSections(history);\n        if (mounted) setState(() => _feedData = HomeFeedData(sections: sections, chips: []));'
)

with open('lib/screens/home_screen.dart', 'w', encoding='utf-8') as f:
    f.write(text)
