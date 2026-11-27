import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import 'lnaddress_service.dart';
import 'coordinator_service.dart';
import '../providers/breez_provider_export.dart';

/// v857: resultado do split da taxa da plataforma.
///
/// Regra comercial (Carol, 26/11): coordinator fica com 80% do que recebe,
/// fundação com 20%. Sem coordinator escolhido, 100% vai para a plataforma.
class FeeSplit {
  /// Endereço que recebe a maior fatia (coordinator, ou plataforma se Automático).
  final String primaryAddress;
  final int primarySats;

  /// Endereço da fundação. Vazio quando não há split.
  final String foundationAddress;
  final int foundationSats;

  /// Nome do coordinator (para log/recibo). Vazio quando Automático.
  final String coordinatorName;

  const FeeSplit({
    required this.primaryAddress,
    required this.primarySats,
    required this.foundationAddress,
    required this.foundationSats,
    this.coordinatorName = '',
  });

  bool get hasSplit => foundationSats > 0 && foundationAddress.isNotEmpty;
  int get totalSats => primarySats + foundationSats;
}

/// Serviço para rastrear taxas da plataforma
///
/// MODO ATUAL: TRACKING ONLY
/// - Taxas vão 100% para provedores
/// - Este serviço apenas REGISTRA as taxas para análise futura
/// - Quando tivermos servidor próprio ou Breez Spark permitir split,
///   ativaremos a coleta automática via [enableAutoCollection]
///
/// MODO FUTURO: AUTO COLLECTION (quando disponível)
/// - Pagamentos passam pela carteira master (PlatformWalletService)
/// - Split automático: 98% provedor / 2% plataforma
class PlatformFeeService {
  static const String _feeRecordsKey = 'platform_fee_records';
  static const String _totalCollectedKey = 'platform_total_collected';
  static const String _autoCollectionKey = 'platform_auto_collection_enabled';
  static const String _paidOrderIdsKey = 'platform_fee_paid_order_ids';
  static const String _feePaymentHashesKey = 'platform_fee_payment_hashes';

  /// v876: fila persistente de fatias da fundação que falharam.
  ///
  /// Quando o pagamento principal (coordinator) passa mas a fatia de 20% da
  /// fundação falha, o dinheiro fica órfão — antes só logava. Agora a
  /// pendência é persistida e reprocessada no próximo boot/reconciliação.
  /// Formato: [{orderId, address, sats, attempts, lastError, createdAt}]
  static const String _pendingFoundationKey = 'platform_fee_pending_foundation';

  /// Taxa da plataforma — centralizada em AppConfig
  static const double platformFeePercent = AppConfig.platformFeePercent;

  // ── Anti re-pagamento (definitivo) ───────────────────────────────────
  // O registro local _paidOrderIds se PERDE quando o app é reinstalado. A
  // descrição "Bro Platform Fee" NÃO chega ao histórico do Spark (o comentário
  // LNURL vai para o servidor do destinatário, não vira description do payment).
  // Então o identificador confiável é o paymentHash, que o Spark guarda.
  // Estratégia: ao pagar, salvamos o paymentHash da taxa na ORDEM (via callback),
  // que vive no Nostr e sobrevive à reinstalação. Antes de re-pagar, checamos se
  // a ordem já tem esse hash E se ele consta no histórico da carteira.
  static Future<List<dynamic>> Function()? _walletHistoryFetcher;

  // Callback para persistir o paymentHash da taxa na ordem (registrado pelo
  // OrderProvider, que tem acesso à ordem e republica no Nostr).
  static Future<void> Function(String orderId, String paymentHash)?
      _onFeePaidPersist;

  /// Registra a função que busca o histórico de pagamentos da carteira.
  static void setWalletHistoryFetcher(
      Future<List<dynamic>> Function() fetcher) {
    _walletHistoryFetcher = fetcher;
    broLog(
        '💼 PlatformFeeService: wallet-history fetcher registrado (anti re-pagamento ativo)');
  }

  /// Registra o callback que persiste o paymentHash da taxa na ordem (Nostr).
  static void setOnFeePaidPersist(
      Future<void> Function(String orderId, String paymentHash) cb) {
    _onFeePaidPersist = cb;
  }

  /// Indica se o acesso ao histórico da carteira já foi registrado (carteira pronta).
  static bool get hasWalletHistoryFetcher => _walletHistoryFetcher != null;

  /// Verifica se um paymentHash consta como pago no histórico REAL da carteira.
  static Future<bool> _hashConfirmedInWallet(String paymentHash) async {
    if (_walletHistoryFetcher == null || paymentHash.isEmpty) return false;
    try {
      final payments = await _walletHistoryFetcher!();
      for (final p in payments) {
        final hash = (p is Map ? (p['paymentHash'] ?? '') : '').toString();
        final type = (p is Map ? (p['type'] ?? p['direction'] ?? '') : '')
            .toString()
            .toLowerCase();
        final isSent = type == 'sent' ||
            type.contains('send') ||
            type.contains('enviado') ||
            type.contains('outgoing');
        final status =
            (p is Map ? (p['status'] ?? '') : '').toString().toLowerCase();
        final isCompleted = status == 'complete' ||
            status == 'completed' ||
            status == 'paymentstatus.completed';
        if (isSent && isCompleted && hash == paymentHash) return true;
      }
      return false;
    } catch (e) {
      broLog('⚠️ _hashConfirmedInWallet: $e');
      return false;
    }
  }

  /// v747: marca a ordem como taxa-paga LOCALMENTE (quando a carteira provou
  /// que o valor saiu mas a ordem não tinha hash gravado).
  static Future<void> markFeePaidLocal(String orderId) async {
    _paidOrderIds.add(orderId);
    await _savePaidOrderIds();
  }

  /// v747: procura no histórico REAL da carteira um ENVIO do valor exato da
  /// taxa dentro da janela [referência − 2h, + 48h]. Usado pelo FeeReconcile
  /// para ordens da era-hash que ficaram sem feePaymentHash (a taxa FALHOU na
  /// conclusão — caso real 07/11: eb547393/c705cc55, ~768/~393 sats órfãos).
  /// A descrição LNURL não chega ao histórico, então a prova é valor exato +
  /// janela. Dúvida (sem timestamp, fetch falhou) → false → NÃO paga.
  static Future<bool> feeFoundInWallet(
      {required int feeSats, required DateTime reference}) async {
    if (_walletHistoryFetcher == null || feeSats <= 0) return false;
    try {
      final payments = await _walletHistoryFetcher!();
      final refMs = reference.millisecondsSinceEpoch;
      for (final p in payments) {
        if (p is! Map) continue;
        final dir =
            (p['direction'] ?? p['type'] ?? '').toString().toUpperCase();
        final isSent = dir.contains('ENVIADO') ||
            dir.contains('SEND') ||
            dir.contains('OUTGOING');
        if (!isSent) continue;
        final rawAmt = p['amount'] ?? p['amountSats'];
        final amt =
            rawAmt is num ? rawAmt.toInt() : int.tryParse('$rawAmt') ?? 0;
        if (amt != feeSats) continue;
        final rawTs = p['timestamp'];
        var ts = rawTs is num ? rawTs.toInt() : int.tryParse('$rawTs') ?? 0;
        if (ts <= 0) continue;
        if (ts > 9999999999) ts = ts ~/ 1000; // ms → s
        final payMs = ts * 1000;
        if (payMs >= refMs - 2 * 3600 * 1000 &&
            payMs <= refMs + 48 * 3600 * 1000) {
          broLog(
              '💼 feeFoundInWallet: envio de $feeSats sats encontrado na janela da ordem');
          return true;
        }
      }
      return false;
    } catch (e) {
      broLog('⚠️ feeFoundInWallet: $e');
      return false;
    }
  }

  /// Chamado pelo OrderProvider: verifica se a taxa da ordem já foi paga,
  /// usando o paymentHash salvo na ordem (se houver) confirmado na carteira.
  static Future<bool> isFeePaidVerified(
      String orderId, String? orderFeeHash) async {
    if (_paidOrderIds.contains(orderId)) return true;
    if (orderFeeHash != null && orderFeeHash.isNotEmpty) {
      if (await _hashConfirmedInWallet(orderFeeHash)) {
        _paidOrderIds.add(orderId);
        await _savePaidOrderIds();
        return true;
      }
    }
    return false;
  }

  /// v857: paga a fatia da FUNDAÇÃO (20% da taxa quando há coordinator).
  ///
  /// Chamado DEPOIS do pagamento principal ter sucesso. Falha aqui não
  /// invalida o pagamento — o coordinator já recebeu. Só loga e retorna false;
  /// a fundação pode ser reconciliada pelo histórico da carteira.
  static Future<bool> _payFoundationShare(FeeSplit split, String orderId) async {
    if (!split.hasSplit) return true;
    if (_payInvoiceCallback == null) return false;
    try {
      broLog('💼 [Fundação] Enviando ${split.foundationSats} sats para ${split.foundationAddress}');
      final ln = LnAddressService();
      final inv = await ln.getInvoice(
        lnAddress: split.foundationAddress,
        amountSats: split.foundationSats,
        comment: 'Bro Foundation Fee - ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}',
      );
      final invoice = inv['invoice'] as String?;
      if (inv['success'] != true || invoice == null || invoice.isEmpty) {
        broLog('⚠️ [Fundação] Falha ao obter invoice: ${inv['error'] ?? 'unknown'}');
        await _queuePendingFoundation(split, orderId,
            error: 'invoice: ${inv['error'] ?? 'unknown'}');
        return false;
      }
      final pay = await _payInvoiceCallback!(invoice);
      final ok = pay != null && pay['success'] == true;
      if (ok) {
        broLog('✅ [Fundação] ${split.foundationSats} sats pagos');
        await _removePendingFoundation(orderId);
      } else {
        broLog('⚠️ [Fundação] pagamento falhou: $pay');
        await _queuePendingFoundation(split, orderId,
            error: 'pay: ${pay?['error'] ?? 'unknown'}');
      }
      return ok;
    } catch (e) {
      broLog('⚠️ [Fundação] erro: $e');
      await _queuePendingFoundation(split, orderId, error: e.toString());
      return false;
    }
  }

  /// v876: persiste a fatia da fundação que falhou, para retry posterior.
  ///
  /// Sem isso, uma falha de rede no momento do split deixava os 20% órfãos
  /// para sempre — só um log registrava. A fila sobrevive à reinstalação.
  static Future<void> _queuePendingFoundation(
    FeeSplit split,
    String orderId, {
    required String error,
  }) async {
    if (!split.hasSplit) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingFoundationKey) ?? '[]';
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      // Idempotente por orderId: atualiza a tentativa em vez de duplicar.
      final idx = list.indexWhere((e) => e['orderId'] == orderId);
      final entry = {
        'orderId': orderId,
        'address': split.foundationAddress,
        'sats': split.foundationSats,
        'attempts': idx >= 0 ? ((list[idx]['attempts'] as int?) ?? 0) + 1 : 1,
        'lastError': error,
        'createdAt': idx >= 0
            ? list[idx]['createdAt']
            : DateTime.now().toIso8601String(),
      };
      if (idx >= 0) {
        list[idx] = entry;
      } else {
        list.add(entry);
      }
      await prefs.setString(_pendingFoundationKey, jsonEncode(list));
      broLog('📥 [Fundação] pendência registrada para ${orderId.length > 8 ? orderId.substring(0, 8) : orderId} '
          '(${split.foundationSats} sats, tentativa ${entry['attempts']})');
    } catch (e) {
      broLog('⚠️ [Fundação] falha ao persistir pendência: $e');
    }
  }

  static Future<void> _removePendingFoundation(String orderId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingFoundationKey) ?? '[]';
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      final before = list.length;
      list.removeWhere((e) => e['orderId'] == orderId);
      if (list.length != before) {
        await prefs.setString(_pendingFoundationKey, jsonEncode(list));
      }
    } catch (_) {}
  }

  /// v876: reprocessa as fatias da fundação que falharam.
  ///
  /// Chamado no boot (após a carteira estar pronta) e pela reconciliação.
  /// Limite de 5 tentativas por entrada para não virar loop infinito com
  /// endereço inválido.
  static Future<int> retryPendingFoundationShares() async {
    if (_payInvoiceCallback == null) return 0;
    int paid = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingFoundationKey) ?? '[]';
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      if (list.isEmpty) return 0;
      broLog('🔄 [Fundação] ${list.length} pendência(s) para reprocessar');
      for (final entry in List<Map<String, dynamic>>.from(list)) {
        final orderId = entry['orderId']?.toString() ?? '';
        final address = entry['address']?.toString() ?? '';
        final sats = (entry['sats'] as num?)?.toInt() ?? 0;
        final attempts = (entry['attempts'] as num?)?.toInt() ?? 0;
        if (orderId.isEmpty || address.isEmpty || sats <= 0) {
          await _removePendingFoundation(orderId);
          continue;
        }
        if (attempts >= 5) {
          broLog('⛔ [Fundação] ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}: '
              '5 tentativas — desistindo (verificar endereço $address)');
          continue;
        }
        final split = FeeSplit(
          primaryAddress: '',
          primarySats: 0,
          foundationAddress: address,
          foundationSats: sats,
        );
        if (await _payFoundationShare(split, orderId)) paid++;
      }
    } catch (e) {
      broLog('⚠️ [Fundação] erro no retry: $e');
    }
    return paid;
  }

  /// ETAPA 2 (roteamento de taxa p/ coordinator): resolve para qual endereço
  /// Lightning a taxa vai.
  /// - Se o usuário escolheu um coordinator específico (não "Automático") e ele
  ///   tem endereço Lightning válido, a taxa vai para ELE.
  /// - Senão (Automático), usa o endereço fixo atual (Bro original) — mesmo
  ///   comportamento de sempre.
  ///
  /// v857: quando há coordinator, a taxa é DIVIDIDA — 80% para o coordinator e
  /// 20% para a fundação (decisão da Carol, 26/11). Ver [resolveFeeSplit].
  static Future<String> _resolveFeeDestination() async {
    final split = await resolveFeeSplit();
    return split.primaryAddress;
  }

  /// v857: resolve o split da taxa da plataforma.
  ///
  /// Regra comercial (Carol, 26/11): o coordinator fica com **80%** de tudo o
  /// que recebe; **20%** vai para a fundação (desenvolvimento do código).
  ///
  /// Sem coordinator escolhido (Automático), 100% vai para o endereço da
  /// plataforma — comportamento idêntico ao anterior.
  ///
  /// Retorna um [FeeSplit] com os dois destinos e os valores em sats. Quando
  /// `foundationSats == 0` (sem coordinator, ou taxa de 1 sat), só há um envio.
  static Future<FeeSplit> resolveFeeSplit({int totalFeeSats = 0}) async {
    try {
      final svc = CoordinatorService();
      await svc.loadSelection();
      if (!svc.isAutomatic) {
        // Tenta o cache (rápido). Se estiver vazio (ex.: usuário escolheu mas a
        // tela fechou antes de gravar o cache), busca da rede para não cair no
        // padrão por um detalhe de timing.
        var cards = await svc.loadCachedCards();
        var card = svc.selectedCard(cards);
        if (card == null) {
          cards = await svc.fetchCoordinatorCards();
          card = svc.selectedCard(cards);
        }
        if (card != null && card.lnAddress.isNotEmpty) {
          // v876 [SEGURANÇA — anti self-dealing]: a fatia da fundação vai
          // SEMPRE para o endereço da plataforma, NUNCA para a tag
          // `foundation` do cartão.
          //
          // O cartão é um evento Nostr público (kind 30082) que qualquer um
          // publica. Antes, um coordinator malicioso anunciava `ln`=ele e
          // `foundation`=ele e capturava 100% da taxa — os 20% da fundação
          // eram inexigíveis. A tag continua no cartão como informação, mas
          // não decide o destino do dinheiro.
          final foundationAddr = AppConfig.platformLightningAddress;
          if (card.foundationLnAddress.isNotEmpty &&
              card.foundationLnAddress != foundationAddr) {
            broLog('🛡️ v876: cartão ${card.name} anuncia fundação '
                '${card.foundationLnAddress} — IGNORADO (destino fixo: '
                '$foundationAddr)');
          }

          // Arredonda a fatia da fundação para baixo e garante que o
          // coordinator nunca fique com menos que o combinado. Com taxa de
          // 1 sat, a fundação fica com 0 e o coordinator com 1 (não dá para
          // dividir 1 sat; cobrar 2 seria mudar o preço).
          final foundationSats =
              (totalFeeSats * CoordinatorCard.foundationShare).floor();
          final coordinatorSats = totalFeeSats - foundationSats;

          broLog('💼 Taxa roteada: ${card.name} (${card.lnAddress}) '
              '$coordinatorSats sats + fundação ($foundationAddr) $foundationSats sats');

          return FeeSplit(
            primaryAddress: card.lnAddress,
            primarySats: coordinatorSats,
            foundationAddress: foundationAddr,
            foundationSats: foundationSats,
            coordinatorName: card.name,
          );
        }
      }
    } catch (e) {
      broLog('⚠️ resolveFeeSplit: fallback p/ padrão ($e)');
    }
    return FeeSplit(
      primaryAddress: AppConfig.platformLightningAddress,
      primarySats: totalFeeSats,
      foundationAddress: '',
      foundationSats: 0,
    );
  }

  /// Inicializa o serviço carregando ordens já pagas do storage
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final paidIds = prefs.getStringList(_paidOrderIdsKey) ?? [];
    _paidOrderIds.clear();
    _paidOrderIds.addAll(paidIds);
    final hashes = prefs.getStringList(_feePaymentHashesKey) ?? [];
    _feePaymentHashes.clear();
    _feePaymentHashes.addAll(hashes);
    broLog(
        '💼 PlatformFeeService inicializado com ${_paidOrderIds.length} ordens já pagas, ${_feePaymentHashes.length} hashes');

    // MIGRAÇÃO ÚNICA (remover depois de rodar 1x): marca as 3 ordens de teste que
    // foram re-pagas durante o debug do FeeReconcile, para o teste da correção
    // começar limpo SEM re-pagar. Essas ordens já tiveram a taxa paga várias
    // vezes; não podem ser pagas de novo. Roda uma vez (guardada por flag).
    const migrationFlag = 'fee_reconcile_migration_20260824_done';
    final alreadyMigrated = prefs.getBool(migrationFlag) ?? false;
    if (!alreadyMigrated) {
      const legacyOrders = [
        '7553fb25-29f8-4cd4-ae1d-5b49e7bdef99',
        'b620259f',
        '9a656378-1366-49a4-abdd-4b6ba04e297a',
      ];
      for (final id in legacyOrders) {
        _paidOrderIds.add(id);
      }
      await _savePaidOrderIds();
      await prefs.setBool(migrationFlag, true);
      broLog(
          '💼 [migração] ordens de teste marcadas como pagas (não re-pagar): ${legacyOrders.length}');
    }
  }

  /// Verifica se uma ordem é uma das ordens de teste legadas (por prefixo).
  /// Usado no filtro do FeeReconcile para pular mesmo se o ID tiver variação.
  static bool isLegacyTestOrder(String orderId) {
    return orderId.startsWith('7553fb25') ||
        orderId.startsWith('b620259f') ||
        orderId.startsWith('9a656378');
  }

  /// Salva o registro de ordens pagas no storage
  static Future<void> _savePaidOrderIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_paidOrderIdsKey, _paidOrderIds.toList());
  }

  /// Verifica se a coleta automática está habilitada
  /// DESABILITADO até termos infraestrutura própria
  static Future<bool> isAutoCollectionEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoCollectionKey) ?? false;
  }

  /// Habilita/desabilita coleta automática
  /// USE APENAS quando tivermos servidor próprio ou Breez permitir
  static Future<void> setAutoCollection(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoCollectionKey, enabled);
  }

  /// Registra uma taxa de transação (TRACKING ONLY)
  /// Chamado quando um pagamento é confirmado
  /// A taxa é registrada mas NÃO cobrada do provedor
  ///
  /// v856: IDEMPOTENTE por orderId. Antes cada chamada fazia `records.add()`
  /// sem checar — e há vários call sites que chamam sem guarda
  /// (payment_screen, lightning_payment_screen, escrow_split_service,
  /// order_status_screen). A mesma ordem podia gerar 2-3 registros e inflar
  /// "Total Histórico"/"Taxas Pendentes" no admin. Agora o primeiro registro
  /// vence e os seguintes são ignorados.
  static Future<void> recordFee({
    required String orderId,
    required double transactionBrl,
    required int transactionSats,
    required String providerPubkey,
    required String clientPubkey,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    // Carregar registros existentes
    final existingJson = prefs.getString(_feeRecordsKey);
    List<Map<String, dynamic>> records = [];
    if (existingJson != null) {
      records = List<Map<String, dynamic>>.from(jsonDecode(existingJson));
    }

    if (orderId.isNotEmpty && records.any((r) => r['orderId'] == orderId)) {
      broLog('💼 Taxa da ordem ${orderId.length > 8 ? orderId.substring(0, 8) : orderId} já registrada — ignorando duplicata');
      return;
    }

    // Calcular taxa
    final feeBrl = transactionBrl * platformFeePercent;
    final feeSats = (transactionSats * platformFeePercent).round();

    // Criar registro
    final record = {
      'orderId': orderId,
      'timestamp': DateTime.now().toIso8601String(),
      'transactionBrl': transactionBrl,
      'transactionSats': transactionSats,
      'feeBrl': feeBrl,
      'feeSats': feeSats,
      'providerPubkey': providerPubkey,
      'clientPubkey': clientPubkey,
      'collected': false, // Marca se a taxa foi efetivamente transferida
    };

    // Adicionar novo registro
    records.add(record);

    // Salvar
    await prefs.setString(_feeRecordsKey, jsonEncode(records));
  }

  /// Obtém todos os registros de taxas
  static Future<List<Map<String, dynamic>>> getAllFeeRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_feeRecordsKey);
    if (json == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(json));
  }

  /// Obtém taxas pendentes (não coletadas)
  static Future<List<Map<String, dynamic>>> getPendingFees() async {
    final records = await getAllFeeRecords();
    return records.where((r) => r['collected'] != true).toList();
  }

  /// Calcula total de taxas pendentes
  static Future<Map<String, dynamic>> getPendingTotals() async {
    final pending = await getPendingFees();

    double totalBrl = 0;
    int totalSats = 0;

    for (final record in pending) {
      totalBrl += (record['feeBrl'] as num?)?.toDouble() ?? 0;
      totalSats += (record['feeSats'] as num?)?.toInt() ?? 0;
    }

    return {
      'totalBrl': totalBrl,
      'totalSats': totalSats,
      'count': pending.length,
      'records': pending,
    };
  }

  /// Calcula total histórico (todas as taxas)
  static Future<Map<String, dynamic>> getHistoricalTotals() async {
    final records = await getAllFeeRecords();

    double totalBrl = 0;
    int totalSats = 0;
    double collectedBrl = 0;
    int collectedSats = 0;

    for (final record in records) {
      final feeBrl = (record['feeBrl'] as num?)?.toDouble() ?? 0;
      final feeSats = (record['feeSats'] as num?)?.toInt() ?? 0;

      totalBrl += feeBrl;
      totalSats += feeSats;

      if (record['collected'] == true) {
        collectedBrl += feeBrl;
        collectedSats += feeSats;
      }
    }

    return {
      'totalBrl': totalBrl,
      'totalSats': totalSats,
      'collectedBrl': collectedBrl,
      'collectedSats': collectedSats,
      'pendingBrl': totalBrl - collectedBrl,
      'pendingSats': totalSats - collectedSats,
      'totalTransactions': records.length,
    };
  }

  /// Marca taxas como coletadas
  static Future<void> markAsCollected(List<String> orderIds) async {
    final prefs = await SharedPreferences.getInstance();
    final records = await getAllFeeRecords();

    for (var record in records) {
      if (orderIds.contains(record['orderId'])) {
        record['collected'] = true;
        record['collectedAt'] = DateTime.now().toIso8601String();
      }
    }

    await prefs.setString(_feeRecordsKey, jsonEncode(records));
  }

  /// Marca todas as taxas pendentes como coletadas
  static Future<int> markAllAsCollected() async {
    final pending = await getPendingFees();
    final orderIds = pending.map((r) => r['orderId'] as String).toList();
    await markAsCollected(orderIds);
    return orderIds.length;
  }

  /// Limpa todos os registros (use com cuidado!)
  static Future<void> clearAllRecords() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_feeRecordsKey);
    await prefs.remove(_totalCollectedKey);
  }

  /// Exporta registros para JSON (backup)
  static Future<String> exportToJson() async {
    final records = await getAllFeeRecords();
    final totals = await getHistoricalTotals();

    return jsonEncode({
      'exportDate': DateTime.now().toIso8601String(),
      'totals': totals,
      'records': records,
    });
  }

  // ========== ENVIO REAL DA TAXA ==========

  // Callback para efetuar o pagamento (será injetado pelo LightningProvider)
  static Future<Map<String, dynamic>?> Function(String invoice)?
      _payInvoiceCallback;
  static String _currentBackend = 'unknown';

  // IMPORTANTE: Registro de ordens que já tiveram a taxa paga para evitar duplicação
  static final Set<String> _paidOrderIds = {};
  static final Set<String> _feePaymentHashes = {};

  /// Configura o callback de pagamento (chamar na inicialização do app)
  static void setPaymentCallback(
    Future<Map<String, dynamic>?> Function(String invoice) callback,
    String backend,
  ) {
    _payInvoiceCallback = callback;
    _currentBackend = backend;
    broLog('💼 PlatformFeeService configurado com backend: $backend');
  }

  /// Verifica se a taxa já foi paga para uma ordem específica
  static bool isFeePaid(String orderId) {
    return _paidOrderIds.contains(orderId);
  }

  /// Retorna os payment hashes de taxas da plataforma (para filtrar no histórico)
  static Set<String> get feePaymentHashes =>
      Set.unmodifiable(_feePaymentHashes);

  /// Registra um payment hash de taxa para que seja ocultado do histórico da carteira.
  /// Usado por taxas internas (ex.: taxa BRIX de 0,5%) que devem ser invisíveis ao usuário.
  static Future<void> registerFeePaymentHash(String hash) async {
    if (hash.isEmpty) return;
    await _saveFeePaymentHash(hash);
  }

  /// Salva um payment hash de taxa no storage
  static Future<void> _saveFeePaymentHash(String hash) async {
    _feePaymentHashes.add(hash);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_feePaymentHashesKey, _feePaymentHashes.toList());
  }

  /// Limpa o registro de ordens pagas (usar apenas em casos especiais)
  static Future<void> clearPaidOrders() async {
    _paidOrderIds.clear();
    await _savePaidOrderIds();
    broLog('💼 Registro de taxas pagas limpo');
  }

  /// Registra uma ordem como tendo taxa paga (e persiste no storage)
  static Future<void> _markOrderAsPaid(String orderId) async {
    _paidOrderIds.add(orderId);
    await _savePaidOrderIds();
  }

  static Future<bool> isFeePaymentConfirmed(String paymentHash) {
    return _hashConfirmedInWallet(paymentHash);
  }

  /// Envia a taxa da plataforma para o Lightning Address configurado
  /// Retorna true se o pagamento foi bem sucedido OU se já foi pago anteriormente
  static Future<bool> sendPlatformFee({
    required String orderId,
    required int totalSats,
    String?
        knownFeeHash, // paymentHash da taxa salvo na ordem (se já paga antes)
    double? feePercentOverride,
    Future<void> Function(String paymentHash)? onPaid,
    Future<void> Function(String invoice, String paymentHash)? onAttempt,
    int maxNetworkFeeSats = 0,
    @visibleForTesting
    Future<bool> Function(String paymentHash)? hashConfirmedOverride,
  }) async {
    // VERIFICAÇÃO CRÍTICA: Evitar pagamento duplicado
    if (_paidOrderIds.contains(orderId)) {
      if (knownFeeHash != null && knownFeeHash.isNotEmpty) {
        final confirmed = hashConfirmedOverride != null
            ? await hashConfirmedOverride(knownFeeHash)
            : await _hashConfirmedInWallet(knownFeeHash);
        if (confirmed) return true;
        broLog(
            '🛡️ Taxa da ordem ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}: tentativa anterior não confirmada — NÃO repetir');
        return false;
      }
      broLog(
          '💼 Taxa já foi paga para ordem ${orderId.length > 8 ? orderId.substring(0, 8) : orderId} - ignorando');
      return true;
    }

    // ANTI RE-PAGAMENTO (definitivo): se a ordem já tem um paymentHash de taxa
    // salvo (persistido no Nostr, sobrevive à reinstalação) E ele consta no
    // histórico real da carteira, a taxa JÁ foi paga — re-marca e NÃO re-paga.
    if (knownFeeHash != null && knownFeeHash.isNotEmpty) {
      final confirmed = hashConfirmedOverride != null
          ? await hashConfirmedOverride(knownFeeHash)
          : await _hashConfirmedInWallet(knownFeeHash);
      if (confirmed) {
        broLog(
            '💼 Taxa da ordem ${orderId.length > 8 ? orderId.substring(0, 8) : orderId} confirmada no histórico (hash) — SEM re-pagar');
        _paidOrderIds.add(orderId);
        await _savePaidOrderIds();
        return true;
      }
      // Um hash salvo é evidência de tentativa anterior. Histórico vazio,
      // incompleto ou indisponível NÃO autoriza uma nova cobrança.
      broLog(
          '🛡️ Taxa da ordem ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}: hash salvo não confirmado — NÃO re-pagar');
      return false;
    }

    // Outra chamada pode ter concluído a taxa durante a verificação acima.
    if (_paidOrderIds.contains(orderId)) return true;

    // CORREÇÃO v1.0.129+224: LOCK IMEDIATO para prevenir race condition
    // Adicionar ao Set SINCRONAMENTE antes de qualquer await.
    // Sem isso, duas chamadas concorrentes (order_status_screen + onPaymentSent)
    // passam o contains() check acima antes de qualquer uma completar o pagamento,
    // resultando em taxa duplicada.
    _paidOrderIds.add(orderId);
    broLog(
        '💼 Lock adquirido para ordem ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}');

    // Calcular taxa da plataforma: 2% do valor total (mínimo 1 sat)
    final feePercent = feePercentOverride ?? AppConfig.platformFeePercent;
    final platformFeeRaw = (totalSats * feePercent).round();
    final platformFeeSats = platformFeeRaw < 1 ? 1 : platformFeeRaw;

    if (platformFeeSats <= 0) {
      broLog('💼 Taxa da plataforma = 0 sats, ignorando...');
      return true;
    }

    if (!AppConfig.isPlatformLightningAddressValid) {
      // vSEC: validação de FORMATO (não só isNotEmpty) — endereço malformado
      // no env.json falhava só em runtime, derrubando a taxa silenciosamente.
      broLog('⚠️ platformLightningAddress ausente ou malformado!');
      _paidOrderIds.remove(orderId); // Liberar lock para retry
      return false;
    }

    broLog('');
    broLog('💼 ════════════════════════════════════════════════');
    broLog('💼 ENVIANDO TAXA DA PLATAFORMA');
    broLog(
        '💼 Ordem: ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}...');
    broLog('💼 Valor total: $totalSats sats');
    broLog(
        '💼 Taxa (${(feePercent * 100).toStringAsFixed(1)}%): $platformFeeSats sats');

    // v857: split 80/20 quando há coordinator escolhido. Sem coordinator,
    // split.primarySats == platformFeeSats e foundationSats == 0 (idêntico
    // ao comportamento anterior).
    final split = await resolveFeeSplit(totalFeeSats: platformFeeSats);
    broLog('💼 Destino: ${split.primaryAddress} (${split.primarySats} sats)'
        '${split.hasSplit ? ' + fundação ${split.foundationAddress} (${split.foundationSats} sats)' : ''}');
    broLog('💼 Backend: $_currentBackend');
    broLog('💼 ════════════════════════════════════════════════');
    broLog('');

    if (_payInvoiceCallback == null) {
      broLog('❌ ERRO: Callback de pagamento não configurado!');
      broLog(
          '   Certifique-se de chamar PlatformFeeService.setPaymentCallback() na inicialização');
      _paidOrderIds.remove(orderId); // Liberar lock para retry
      return false;
    }

    try {
      final platformAddress = split.primaryAddress;
      // v857: valor efetivamente enviado ao destino principal (coordinator ou
      // plataforma). Sem split é igual à taxa cheia.
      final primaryAmountSats = split.primarySats > 0 ? split.primarySats : platformFeeSats;

      // Detectar tipo de endereço Lightning
      if (platformAddress.contains('@')) {
        // Lightning Address (user@domain.com)
        broLog('💼 Resolvendo Lightning Address: $platformAddress');

        final lnAddressService = LnAddressService();
        final result = await lnAddressService.getInvoice(
          lnAddress: platformAddress,
          amountSats: primaryAmountSats,
          comment:
              'Bro Platform Fee - ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}',
        );

        broLog(
            '💼 Resultado LNURL: success=${result['success']}, hasInvoice=${result['invoice'] != null}');

        if (result['success'] != true || result['invoice'] == null) {
          broLog(
              '❌ Falha ao obter invoice do LN Address: ${result['error'] ?? 'unknown'}');
          _paidOrderIds.remove(orderId); // Liberar lock para retry
          return false;
        }

        final invoice = result['invoice'] as String;
        broLog('💼 Invoice obtido: ${invoice.substring(0, 50)}...');
        // v869: RASTREABILIDADE — registra o hash da invoice ANTES de pagar.
        // Sem isso é impossível correlacionar um recebimento no extrato do
        // destinatário com a ordem que o gerou (caso 26/11: 8 taxas de 1 sat
        // sem origem identificável). Formato estável para grep:
        //   [FEE-TRACE] order=<id> amount=<sats> hash=<paymentHash> dest=<addr>
        String? invoiceHash;
        if (onAttempt != null) {
          final decoded = await BreezProvider().decodeInvoice(invoice);
          final attemptHash = decoded?['invoice']?['paymentHash'] as String?;
          if (attemptHash != null && attemptHash.isNotEmpty) {
            invoiceHash = attemptHash;
            await onAttempt(invoice, attemptHash);
          }
        }
        if (invoiceHash == null) {
          try {
            final decoded = await BreezProvider().decodeInvoice(invoice);
            invoiceHash = decoded?['invoice']?['paymentHash'] as String?;
          } catch (_) {}
        }
        broLog('[FEE-TRACE] order=$orderId amount=$primaryAmountSats '
            'hash=${invoiceHash ?? "?"} dest=$platformAddress');
        broLog('💼 Pagando via $_currentBackend...');

        // A taxa BRIX é um serviço e deve ser cobrada. A reserva de rede só
        // evita pagar a taxa duas vezes; nunca impede a cobrança.
        final payResult = await _payInvoiceCallback!(invoice);

        if (payResult != null && payResult['success'] == true) {
          // Lock já foi adquirido - apenas persistir no storage
          await _savePaidOrderIds();

          // Salvar payment hash para filtrar do histórico da carteira
          final payHash = payResult['payment']?['paymentHash'] as String?;
          if (payHash != null && payHash.isNotEmpty) {
            await _saveFeePaymentHash(payHash);
            if (onPaid != null) await onPaid(payHash);
            // ANTI RE-PAGAMENTO: persistir o hash NA ORDEM (Nostr) — sobrevive à
            // reinstalação. Assim o FeeReconcile consegue confirmar que a taxa
            // já foi paga mesmo com o app reinstalado, e nunca re-paga.
            if (_onFeePaidPersist != null) {
              try {
                await _onFeePaidPersist!(orderId, payHash);
              } catch (_) {}
            }
          }

          broLog('');
          broLog('✅ ════════════════════════════════════════════════');
          broLog('✅ TAXA DA PLATAFORMA PAGA COM SUCESSO!');
          broLog('✅ Valor: $primaryAmountSats sats');
          broLog('✅ Destino: $platformAddress');
          broLog('✅ Backend: $_currentBackend');
          broLog('✅ ════════════════════════════════════════════════');
          broLog('');

          // v857: fatia da fundação (20%). Falha aqui NÃO invalida o pagamento
          // principal — o coordinator já recebeu. Loga e segue; a fundação
          // pode ser reconciliada depois pelo histórico.
          await _payFoundationShare(split, orderId);

          // Marcar como coletada no tracking
          await markAsCollected([orderId]);

          return true;
        } else {
          broLog('❌ Falha no pagamento: $payResult');
          if (payResult?['mayStillSucceed'] != true) {
            _paidOrderIds.remove(orderId);
          }
          return false;
        }
      } else if (platformAddress.toLowerCase().startsWith('lno1')) {
        // BOLT12 Offer - ainda não suportado
        broLog('⚠️ BOLT12 Offer detectado - não suportado ainda');
        _paidOrderIds.remove(orderId); // Liberar lock para retry
        return false;
      } else if (platformAddress.toLowerCase().startsWith('ln')) {
        // Invoice BOLT11 direto
        broLog('💼 Pagando invoice BOLT11 direto...');
        if (onAttempt != null) {
          final decoded = await BreezProvider().decodeInvoice(platformAddress);
          final attemptHash = decoded?['invoice']?['paymentHash'] as String?;
          if (attemptHash != null && attemptHash.isNotEmpty) {
            await onAttempt(platformAddress, attemptHash);
          }
        }

        final payResult = await _payInvoiceCallback!(platformAddress);

        if (payResult != null && payResult['success'] == true) {
          // Lock já foi adquirido - apenas persistir no storage
          await _savePaidOrderIds();

          // Salvar payment hash para filtrar do histórico
          final payHash = payResult['payment']?['paymentHash'] as String?;
          if (payHash != null && payHash.isNotEmpty) {
            await _saveFeePaymentHash(payHash);
            if (onPaid != null) await onPaid(payHash);
          }

          broLog('✅ TAXA DA PLATAFORMA PAGA COM SUCESSO via $_currentBackend!');
          await markAsCollected([orderId]);
          return true;
        } else {
          broLog('❌ Falha no pagamento: $payResult');
          if (payResult?['mayStillSucceed'] != true) {
            _paidOrderIds.remove(orderId);
          }
          return false;
        }
      }

      broLog('⚠️ Tipo de endereço não reconhecido: $platformAddress');
      _paidOrderIds.remove(orderId); // Liberar lock para retry
      return false;
    } catch (e, stack) {
      broLog('❌ ERRO ao pagar taxa da plataforma: $e');
      broLog('   Stack: $stack');
      final pending = e.toString().toLowerCase().contains('timeout') ||
          e.toString().toLowerCase().contains('alreadyexists') ||
          e.toString().toLowerCase().contains('already paid');
      if (!pending) _paidOrderIds.remove(orderId);
      return false;
    }
  }
}
