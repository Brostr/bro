#!/usr/bin/env bash
# Publica os metadados do app na Zapstore lendo a nsec de um arquivo temporario
# (C:\Users\produ\bro_nsec_temp.txt). O arquivo e apagado logo apos o uso e a
# saida do zsp vai apenas para um log que e higienizado (chaves removidas).
cd /mnt/c/Users/produ/Documents/GitHub/bro_app || exit 1
NSEC_FILE=/mnt/c/Users/produ/bro_nsec_temp.txt
LOG=/mnt/c/Users/produ/Documents/GitHub/bro_app/scripts/zsp_last.log
: > "$LOG"

if [ ! -f "$NSEC_FILE" ]; then
  echo "ERRO: arquivo da nsec nao encontrado ($NSEC_FILE)."
  exit 2
fi

K="$(tr -d '[:space:]' < "$NSEC_FILE")"
if [ -z "$K" ]; then
  echo "ERRO: o arquivo da nsec esta vazio."
  rm -f "$NSEC_FILE"
  exit 3
fi

if ! printf '%s' "$K" | grep -qiE '^(nsec1[0-9a-z]{20,}|[0-9a-f]{64})$'; then
  echo "ERRO: o conteudo colado nao parece uma nsec valida (nem nsec1... nem hex de 64)."
  shred -u "$NSEC_FILE" 2>/dev/null || rm -f "$NSEC_FILE"
  exit 4
fi

# Publica. Saida (que poderia conter a chave em mensagens de erro) vai SO pro log.
SIGN_WITH="$K" ~/bin/zsp publish --overwrite-release --skip-certificate-linking --skip-preview --quiet zapstore.yaml > "$LOG" 2>&1
status=$?
unset K

# Apaga a nsec imediatamente
shred -u "$NSEC_FILE" 2>/dev/null || rm -f "$NSEC_FILE"

# Higieniza o log: remove qualquer nsec/hex antes de qualquer leitura
sed -i -E 's/nsec1[0-9a-z]{20,}/nsec1_REDACTED/gI; s/\b[0-9a-fA-F]{64}\b/HEX64_REDACTED/g' "$LOG" 2>/dev/null

echo "STATUS=$status"
