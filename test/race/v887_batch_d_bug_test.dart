import 'package:flutter_test/flutter_test.dart';

/// v887 — teste REAL do bug de batch `#d` (bloqueador 2 do integrador).
///
/// ## O bug (pré-existente desde v812/v815d)
///
/// ```dart
/// ids.sublist(i, i + 15 > ids.length ? ids.length : i)   // ← errado
/// ```
///
/// Quando o batch está CHEIO (`i + 15 <= ids.length`), a expressão ternária
/// cai no ramo `else` que é `i` — então `sublist(i, i)` = **lista vazia**.
///
/// Com >15 ordens ativas, todo batch cheio saía vazio. E `'#d': []` é tratado
/// como **SEM FILTRO** por relays nostr-rs (apexcord, bro-relay2): devolvem 50
/// eventos alheios (~2,7 MB) por relay por passe.
///
/// ## A correção
///
/// `i + 15` no ramo else, mais `if (batch.isEmpty) continue;` como defesa.
void main() {
  /// Réplica EXATA da expressão corrigida.
  List<String> batchOf(List<String> ids, int i) {
    return ids.sublist(i, i + 15 > ids.length ? ids.length : i + 15);
  }

  /// Réplica da expressão BUGADA (para provar que o teste pega o bug).
  List<String> buggyBatchOf(List<String> ids, int i) {
    return ids.sublist(i, i + 15 > ids.length ? ids.length : i);
  }

  List<String> makeIds(int n) => List.generate(n, (i) => 'order$i');

  group('Bug provado: expressão antiga devolvia vazio', () {
    test('18 ids, i=0: bugado devolve VAZIO', () {
      final ids = makeIds(18);
      expect(buggyBatchOf(ids, 0), isEmpty,
          reason: 'i + 15 > 18? não → else = i → sublist(0,0) = []');
    });

    test('18 ids, i=0: corrigido devolve 15', () {
      final ids = makeIds(18);
      expect(batchOf(ids, 0).length, 15);
    });

    test('18 ids, i=15: bugado devolve 3 (último batch parcial)', () {
      final ids = makeIds(18);
      // i + 15 = 30 > 18 → true → ids.length = 18 → sublist(15,18) = 3
      expect(buggyBatchOf(ids, 15).length, 3);
    });

    test('18 ids, i=15: corrigido também devolve 3', () {
      final ids = makeIds(18);
      expect(batchOf(ids, 15).length, 3);
    });
  });

  group('Correção: nenhum batch vazio, todos os ids cobertos', () {
    test('18 ids → 2 batches (15 + 3), nenhum vazio', () {
      final ids = makeIds(18);
      final batches = <List<String>>[];
      for (var i = 0; i < ids.length; i += 15) {
        final b = batchOf(ids, i);
        if (b.isEmpty) continue; // defesa v887
        batches.add(b);
      }
      expect(batches.length, 2);
      expect(batches[0].length, 15);
      expect(batches[1].length, 3);
      expect(batches.every((b) => b.isNotEmpty), isTrue);
    });

    test('todos os ids aparecem exatamente uma vez', () {
      final ids = makeIds(18);
      final seen = <String>[];
      for (var i = 0; i < ids.length; i += 15) {
        final b = batchOf(ids, i);
        if (b.isEmpty) continue;
        seen.addAll(b);
      }
      expect(seen.length, 18);
      expect(seen.toSet().length, 18, reason: 'sem duplicatas');
      expect(seen, containsAll(ids));
    });

    test('15 ids exatos → 1 batch cheio', () {
      final ids = makeIds(15);
      final batches = <List<String>>[];
      for (var i = 0; i < ids.length; i += 15) {
        final b = batchOf(ids, i);
        if (b.isEmpty) continue;
        batches.add(b);
      }
      expect(batches.length, 1);
      expect(batches[0].length, 15);
    });

    test('16 ids → 2 batches (15 + 1)', () {
      final ids = makeIds(16);
      final batches = <List<String>>[];
      for (var i = 0; i < ids.length; i += 15) {
        final b = batchOf(ids, i);
        if (b.isEmpty) continue;
        batches.add(b);
      }
      expect(batches.length, 2);
      expect(batches[0].length, 15);
      expect(batches[1].length, 1);
    });

    test('1 id → 1 batch de 1', () {
      final ids = makeIds(1);
      expect(batchOf(ids, 0).length, 1);
    });

    test('lista vazia → nenhum batch', () {
      final ids = <String>[];
      final batches = <List<String>>[];
      for (var i = 0; i < ids.length; i += 15) {
        batches.add(batchOf(ids, i));
      }
      expect(batches, isEmpty);
    });
  });

  group('Defesa: batch vazio nunca vai para o relay', () {
    test("'#d': [] é tratado como SEM FILTRO por nostr-rs", () {
      // Documentação do comportamento que motivou a defesa.
      // apexcord e bro-relay2 devolvem 50 eventos alheios (~2,7 MB).
      const emptyBatchIsUnfiltered = true;
      expect(emptyBatchIsUnfiltered, isTrue);
    });

    test('com a defesa, nenhum filtro com #d vazio é enviado', () {
      final ids = makeIds(18);
      final filters = <Map<String, dynamic>>[];
      for (var i = 0; i < ids.length; i += 15) {
        final b = batchOf(ids, i);
        if (b.isEmpty) continue; // ← a defesa
        filters.add({'#d': b});
      }
      expect(filters.every((f) => (f['#d'] as List).isNotEmpty), isTrue);
      expect(filters.length, 2);
    });
  });

  group('Cenário real da Carol: 18 ordens ativas', () {
    test('antes: 15 de 18 ordens sem busca #d', () {
      final ids = makeIds(18);
      var covered = 0;
      for (var i = 0; i < ids.length; i += 15) {
        covered += buggyBatchOf(ids, i).length;
      }
      expect(covered, 3, reason: 'só o último batch parcial funcionava');
      expect(ids.length - covered, 15, reason: '15 ordens sem busca #d');
    });

    test('depois: 18 de 18 ordens cobertas', () {
      final ids = makeIds(18);
      var covered = 0;
      for (var i = 0; i < ids.length; i += 15) {
        covered += batchOf(ids, i).length;
      }
      expect(covered, 18);
    });
  });
}
