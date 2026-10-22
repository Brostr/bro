import 'package:crypto/crypto.dart';

import '../config.dart';

/// Serviço de validação e sanitização de inputs
/// Previne injeção de código e dados maliciosos
class InputValidationService {
  static final InputValidationService _instance = InputValidationService._internal();
  factory InputValidationService() => _instance;
  InputValidationService._internal();

  /// Sanitiza texto removendo caracteres perigosos
  String sanitizeText(String input, {int maxLength = 500}) {
    if (input.isEmpty) return input;
    
    // Remove caracteres de controle
    String sanitized = input.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '');
    
    // Remove tags HTML/script
    sanitized = sanitized.replaceAll(RegExp(r'<[^>]*>'), '');
    
    // Limita tamanho
    if (sanitized.length > maxLength) {
      sanitized = sanitized.substring(0, maxLength);
    }
    
    return sanitized.trim();
  }
  
  /// Valida e sanitiza valor monetário em BRL
  ValidationResult validateBrlAmount(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^\d,.]'), '');
    
    // Converte vírgula para ponto
    final normalized = sanitized.replaceAll(',', '.');
    
    final amount = double.tryParse(normalized);
    
    if (amount == null) {
      return ValidationResult(
        isValid: false,
        error: 'Valor inválido',
      );
    }
    
    if (amount <= 0) {
      return ValidationResult(
        isValid: false,
        error: 'Valor deve ser maior que zero',
      );
    }
    
    if (amount > 100000) {
      return ValidationResult(
        isValid: false,
        error: 'Valor máximo excedido (R\$ 100.000)',
      );
    }
    
    return ValidationResult(
      isValid: true,
      sanitizedValue: amount.toString(),
    );
  }
  
  /// Valida chave PIX
  ValidationResult validatePixKey(String input) {
    final sanitized = sanitizeText(input, maxLength: 100);
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Chave PIX obrigatória');
    }
    
    // CPF: 11 dígitos
    if (RegExp(r'^\d{11}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'cpf');
    }
    
    // CNPJ: 14 dígitos
    if (RegExp(r'^\d{14}$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'cnpj');
    }
    
    // Email
    if (RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized.toLowerCase(), type: 'email');
    }
    
    // Telefone: +55 + DDD + número
    final phoneClean = sanitized.replaceAll(RegExp(r'[^\d+]'), '');
    if (RegExp(r'^\+?55?\d{10,11}$').hasMatch(phoneClean)) {
      return ValidationResult(isValid: true, sanitizedValue: phoneClean, type: 'phone');
    }
    
    // Chave aleatória: 32 caracteres alfanuméricos
    if (RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$', caseSensitive: false).hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized.toLowerCase(), type: 'random');
    }
    
    // PIX copia e cola (começa com padrão EMV)
    if (sanitized.startsWith('00020126')) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'emv');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'Formato de chave PIX inválido',
    );
  }
  
  /// Valida código de barras de boleto
  ValidationResult validateBoletoCode(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^\d]'), '');
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Código do boleto obrigatório');
    }
    
    // Boleto bancário: 47 dígitos (linha digitável)
    if (sanitized.length == 47) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'bancario');
    }
    
    // Convênio/concessionária: 48 dígitos
    if (sanitized.length == 48) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'convenio');
    }
    
    // Código de barras: 44 dígitos
    if (sanitized.length == 44) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'barcode');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'Código de boleto inválido (esperado 44, 47 ou 48 dígitos)',
    );
  }
  
  /// Valida invoice Lightning
  ValidationResult validateLightningInvoice(String input) {
    final sanitized = sanitizeText(input, maxLength: 1000).toLowerCase();
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Invoice obrigatória');
    }
    
    // BOLT11: começa com lnbc (mainnet), lntb (testnet), lnbcrt (regtest)
    if (sanitized.startsWith('lnbc') || 
        sanitized.startsWith('lntb') || 
        sanitized.startsWith('lnbcrt')) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized);
    }
    
    // Lightning Address: user@domain.com
    if (sanitized.contains('@') && RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$').hasMatch(sanitized)) {
      return ValidationResult(isValid: true, sanitizedValue: sanitized, type: 'lnaddress');
    }
    
    return ValidationResult(
      isValid: false,
      error: 'Invoice Lightning inválida',
    );
  }
  
  /// Valida endereço Bitcoin
  /// [allowTestnet] defaults to the app's configured network policy.
  ValidationResult validateBitcoinAddress(String input, {bool? allowTestnet}) {
    final sanitized = sanitizeText(input, maxLength: 100);
    
    if (sanitized.isEmpty) {
      return ValidationResult(isValid: false, error: 'Endereço obrigatório');
    }
    
    final lower = sanitized.toLowerCase();
    final isTestnet = lower.startsWith('tb1') ||
        lower.startsWith('m') ||
        lower.startsWith('n') ||
        lower.startsWith('2');

    final acceptsTestnet =
        allowTestnet ?? (AppConfig.testMode || !AppConfig.useMainnet);
    if (isTestnet && !acceptsTestnet) {
      return ValidationResult(
        isValid: false,
        error: 'Endereço de testnet não aceito',
      );
    }

    if (lower.startsWith('bc1') || lower.startsWith('tb1')) {
      return _validateSegwitAddress(sanitized);
    }

    final base58Result = _validateBase58Address(sanitized, acceptsTestnet);
    if (base58Result != null) {
      return base58Result;
    }

    return ValidationResult(
      isValid: false,
      error: 'Endereço Bitcoin inválido',
    );
  }

  ValidationResult _validateSegwitAddress(String address) {
    if (address != address.toLowerCase() && address != address.toUpperCase()) {
      return ValidationResult(
        isValid: false,
        error: 'Endereço Bitcoin inválido',
      );
    }

    final normalized = address.toLowerCase();
    final separatorIndex = normalized.lastIndexOf('1');
    if (separatorIndex < 1 ||
        separatorIndex + 8 > normalized.length ||
        normalized.length > 90) {
      return ValidationResult(
        isValid: false,
        error: 'Endereço Bitcoin inválido',
      );
    }

    final hrp = normalized.substring(0, separatorIndex);
    if (hrp != 'bc' && hrp != 'tb') {
      return ValidationResult(
        isValid: false,
        error: 'Endereço Bitcoin inválido',
      );
    }

    final data = <int>[];
    for (final codeUnit in normalized.substring(separatorIndex + 1).codeUnits) {
      final value = _bech32Charset.indexOf(String.fromCharCode(codeUnit));
      if (value == -1) {
        return ValidationResult(
          isValid: false,
          error: 'Endereço Bitcoin inválido',
        );
      }
      data.add(value);
    }

    final encoding = _bech32Encoding(hrp, data);
    if (encoding == null) {
      return ValidationResult(
        isValid: false,
        error: 'Checksum inválido - verifique se digitou corretamente',
      );
    }

    final witnessVersion = data.first;
    if (witnessVersion > 16) {
      return ValidationResult(
        isValid: false,
        error: 'Endereço Bitcoin inválido',
      );
    }

    final program = _convertBits(data.sublist(1, data.length - 6), 5, 8, false);
    if (program == null || program.length < 2 || program.length > 40) {
      return ValidationResult(
        isValid: false,
        error: 'Endereço Bitcoin inválido',
      );
    }

    if (witnessVersion == 0) {
      if (encoding != 'bech32' ||
          (program.length != 20 && program.length != 32)) {
        return ValidationResult(
          isValid: false,
          error: 'Endereço Bitcoin inválido',
        );
      }
    } else if (encoding != 'bech32m') {
      return ValidationResult(
        isValid: false,
        error: 'Endereço Bitcoin inválido',
      );
    }

    return ValidationResult(
      isValid: true,
      sanitizedValue: normalized,
      type: encoding,
    );
  }

  ValidationResult? _validateBase58Address(String address, bool allowTestnet) {
    // 25 bytes encode to at most 35 chars; bound input before BigInt decoding.
    if (address.length > 35 ||
        !RegExp(r'^[1-9A-HJ-NP-Za-km-z]+$').hasMatch(address)) {
      return null;
    }

    final decoded = _decodeBase58(address);
    if (decoded == null || decoded.length != 25) {
      return ValidationResult(
        isValid: false,
        error: 'Endereço Bitcoin inválido',
      );
    }

    final payload = decoded.sublist(0, decoded.length - 4);
    final checksum = decoded.sublist(decoded.length - 4);
    final expected =
        sha256.convert(sha256.convert(payload).bytes).bytes.take(4).toList();
    for (var i = 0; i < 4; i++) {
      if (checksum[i] != expected[i]) {
        return ValidationResult(
          isValid: false,
          error: 'Checksum inválido - verifique se digitou corretamente',
        );
      }
    }

    final version = decoded.first;
    if (version == 0x00 || (allowTestnet && version == 0x6f)) {
      return ValidationResult(
        isValid: true,
        sanitizedValue: address,
        type: 'p2pkh',
      );
    }
    if (version == 0x05 || (allowTestnet && version == 0xc4)) {
      return ValidationResult(
        isValid: true,
        sanitizedValue: address,
        type: 'p2sh',
      );
    }

    return ValidationResult(
      isValid: false,
      error: 'Endereço Bitcoin inválido',
    );
  }

  List<int>? _decodeBase58(String input) {
    var value = BigInt.zero;
    for (final char in input.split('')) {
      final digit = _base58Alphabet.indexOf(char);
      if (digit == -1) return null;
      value = value * BigInt.from(58) + BigInt.from(digit);
    }

    final bytes = <int>[];
    while (value > BigInt.zero) {
      bytes.insert(0, (value % BigInt.from(256)).toInt());
      value ~/= BigInt.from(256);
    }

    for (var i = 0; i < input.length && input[i] == '1'; i++) {
      bytes.insert(0, 0);
    }

    return bytes;
  }

  String? _bech32Encoding(String hrp, List<int> data) {
    final polymod = _bech32Polymod([..._bech32HrpExpand(hrp), ...data]);
    if (polymod == 1) return 'bech32';
    if (polymod == 0x2bc830a3) return 'bech32m';
    return null;
  }

  int _bech32Polymod(List<int> values) {
    const generator = [
      0x3b6a57b2,
      0x26508e6d,
      0x1ea119fa,
      0x3d4233dd,
      0x2a1462b3,
    ];
    var chk = 1;
    for (final value in values) {
      final top = chk >> 25;
      chk = ((chk & 0x1ffffff) << 5) ^ value;
      for (var i = 0; i < 5; i++) {
        if (((top >> i) & 1) == 1) {
          chk ^= generator[i];
        }
      }
    }
    return chk;
  }

  List<int> _bech32HrpExpand(String hrp) {
    return [
      ...hrp.codeUnits.map((x) => x >> 5),
      0,
      ...hrp.codeUnits.map((x) => x & 31),
    ];
  }

  List<int>? _convertBits(List<int> data, int fromBits, int toBits, bool pad) {
    var acc = 0;
    var bits = 0;
    final ret = <int>[];
    final maxv = (1 << toBits) - 1;
    final maxAcc = (1 << (fromBits + toBits - 1)) - 1;

    for (final value in data) {
      if (value < 0 || (value >> fromBits) != 0) return null;
      acc = ((acc << fromBits) | value) & maxAcc;
      bits += fromBits;
      while (bits >= toBits) {
        bits -= toBits;
        ret.add((acc >> bits) & maxv);
      }
    }

    if (pad) {
      if (bits > 0) {
        ret.add((acc << (toBits - bits)) & maxv);
      }
    } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0) {
      return null;
    }

    return ret;
  }
}

const _bech32Charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const _base58Alphabet =
    '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

class ValidationResult {
  final bool isValid;
  final String? error;
  final String? sanitizedValue;
  final String? type;
  
  ValidationResult({
    required this.isValid,
    this.error,
    this.sanitizedValue,
    this.type,
  });
}
