String deriveCarIdFromCn1(String cn1) {
  final first = cn1.split('/').first.trim();
  if (first.isEmpty) return '';
  return '1$first';
}
