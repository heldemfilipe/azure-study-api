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
