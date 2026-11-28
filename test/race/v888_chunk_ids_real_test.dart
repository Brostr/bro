import 'package:bro_app/services/nostr_order_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// v888 — teste REAL de `chunkIds` (bloqueador 2 do integrador).
///
/// O integrador apontou que o teste anterior copiava a expressão para dentro
/// do teste e não importava o app. Se alguém revertesse a correção em
/// produção, nenhum teste falharia.
///
/// Agora `chunkIds` é uma função **de produção** (`@visibleForTesting`) e este
/// teste chama ela de verdade.
///
/// ## O bug que ela corrige (v812/v815d)
///
/// ```dart
/// ids.sublist(i, i + 15 > ids.length ? ids.length : i)   // errado
/// ```
///
/// Quando o chunk estava CHEIO, o ternário caía no `else` = `i`, então
/// `sublist(i, i)` = lista vazia. E `'#d': []` é tratado como **SEM FILTRO**
/// por relays nostr-rs (apexcord, bro-relay2) → 50 eventos alheios (~2,7 MB)
/// por relay por passe.
void main() {
  List<String> makeIds(int n) => List.generate(n, (i) => 'order$i');

  group('chunkIds — garantias', () {
    test('lista vazia → nenhum chunk', () {
      expect(NostrOrderService.chunkIds([], 15), isEmpty);
    });

    test('size <= 0 → nenhum chunk (nunca loop infinito)', () {
      expect(NostrOrderService.chunkIds(makeIds(10), 0), isEmpty);
      expect(NostrOrderService.chunkIds(makeIds(10), -1), isEmpty);
    });

    test('1 id → 1 chunk de 1', () {
      final chunks = NostrOrderService.chunkIds(makeIds(1), 15);
      expect(chunks.length, 1);
      expect(chunks[0], ['order0']);
    });

    test('15 ids exatos → 1 chunk cheio', () {
      final chunks = NostrOrderService.chunkIds(makeIds(15), 15);
      expect(chunks.length, 1);
      expect(chunks[0].length, 15);
    });

    test('16 ids → 2 chunks (15 + 1)', () {
      final chunks = NostrOrderService.chunkIds(makeIds(16), 15);
      expect(chunks.length, 2);
      expect(chunks[0].length, 15);
      expect(chunks[1].length, 1);
    });

    test('18 ids → 2 chunks (15 + 3) — cenário real da Carol', () {
      final chunks = NostrOrderService.chunkIds(makeIds(18), 15);
      expect(chunks.length, 2);
      expect(chunks[0].length, 15);
      expect(chunks[1].length, 3);
    });

    test('30 ids → 2 chunks cheios', () {
      final chunks = NostrOrderService.chunkIds(makeIds(30), 15);
      expect(chunks.length, 2);
      expect(chunks.every((c) => c.length == 15), isTrue);
    });

    test('31 ids → 3 chunks (15 + 15 + 1)', () {
      final chunks = NostrOrderService.chunkIds(makeIds(31), 15);
      expect(chunks.length, 3);
      expect(chunks[0].length, 15);
      expect(chunks[1].length, 15);
      expect(chunks[2].length, 1);
    });
  });

  group('chunkIds — invariantes que o bug violava', () {
    test('NENHUM chunk vazio (o bug produzia vazios)', () {
      for (final n in [0, 1, 14, 15, 16, 18, 29, 30, 31, 100]) {
        final chunks = NostrOrderService.chunkIds(makeIds(n), 15);
        expect(chunks.every((c) => c.isNotEmpty), isTrue,
            reason: 'n=$n produziu chunk vazio');
      }
    });

    test('cada chunk tem no máximo `size` elementos', () {
      for (final n in [1, 15, 16, 30, 31, 100]) {
        final chunks = NostrOrderService.chunkIds(makeIds(n), 15);
        expect(chunks.every((c) => c.length <= 15), isTrue,
            reason: 'n=$n produziu chunk > 15');
      }
    });

    test('união dos chunks == lista original (sem perder nem duplicar)', () {
      for (final n in [0, 1, 15, 16, 18, 30, 31, 100]) {
        final ids = makeIds(n);
        final chunks = NostrOrderService.chunkIds(ids, 15);
        final flat = chunks.expand((c) => c).toList();
        expect(flat.length, n, reason: 'n=$n perdeu ou duplicou');
        expect(flat, ids, reason: 'n=$n mudou a ordem');
      }
    });

    test('ordem preservada (importante para debug)', () {
      final ids = makeIds(18);
      final chunks = NostrOrderService.chunkIds(ids, 15);
      expect(chunks[0].first, 'order0');
      expect(chunks[0].last, 'order14');
      expect(chunks[1].first, 'order15');
      expect(chunks[1].last, 'order17');
    });
  });

  group('Cenário real: 18 ordens ativas', () {
    test('antes (bug): só 3 de 18 cobertas', () {
      // Réplica da expressão BUGADA, só para documentar o impacto.
      final ids = makeIds(18);
      var covered = 0;
      for (var i = 0; i < ids.length; i += 15) {
        final end = i + 15 > ids.length ? ids.length : i;
        covered += ids.sublist(i, end).length;
      }
      expect(covered, 3, reason: 'só o último chunk parcial funcionava');
      expect(ids.length - covered, 15, reason: '15 ordens sem busca #d');
    });

    test('depois (chunkIds): 18 de 18 cobertas', () {
      final ids = makeIds(18);
      final chunks = NostrOrderService.chunkIds(ids, 15);
      final covered = chunks.expand((c) => c).length;
      expect(covered, 18);
    });
  });
}
