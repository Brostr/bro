import 'package:bro_app/services/log_utils.dart';
import 'package:dio/dio.dart';
import '../config.dart';
import 'api_service.dart';

/// EscrowService
///
/// IMPORTANTE (ver .github/copilot-instructions.md e memória do repo):
/// A garantia/colateral do Bro é DESCENTRALIZADA. A fonte da verdade é local
/// (`LocalCollateralService` em FlutterSecureStorage) + a carteira Spark/Breez
/// do próprio provedor. O pagamento real ao provedor (auto-liquidação/disputa)
/// sai via Lightning (`breezProvider.payInvoice`), NÃO por escrow no backend.
///
/// As rotas backend `/escrow` e `/collateral` eram de um design antigo de escrow
/// centralizado (abandonado) — hoje são no-ops de bookkeeping. Por isso os métodos
/// de depósito/escrow/release foram removidos como código morto.
///
/// Só permanece aqui:
///  - [providerFeePercent]: constante da taxa do provedor, usada em várias telas.
///  - [lockCollateral]: ainda chamado por provider_order_detail_screen (best-effort,
///    não-bloqueante). Mantido para não alterar o fluxo da tela viva.
class EscrowService {
  /// Taxa do provedor Bro (3%) - usa o valor centralizado do AppConfig
  static double get providerFeePercent => AppConfig.providerFeePercent * 100;

  /// Dio instance do ApiService (com NIP-98 auth)
  Dio get _dio => ApiService().dio;

  Future<void> lockCollateral({required String providerId, required String orderId, required int lockedSats}) async {
    // Em modo teste OU providerTestMode, apenas logar
    if (AppConfig.testMode || AppConfig.providerTestMode) {
      broLog('🧪 Modo teste: lockCollateral simulado para ordem $orderId');
      return;
    }

    try {
      final response = await _dio.post(
        '/collateral/lock',
        data: {'orderId': orderId, 'lockedSats': lockedSats},
      ).timeout(const Duration(seconds: 10));

      broLog('🔒 lockCollateral response: ${response.statusCode}');
    } catch (e) {
      // Logar erro mas não bloquear - a garantia é gerenciada localmente
      broLog('⚠️ Erro ao chamar lockCollateral no backend: $e');
      broLog('   Continuando com garantia local...');
    }
  }
}
