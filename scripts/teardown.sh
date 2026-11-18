#!/usr/bin/env bash
# scripts/teardown.sh
# Encerramento DEFINITIVO do estudo: apaga a base (state do Terraform, resource group
# da aplicação e identidade do pipeline).
#
# Antes, destrua a aplicação pelo workflow "infra" (action = destroy) e confira que
# `az resource list -g rg-azstudy-dev -o table` vem vazio. Para a rotina de cada
# sessão, só o destroy do workflow basta: este script é para encerrar o projeto.
#
# Uso: ARM_CLIENT_ID=<appId do sp-azstudy-github> bash scripts/teardown.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1

BOOT_RG=rg-azstudy-tfstate
APP_RG=rg-azstudy-dev
: "${ARM_CLIENT_ID:?defina ARM_CLIENT_ID com o appId do sp-azstudy-github}"

echo "Isto apaga $BOOT_RG (state do Terraform), $APP_RG e a app registration $ARM_CLIENT_ID."
read -r -p "Digite 'apagar' para continuar: " answer
[ "$answer" = "apagar" ] || { echo "Cancelado."; exit 1; }

# Se você criou o lock de proteção do state (docs/governanca.md), ele precisa sair primeiro.
az lock delete --name keep-state --resource-group "$BOOT_RG" 2> /dev/null || true

az group delete -n "$BOOT_RG" --yes
az group delete -n "$APP_RG" --yes
az ad app delete --id "$ARM_CLIENT_ID"
echo "Concluído. Confira com: az group list -o table"
