import 'package:bro_app/services/log_utils.dart';
import 'package:dio/dio.dart';

/// Servico para buscar preco real do Bitcoin de APIs publicas.
///
/// v592: multi-moeda. Coinbase /exchange-rates retorna todas as fiat em
/// uma chamada so, entao cacheamos o objeto inteiro e fazemos lookup
/// local por ISO-4217 (BRL, ARS, MXN, COP, INR, THB...).
class BitcoinPriceService {
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  /// Moedas que o app conhece (apenas para query no CoinGecko).
  static const Set<String> kSupportedFiats = {
    'BRL', 'USD', 'EUR', 'ARS', 'MXN', 'COP', 'INR', 'THB',
  };

  /// Cache de todas as taxas BTC->fiat (chave ISO-4217 uppercase).
  static Map<String, double>? _ratesCache;
  static DateTime? _ratesFetchedAt;
  static const _cacheDuration = Duration(minutes: 2);

  /// Preco do BTC numa moeda especifica (ISO-4217). null se indisponivel.
  static Future<double?> getBitcoinPriceIn(String currency) async {
    final cur = currency.toUpperCase();
    final rates = await _getAllRatesWithCache();
    if (rates == null) return null;
    final v = rates[cur];
    if (v == null) {
      broLog('⚠️ Sem cotação para $cur');
      return null;
    }
    return v;
  }

  /// Compat: BTC -> BRL.
  static Future<double?> getBitcoinPriceInBRL() => getBitcoinPriceIn('BRL');

  static Future<Map<String, double>?> _getAllRatesWithCache() async {
    if (_ratesCache != null && _ratesFetchedAt != null) {
      final age = DateTime.now().difference(_ratesFetchedAt!);
      if (age < _cacheDuration) return _ratesCache;
    }
    Map<String, double>? rates = await _getCoinbaseRates();
    rates ??= await _getCoingeckoRates();
    rates ??= await _getBinanceFallbackBrlOnly();
    if (rates != null) {
      _ratesCache = rates;
      _ratesFetchedAt = DateTime.now();
    }
    return rates;
  }

  static Future<Map<String, double>?> _getCoinbaseRates() async {
    try {
      broLog('📡 Buscando taxas BTC na Coinbase...');
      final response = await _dio.get(
        'https://api.coinbase.com/v2/exchange-rates?currency=BTC',
      );
      final rawRates = response.data['data']?['rates'];
      if (rawRates is! Map) return null;
      final out = <String, double>{};
      rawRates.forEach((k, v) {
        if (v == null) return;
        final d = double.tryParse(v.toString());
        if (d != null) out[k.toString().toUpperCase()] = d;
      });
      if (out.isEmpty) return null;
      broLog('✅ Coinbase: ${out.length} moedas (BRL=${out['BRL']?.toStringAsFixed(2)})');
      return out;
    } catch (e) {
      broLog('⚠️ Coinbase falhou: $e');
      return null;
    }
  }

  static Future<Map<String, double>?> _getCoingeckoRates() async {
    try {
      broLog('📡 Buscando taxas BTC no CoinGecko...');
      final response = await _dio.get(
        'https://api.coingecko.com/api/v3/simple/price',
        queryParameters: {
          'ids': 'bitcoin',
          'vs_currencies':
              kSupportedFiats.map((c) => c.toLowerCase()).join(','),
        },
      );
      final btc = response.data['bitcoin'];
      if (btc is! Map) return null;
      final out = <String, double>{};
      btc.forEach((k, v) {
        if (v == null) return;
        final d = double.tryParse(v.toString());
        if (d != null) out[k.toString().toUpperCase()] = d;
      });
      if (out.isEmpty) return null;
      broLog('✅ CoinGecko: ${out.length} moedas');
      return out;
    } catch (e) {
      broLog('⚠️ CoinGecko falhou: $e');
      return null;
    }
  }

  static Future<Map<String, double>?> _getBinanceFallbackBrlOnly() async {
    try {
      broLog('📡 Fallback Binance (só BRL/USD)...');
      final btcUsdt = double.parse((await _dio.get(
        'https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT',
      )).data['price'].toString());
      final usdtBrl = double.parse((await _dio.get(
        'https://api.binance.com/api/v3/ticker/price?symbol=USDTBRL',
      )).data['price'].toString());
      return {'BRL': btcUsdt * usdtBrl, 'USD': btcUsdt};
    } catch (e) {
      broLog('⚠️ Binance fallback falhou: $e');
      return null;
    }
  }

  /// Compat: preco com cache em BRL.
  static Future<double?> getBitcoinPriceWithCache() => getBitcoinPriceIn('BRL');

  /// v595: moeda de exibição padrão por idioma.
  /// - `pt` (português) → BRL
  /// - `es` (espanhol)  → USD
  /// - `en` (inglês)    → USD
  /// - qualquer outro   → USD
  ///
  /// Não é uma conversão de PIX para dólar — só define em qual moeda os
  /// preços do BTC (dashboard, carteira, marketplace) são MOSTRADOS quando
  /// o usuário troca o idioma do app. As ordens PIX continuam em BRL.
  static String displayCurrencyForLanguage(String languageCode) {
    switch (languageCode.toLowerCase()) {
      case 'pt':
        return 'BRL';
      case 'es':
      case 'en':
      default:
        return 'USD';
    }
  }

  /// Atalho: cotação BTC na moeda de exibição do idioma atual.
  static Future<double?> getBitcoinPriceForLanguage(String languageCode) {
    return getBitcoinPriceIn(displayCurrencyForLanguage(languageCode));
  }

  static void clearCache() {
    _ratesCache = null;
    _ratesFetchedAt = null;
  }

  /// Instance alias (compat).
  Future<double?> getBitcoinPrice() => getBitcoinPriceWithCache();
}
