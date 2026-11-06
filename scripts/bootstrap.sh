#!/usr/bin/env bash
# scripts/bootstrap.sh
# Cria o que o Terraform não cria sozinho: resource groups, storage do state
# e a identidade do pipeline (OIDC). Rode uma vez, logado com `az login`.
# É seguro rodar de novo: o que já existe é reaproveitado.
#
# Uso:  bash scripts/bootstrap.sh
#       STATE_SA=<nome> bash scripts/bootstrap.sh   # reaproveita a storage account

# ---------------------------------------------------------------------------
# Bloco 0: cabeçalho e variáveis
# ---------------------------------------------------------------------------
# -e: para no primeiro erro | -u: erro se usar variável não definida
# pipefail: um erro no meio de um pipe também derruba o script
set -euo pipefail

# O Git Bash do Windows converte argumentos que começam com "/" em caminhos do
# Windows, o que quebra scopes como /subscriptions/... Desliga a conversão.
export MSYS_NO_PATHCONV=1

LOCATION="${LOCATION:-eastus2}"
BOOT_RG=rg-azstudy-tfstate # resource group do state (sobrevive ao destroy da app)
APP_RG=rg-azstudy-dev      # resource group da aplicação
APP_NAME=sp-azstudy-github # nome da app registration do pipeline
GITHUB_REPO="${GITHUB_REPO:-heldemfilipe/azure-study-api}"

# Nome da storage account: 3-24 caracteres, só minúsculas e números, único no mundo.
STATE_SA="${STATE_SA:-stazstudytf$(openssl rand -hex 3)}"

# O az no Windows devolve CRLF; o "tr -d '\r'" tira o \r que o $(...) deixaria
# colado no valor. Sem isso, as variáveis ficam "sujas" e os comandos seguintes falham.
SUB_ID=$(az account show --query id -o tsv | tr -d '\r')
TENANT_ID=$(az account show --query tenantId -o tsv | tr -d '\r')
echo "Subscription: $SUB_ID | região: $LOCATION | storage do state: $STATE_SA"

# ---------------------------------------------------------------------------
# Bloco 1: registrar os resource providers
# ---------------------------------------------------------------------------
# Na Azure cada serviço é um "resource provider" que precisa estar registrado na
# subscription antes do primeiro uso (na AWS os serviços já vêm disponíveis).
# Registrar aqui permite que o Terraform rode sem permissão na subscription inteira.
# --wait espera terminar; pode levar alguns minutos na primeira vez.
# Microsoft.Storage: sem ele, criar a storage account falha com um enganoso
# "SubscriptionNotFound". Microsoft.Insights: necessário para o diagnostic setting.
for ns in Microsoft.Storage Microsoft.Insights Microsoft.App Microsoft.ContainerRegistry \
  Microsoft.OperationalInsights Microsoft.DocumentDB Microsoft.KeyVault Microsoft.ManagedIdentity; do
  echo "Registrando $ns..."
  az provider register --namespace "$ns" --wait
done

# ---------------------------------------------------------------------------
# Bloco 2: resource groups
# ---------------------------------------------------------------------------
# Todo recurso na Azure vive em um resource group: é o escopo de RBAC, de custo
# e de ciclo de vida (apagar o grupo apaga tudo dentro). `az group create` é
# idempotente: se o grupo existe, só atualiza.
az group create -n "$BOOT_RG" -l "$LOCATION" > /dev/null
az group create -n "$APP_RG" -l "$LOCATION" --tags project=study-api env=dev > /dev/null

# ---------------------------------------------------------------------------
# Bloco 3: storage account e container do state do Terraform
# ---------------------------------------------------------------------------
# Equivale ao bucket S3 do state. O lock é nativo (lease do blob); não existe
# tabela DynamoDB. Sem acesso público e com TLS 1.2 no mínimo.
if ! az storage account show -n "$STATE_SA" -g "$BOOT_RG" > /dev/null 2>&1; then
  az storage account create -n "$STATE_SA" -g "$BOOT_RG" -l "$LOCATION" \
    --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false > /dev/null
fi
# container-rm cria o container pelo plano de gerenciamento (não precisa de papel de dados)
az storage container-rm create --storage-account "$STATE_SA" -n tfstate > /dev/null

# ---------------------------------------------------------------------------
# Bloco 4: identidade do pipeline (app registration + service principal + OIDC)
# ---------------------------------------------------------------------------
# App registration = a definição da identidade; service principal = a instância
# dela no seu tenant. Juntas fazem o papel de uma IAM Role da AWS.

APP_ID=$(az ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv | tr -d '\r')
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv | tr -d '\r')
fi

SP_OBJ_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv | tr -d '\r')
if [ -z "$SP_OBJ_ID" ]; then
  SP_OBJ_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv | tr -d '\r')
fi

# Credencial federada = a "trust policy" da role na AWS. Diz: "aceite tokens
# emitidos por este issuer, com este subject e este audience". O subject restringe
# o login a workflows da branch main deste repositório; se não bater exato, falha.
CRED_FILE="./.cred.json"
trap 'rm -f "$CRED_FILE"' EXIT # apaga o arquivo temporário ao sair, mesmo com erro
cat > "$CRED_FILE" <<EOF
{
  "name": "github-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:${GITHUB_REPO}:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
HAS_CRED=$(az ad app federated-credential list --id "$APP_ID" \
  --query "[?name=='github-main'] | length(@)" -o tsv | tr -d '\r')
if [ "$HAS_CRED" = "0" ]; then
  az ad app federated-credential create --id "$APP_ID" --parameters "@${CRED_FILE}" > /dev/null
fi

# ---------------------------------------------------------------------------
# Bloco 5: permissões mínimas (só nos dois resource groups, nunca na subscription)
# ---------------------------------------------------------------------------
# O service principal acabou de nascer e demora a propagar no Entra ID; por isso
# tentamos algumas vezes. Se a atribuição já existe, pula.
assign() {
  local role="$1" scope="$2" found
  found=$(az role assignment list --assignee-object-id "$SP_OBJ_ID" --role "$role" \
    --scope "$scope" --query "length(@)" -o tsv | tr -d '\r')
  if [ "$found" != "0" ]; then
    echo "já existe: $role"
    return 0
  fi
  for attempt in 1 2 3 4 5 6; do
    if az role assignment create --assignee-object-id "$SP_OBJ_ID" \
      --assignee-principal-type ServicePrincipal --role "$role" --scope "$scope" > /dev/null; then
      echo "atribuído: $role"
      return 0
    fi
    echo "identidade ainda propagando (tentativa $attempt/6)..." >&2
    sleep 10
  done
  return 1
}

APP_SCOPE="/subscriptions/$SUB_ID/resourceGroups/$APP_RG"
STATE_SCOPE=$(az storage account show -n "$STATE_SA" -g "$BOOT_RG" --query id -o tsv | tr -d '\r')

# Contributor cria os recursos, mas NÃO cria role assignments. Como o Terraform vai
# conceder AcrPull e acesso ao Key Vault, a identidade também precisa do papel
# RBAC Administrator (na AWS: PowerUserAccess também não mexe em IAM).
assign "Contributor" "$APP_SCOPE"
assign "Role Based Access Control Administrator" "$APP_SCOPE"
# Papel de DADOS: ler e escrever o state em Blob via Entra ID, sem chave da storage.
assign "Storage Blob Data Contributor" "$STATE_SCOPE"

# ---------------------------------------------------------------------------
# Bloco 6: valores para as variáveis do GitHub
# ---------------------------------------------------------------------------
echo
echo "Crie estas 4 variáveis (identificadores, não segredos) em"
echo "GitHub > Settings > Secrets and variables > Actions > Variables:"
echo "ARM_CLIENT_ID=$APP_ID"
echo "ARM_TENANT_ID=$TENANT_ID"
echo "ARM_SUBSCRIPTION_ID=$SUB_ID"
echo "TF_STATE_SA=$STATE_SA"
