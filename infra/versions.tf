terraform {
  required_version = ">= 1.5.0"

  # Providers = plugins que sabem falar com cada API.
  # azurerm é o da Azure (na AWS seria "hashicorp/aws"). "~> 4.0" aceita 4.x, nunca 5.
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # State remoto em Blob Storage (equivale ao backend "s3"). O lock é nativo, sem DynamoDB.
  # Sem chave: use_oidc + use_azuread_auth autenticam com o token do pipeline.
  backend "azurerm" {
    resource_group_name = "rg-azstudy-tfstate"
    container_name      = "tfstate"
    key                 = "study-api.tfstate"
    use_oidc            = true
    use_azuread_auth    = true
    # storage_account_name vem do -backend-config no pipeline (TF_STATE_SA)
  }
}

# subscription_id, tenant_id e client_id vêm das variáveis de ambiente ARM_*.
provider "azurerm" {
  features {
    # Apaga o workspace de vez no destroy, para poder recriar o mesmo nome depois.
    log_analytics_workspace {
      permanently_delete_on_destroy = true
    }
  }

  # O pipeline só tem permissão nos resource groups, não na subscription; por isso
  # o registro dos providers foi feito no bootstrap e o Terraform não tenta registrar.
  resource_provider_registrations = "none"
}
