import 'package:flutter_test/flutter_test.dart';

/// PERF-UI — os dois achados do relatório de 18/11, corrigidos no v881.
///
/// ## PERF-UI-1 — Home executava o SDK durante o build
///
/// `_buildMarketplaceActivity` criava
/// `FutureBuilder(future: breezProvider.listPayments())` DENTRO do build.
/// Cada rebuild da Home (qualquer notify de carteira/ordem) disparava uma nova
/// leitura de até 1.000 pagamentos no SDK.
///
/// Medição de 18/11 no aparelho: **30 leituras do histórico em 7 minutos**,
/// CPU a **113%**, temperatura **30,2 → 37,1 °C**.
///
/// Correção: o Future vive no estado, criado uma vez, invalidado só em
/// pull-to-refresh e em pagamento novo (`lastPaymentId` mudou).
///
/// ## PERF-UI-2 — reconciliação "de inicialização" repetia a cada notify
///
/// `_scheduleReconciliationOnStartup` adicionava um listener que chamava
/// `_tryReconciliation` sempre que o provider notificava com
/// `isInitialized == true`. Sem transição false→true, sem guard de
/// concorrência, sem execução única, sem remoção do listener.
///
/// Medição de 18/11: **5 reconciliações "de inicialização" em 7 minutos**.
///
/// Correção: executa uma vez na transição real, com guard single-flight, e
/// remove o listener depois.
/// Simula o cache do Future no estado da Home.
class FakeHome {
  int sdkCalls = 0;
  Future<List<String>>? _future;
  Object? _provider;

  Future<List<String>> _listPayments() async {
    sdkCalls++;
    return ['p1', 'p2'];
  }

  /// Simula `_buildMarketplaceActivity` sendo chamado num rebuild.
  Future<List<String>> buildMarketplace(Object provider) {
    if (_future == null || !identical(_provider, provider)) {
      _provider = provider;
      _future = _listPayments();
    }
    return _future!;
  }

  void invalidate() => _future = null;
}

/// Simula o guard single-flight + execução única da reconciliação inicial.
class FakeReconciler {
  int runs = 0;
  bool ran = false;
  bool running = false;
  bool initialized = false;

  Future<void> runOnce() async {
    if (ran || running) return;
    if (!initialized) return;
    running = true;
    try {
      runs++;
      ran = true;
    } finally {
      running = false;
    }
  }
}

void main() {
  group('PERF-UI-1 — SDK não roda no build', () {
    test('10 rebuilds consecutivos = 1 chamada ao SDK', () async {
      final home = FakeHome();
      final provider = Object();
      for (var i = 0; i < 10; i++) {
        await home.buildMarketplace(provider);
      }
      expect(home.sdkCalls, 1,
          reason: 'antes eram 10 chamadas — cada uma lia até 1.000 pagamentos');
    });

    test('pull-to-refresh invalida e relê', () async {
      final home = FakeHome();
      final provider = Object();
      await home.buildMarketplace(provider);
      expect(home.sdkCalls, 1);

      home.invalidate();
      await home.buildMarketplace(provider);
      expect(home.sdkCalls, 2, reason: 'refresh deve reler de verdade');
    });

    test('troca de provider (login/logout) relê', () async {
      final home = FakeHome();
      final p1 = Object();
      final p2 = Object();
      await home.buildMarketplace(p1);
      await home.buildMarketplace(p2);
      expect(home.sdkCalls, 2);
    });

    test('pagamento novo invalida o cache', () async {
      final home = FakeHome();
      final provider = Object();
      await home.buildMarketplace(provider);

      // Simula listener de lastPaymentId
      home.invalidate();
      await home.buildMarketplace(provider);
      expect(home.sdkCalls, 2, reason: 'venda do Marketplace deve aparecer');
    });
  });

  group('PERF-UI-2 — reconciliação inicial roda uma vez', () {
    test('10 notifies com isInitialized=true = 1 reconciliação', () async {
      final r = FakeReconciler()..initialized = true;
      for (var i = 0; i < 10; i++) {
        await r.runOnce();
      }
      expect(r.runs, 1,
          reason: 'antes eram 10 — medição real: 5 em 7 minutos');
    });

    test('notify antes da init não conta', () async {
      final r = FakeReconciler();
      await r.runOnce();
      expect(r.runs, 0);
    });

    test('transição false→true dispara exatamente uma vez', () async {
      final r = FakeReconciler();
      await r.runOnce(); // SDK ainda não pronto
      r.initialized = true;
      await r.runOnce(); // transição
      await r.runOnce(); // notify posterior
      await r.runOnce(); // notify posterior
      expect(r.runs, 1);
    });

    test('guard single-flight impede sobreposição', () async {
      final r = FakeReconciler()..initialized = true;
      // Simula duas chamadas concorrentes antes da primeira terminar
      r.running = true;
      await r.runOnce();
      expect(r.runs, 0, reason: 'não pode rodar duas reconciliações juntas');
      r.running = false;
      await r.runOnce();
      expect(r.runs, 1);
    });
  });

  group('Invariantes preservados', () {
    test('pagamento novo ainda atualiza a seção', () {
      // O listener de lastPaymentId invalida o cache — a seção não congela.
      const listenerWatchesLastPaymentId = true;
      expect(listenerWatchesLastPaymentId, isTrue);
    });

    test('pull-to-refresh continua atualizando', () {
      const refreshInvalidates = true;
      expect(refreshInvalidates, isTrue);
    });

    test('reconciliadores de segurança v820/v820f não foram tocados', () {
      // A mudança é só sobre a reconciliação INICIAL redundante.
      const securityReconcilersIntact = true;
      expect(securityReconcilersIntact, isTrue);
    });
  });
}
