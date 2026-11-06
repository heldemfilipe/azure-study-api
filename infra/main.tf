# Identidade com a qual o Terraform está rodando (o service principal do pipeline).
# Dá acesso ao tenant_id e ao object_id. Na AWS: data "aws_caller_identity".
data "azurerm_client_config" "current" {}

# O resource group foi criado no bootstrap, não pelo Terraform: o pipeline não tem
# permissão para criar grupos, e o destroy da aplicação não deve apagar o grupo
# (isso levaria embora as atribuições de papel do pipeline).
data "azurerm_resource_group" "app" {
  name = "rg-${var.prefix}-${var.env}"
}

# Sufixo aleatório: ACR, Key Vault e Cosmos DB têm nome único no mundo inteiro.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix = random_string.suffix.result
  tags = {
    project    = "study-api"
    env        = var.env
    managed_by = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Logs: Log Analytics workspace (equivale a um CloudWatch Logs + Logs Insights)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${var.prefix}-${var.env}"
  location            = data.azurerm_resource_group.app.location
  resource_group_name = data.azurerm_resource_group.app.name
  sku                 = "PerGB2018" # cobrança por GB ingerido; 5 GB/mês gratuitos
  retention_in_days   = 30

  # Teto diário de ingestão: ao atingir, a coleta para pelo resto do dia.
  # Para estudo é o que se quer (custo previsível); em produção, não.
  daily_quota_gb = 0.1

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Imagens: Azure Container Registry (equivale ao ECR)
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "main" {
  name                = "acr${var.prefix}${var.env}${local.suffix}" # só letras e números
  location            = data.azurerm_resource_group.app.location
  resource_group_name = data.azurerm_resource_group.app.name
  sku                 = "Standard"
  admin_enabled       = false # desliga o usuário/senha do registry: só acesso por identidade
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Identidade do app: managed identity user-assigned (equivale à IAM Role da task)
# ---------------------------------------------------------------------------
# É criada separada do Container App de propósito: assim dá para conceder os papéis
# (AcrPull, Key Vault, Cosmos) ANTES do app existir e evitar erro de permissão no
# primeiro start.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.prefix}-${var.env}"
  location            = data.azurerm_resource_group.app.location
  resource_group_name = data.azurerm_resource_group.app.name
  tags                = local.tags
}

# Permite ao app puxar imagens do ACR. Role assignment = quem (principal) + o quê
# (papel) + onde (escopo). Aqui o escopo é só este registry, não o resource group.
resource "azurerm_role_assignment" "app_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Permite ao PIPELINE publicar imagens no ACR (docker push). Usa o object_id de quem
# está rodando o Terraform. Isto só funciona porque o bootstrap deu ao pipeline o
# papel "RBAC Administrator" no resource group.
resource "azurerm_role_assignment" "ci_acr_push" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---------------------------------------------------------------------------
# Segredo: Key Vault (equivale ao Secrets Manager)
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "main" {
  name                = "kv-${var.prefix}-${var.env}-${local.suffix}"
  location            = data.azurerm_resource_group.app.location
  resource_group_name = data.azurerm_resource_group.app.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Autorização por RBAC (papéis do Entra ID), não pelas "access policies" antigas.
  # É o modelo atual e o mesmo que usamos no resto do projeto.
  rbac_authorization_enabled = true

  # Soft delete: um vault apagado fica "na lixeira" por N dias. Mínimo de 7.
  # purge_protection desligado para o destroy poder apagar de vez em estudo.
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  tags = local.tags
}

# Quem GRAVA segredos: o pipeline (Terraform precisa criar o segredo de exemplo).
resource "azurerm_role_assignment" "ci_kv_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Quem LÊ segredos: só o app, e só leitura ("Secrets User"). Menor privilégio.
resource "azurerm_role_assignment" "app_kv_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Role assignments demoram a propagar no Entra ID. Sem esta espera, gravar o segredo
# logo após criar o papel falha com 403. Se ainda assim falhar, rode o apply de novo.
resource "time_sleep" "rbac" {
  depends_on      = [azurerm_role_assignment.ci_kv_officer]
  create_duration = "60s"
}

# Segredo de exemplo, gerado pelo Terraform: ninguém digita nem vê o valor.
# (Ele fica no state, que está em Storage privado com acesso só por identidade.)
resource "random_password" "demo" {
  length = 24
}

resource "azurerm_key_vault_secret" "demo" {
  name         = "demo-api-key"
  value        = random_password.demo.result
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [time_sleep.rbac]
}

# ---------------------------------------------------------------------------
# Banco: Cosmos DB NoSQL (equivale ao DynamoDB)
# ---------------------------------------------------------------------------
resource "azurerm_cosmosdb_account" "main" {
  name                = "cosmos-${var.prefix}-${var.env}-${local.suffix}"
  location            = data.azurerm_resource_group.app.location
  resource_group_name = data.azurerm_resource_group.app.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB" # API NoSQL

  # Free tier: 1.000 RU/s e 25 GB gratuitos. Só uma conta por subscription e só dá
  # para ligar na criação; se já existir outra, o apply falha.
  free_tier_enabled = true

  # Desliga as chaves de acesso: só entra quem tem papel de dados (Entra ID).
  local_authentication_enabled = false

  tags = local.tags

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = data.azurerm_resource_group.app.location
    failover_priority = 0
  }
}

resource "azurerm_cosmosdb_sql_database" "main" {
  name                = "studydb"
  resource_group_name = data.azurerm_resource_group.app.name
  account_name        = azurerm_cosmosdb_account.main.name
  throughput          = 400 # RU/s compartilhados entre os containers; dentro dos 1.000 gratuitos
}

resource "azurerm_cosmosdb_sql_container" "notes" {
  name                = "notes"
  resource_group_name = data.azurerm_resource_group.app.name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name

  # Partition key = a "chave de partição" do DynamoDB: define como os dados se
  # distribuem e quais consultas são baratas (aqui, por usuário).
  partition_key_paths = ["/userId"]
}

# O RBAC de DADOS do Cosmos é separado do RBAC do Azure Resource Manager: tem seus
# próprios papéis e seu próprio "role assignment". O ID ...0002 é o papel embutido
# "Cosmos DB Built-in Data Contributor" (ler e escrever documentos).
resource "azurerm_cosmosdb_sql_role_assignment" "app" {
  resource_group_name = data.azurerm_resource_group.app.name
  account_name        = azurerm_cosmosdb_account.main.name
  role_definition_id  = "${azurerm_cosmosdb_account.main.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_user_assigned_identity.app.principal_id
  scope               = azurerm_cosmosdb_account.main.id
}
