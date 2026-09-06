void main() {
  final token = 'QQ%3D%3D';
  final uri = Uri.parse('https://example.com').replace(queryParameters: {
    'ctoken': Uri.decodeComponent(token)
  });
  print(uri.toString());
}
