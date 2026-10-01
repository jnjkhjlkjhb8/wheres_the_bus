import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no generated proto imports leak outside data/', () {
    final root = Directory('lib');
    final offenders = <String>[];
    final pattern = RegExp(r'''import\s+['"][^'"]*data/generated/[^'"]*\.pb''');
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final normalized = entity.path.replaceAll(r'\', '/');
      if (normalized.startsWith('lib/data/')) continue;
      if (normalized.startsWith('lib/core/grpc/')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) {
          offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Generated proto types must not leave data/. Move decoding into a '
          'repository or decoder and return a domain type.\n'
          '${offenders.join('\n')}',
    );
  });

  test('no repository public method returns a generated proto type', () {
    final protoNames = _generatedProtoClassNames();
    expect(
      protoNames,
      isNotEmpty,
      reason: 'Generated proto stubs missing; run protoc before this test.',
    );

    // A method declaration: an optional `static`, a return-type token, the
    // method name, then `(`. Getters (no parens) and constructors (single
    // token before `(`) do not match, which is intended.
    final decl = RegExp(
      r'''^\s*(?:static\s+)?([\w$][\w$<>,.?\s]*?)\s+([A-Za-z]\w*)\s*\(''',
    );
    const nonMethodNames = <String>{
      'if',
      'for',
      'while',
      'switch',
      'return',
      'catch',
      'assert',
      'await',
      'yield',
      'get',
      'set',
    };

    final offenders = <String>[];
    for (final entity in Directory('lib/data/repositories').listSync()) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trimLeft();
        if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
        final match = decl.firstMatch(lines[i]);
        if (match == null) continue;
        final name = match.group(2)!;
        if (name.startsWith('_') || nonMethodNames.contains(name)) continue;
        final returnType = match.group(1)!;
        final leaked = _identifiers(
          returnType,
        ).where(protoNames.contains).toSet();
        if (leaked.isNotEmpty) {
          offenders.add(
            '${entity.path}:${i + 1}: $name returns $returnType '
            '(proto: ${leaked.join(', ')})',
          );
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Repositories are the data/ boundary: return validated domain '
          'types, never proto. Add a domain model + decoder and return that.\n'
          '${offenders.join('\n')}',
    );
  });
}

/// Class names declared in the generated proto stubs (messages and enums).
Set<String> _generatedProtoClassNames() {
  final dir = Directory('lib/data/generated');
  if (!dir.existsSync()) return const {};
  final classDecl = RegExp(r'^class (\w+) extends ');
  final names = <String>{};
  for (final entity in dir.listSync()) {
    if (entity is! File) continue;
    final path = entity.path;
    if (!path.endsWith('.pb.dart') && !path.endsWith('.pbenum.dart')) continue;
    for (final line in entity.readAsLinesSync()) {
      final m = classDecl.firstMatch(line);
      if (m != null) names.add(m.group(1)!);
    }
  }
  return names;
}

Iterable<String> _identifiers(String type) =>
    RegExp(r'[A-Za-z_$][\w$]*').allMatches(type).map((m) => m.group(0)!);
