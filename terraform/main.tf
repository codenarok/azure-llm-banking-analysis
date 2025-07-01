terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~>3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~>3.1"
    }
    azuread = {
      source = "hashicorp/azuread"
      version = "~>2.39"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "azuread" {}

data "azuread_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# 1. Azure Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "az-llm-banking-rg-${random_string.suffix.result}"
  location = var.location
}

# 2. Azure Storage Account (Data Lake Gen2 & Static Website)
resource "azurerm_storage_account" "storage" {
  name                     = "azllmbankstorage${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true # Enables Data Lake Storage Gen2

  static_website {
    index_document = "index.html"
  }
}

# 3. Azure SQL Server and Database
resource "azurerm_mssql_server" "sqlserver" {
  name                         = "az-llm-bank-sqlserver-${random_string.suffix.result}"
  resource_group_name          = azurerm_resource_group.rg.name
  location                     = azurerm_resource_group.rg.location
  version                      = "12.0"
  administrator_login          = "sqladminuser"
  administrator_login_password = "thisIsAPassword123!"

  azuread_administrator {
    login_username = var.sql_admin_login
    object_id      = data.azuread_client_config.current.object_id
  }
}

resource "azurerm_mssql_database" "sqldb" {
  name           = "financialdb"
  server_id      = azurerm_mssql_server.sqlserver.id
  collation      = "SQL_Latin1_General_CP1_CI_AS"
  license_type   = "LicenseIncluded"
  max_size_gb    = 1
  sku_name       = "S0"
}

# 4. Azure Data Factory
resource "azurerm_data_factory" "adf" {
  name                = "az-llm-bank-adf-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# 5. Azure OpenAI Service
resource "azurerm_cognitive_account" "openai" {
  name                = "az-llm-bank-openai-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  kind                = "OpenAI"
  sku_name            = "S0"
}

resource "azurerm_cognitive_deployment" "openai_deployment" {
  name                  = "gpt-4o"
  cognitive_account_id  = azurerm_cognitive_account.openai.id
  model {
    format  = "OpenAI"
    name    = "gpt-4o"
    version = "2024-05-13"
  }
  scale {
    type = "Standard"
  }
}

# 6. Azure Key Vault
resource "azurerm_key_vault" "kv" {
  name                        = "az-llm-kv-${random_string.suffix.result}"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id
    key_permissions = [
      "Get",
    ]
    secret_permissions = [
      "Get",
      "List",
      "Set",
      "Delete",
      "Purge",
      "Recover"
    ]
    storage_permissions = [
      "Get",
    ]
  }
}

resource "azurerm_key_vault_secret" "sql_connection_string" {
  name         = "sql-connection-string"
  value        = "Server=tcp:${azurerm_mssql_server.sqlserver.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.sqldb.name};Persist Security Info=False;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
  key_vault_id = azurerm_key_vault.kv.id
}

resource "azurerm_key_vault_secret" "openai_api_key" {
  name         = "openai-api-key"
  value        = azurerm_cognitive_account.openai.primary_access_key
  key_vault_id = azurerm_key_vault.kv.id
}

data "azurerm_client_config" "current" {}

# 7. Azure App Service Plan and App Service for Metabase
resource "azurerm_service_plan" "appserviceplan" {
  name                = "az-llm-bank-metabase-plan-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "metabase_app" {
  name                = "az-llm-bank-metabase-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.appserviceplan.id

  site_config {
    always_on = false
    application_stack {
      docker_image     = "metabase/metabase"
      docker_image_tag = "latest"
    }
  }
}

# 8. Azure Function App
resource "azurerm_service_plan" "function_plan" {
  name                = "az-llm-bank-function-plan-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan
}

resource "azurerm_linux_function_app" "function_app" {
  name                = "az-llm-bank-function-${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  storage_account_name = azurerm_storage_account.storage.name
  storage_account_access_key = azurerm_storage_account.storage.primary_access_key
  service_plan_id     = azurerm_service_plan.function_plan.id

  site_config {
    application_stack {
       python_version = "3.9"
    }
  }
}

# 9. Azure Log Analytics Workspace
resource "azurerm_log_analytics_workspace" "loganalytics" {
  name                = "az-llm-bank-loganalytics-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}