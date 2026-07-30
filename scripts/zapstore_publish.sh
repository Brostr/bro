#!/usr/bin/env bash
# Republica os metadados do app na Zapstore (kind 32267) com as tags do
# zapstore.yaml. A nsec NAO fica salva: e lida de forma oculta, usada so
# nesta execucao e descartada. Nada de chave passa por arquivo/historico.
clear
echo "===================================================="
echo "   PUBLICAR BRO NA ZAPSTORE (atualizar categorias)"
echo "===================================================="
echo
cd /mnt/c/Users/produ/Documents/GitHub/bro_app || { echo "Pasta nao encontrada"; read -r _; exit 1; }
echo ">> COLE a sua nsec aqui embaixo e tecle ENTER."
echo "   (ao colar NAO aparece nada na tela - isso e normal/proposital)"
echo
read -rsp 'nsec: ' K
echo
K="$(printf '%s' "$K" | tr -d '[:space:]')"
if [ -z "$K" ]; then
  echo
  echo "ERRO: nada foi colado. No cmd, COLAR e com o BOTAO DIREITO do mouse."
  echo "Pressione ENTER para fechar e tentamos de novo."
  read -r _; exit 1
fi
echo
echo ">> Publicando na Zapstore... aguarde alguns segundos."
echo
LOG=/mnt/c/Users/produ/Documents/GitHub/bro_app/scripts/zsp_last.log
SIGN_WITH="$K" ~/bin/zsp publish --overwrite-release --skip-certificate-linking --skip-preview --quiet zapstore.yaml 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
unset K
# Remove qualquer chave do log antes de qualquer analise (seguranca)
sed -i -E 's/nsec1[0-9a-z]{20,}/nsec1_REDACTED/g; s/\b[0-9a-fA-F]{64}\b/HEX64_REDACTED/g' "$LOG" 2>/dev/null
echo
if [ "$status" -eq 0 ]; then
  echo "==================================================="
  echo "   PRONTO! Categorias atualizadas com sucesso."
  echo "==================================================="
else
  echo "==================================================="
  echo "   ERRO (codigo $status). Tire um print e me mostre."
  echo "==================================================="
fi
echo
echo "Pressione ENTER para fechar esta janela."
read -r _
exit $status
