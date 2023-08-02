terraform {
  required_providers {
    azapi = {
      source = "Azure/azapi"
    }
  }
  backend "azurerm" {
    resource_group_name  = "state_rg"
    storage_account_name = "state_sa"
    container_name       = "state_cn"
    access_key           = "state_ak"
    key                  = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

provider "azapi" {
}

data "azurerm_client_config" "current" {}

# initial properties
locals {
  tags = {
    "Owner"         = "aleksei.trifonov@dpc.vic.gov.au"
    "Client"        = "VIC"
    "Environment"   = "UAT"
  }
  resource_group_name             = "uat-ocr"
  prefix                          = "uatocr"
  location                        = "Australia East"
  log_days                        = "30"
  registry                        = "devocrregistry.azurecr.io"
  back_image                      = "coolforms"
  back_allow_external             = true
  back_allow_insecure             = false
  back_target_port                = 5000
  back_cpu                        = 0.5
  back_memory                     = "1Gi"
  back_modelid                    = "neural_v1_9"
  back_min_replicas               = 1
  back_max_replicas               = 1
  back_allowed_ip1                = "149.96.92.248"
  back_allowed_ip2                = "149.96.88.248"
  back_allowed_ip3                = "103.23.64.8/29"
  back_allowed_ip4                = "103.23.65.8/29"
  front_image                     = "docai"
  front_allow_external            = true
  front_allow_insecure            = false
  front_target_port               = 80
  front_cpu                       = 0.5
  front_memory                    = "1Gi"
  front_min_replicas              = 1
  front_max_replicas              = 1
  dapr_keyvault_component         = "form-recognizer-secret-store"
  dapr_blobstorage_component      = "coolfiles"
  storage_mb                      = 5120
  db_administrator_login          = "user"
  ui_username                     = "admin@servian.com"
  sn_username                     = "admin@servian.com"
}

resource "azurerm_resource_group" "terraform" {
  name     = local.resource_group_name
  location = local.location
  tags     = local.tags
  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_log_analytics_workspace" "terraform" {
  name                = "${local.prefix}workspace"
  location            = local.location
  resource_group_name = local.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = local.log_days
  tags                = local.tags
  lifecycle {
    ignore_changes = [tags]
  }
  depends_on = [azurerm_resource_group.terraform]
}

resource "azurerm_container_app_environment" "terraform" {
  name                       = "${local.prefix}environment"
  location                   = local.location
  resource_group_name        = local.resource_group_name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.terraform.id
  lifecycle {
    ignore_changes = [tags]
  }
  depends_on = [azurerm_resource_group.terraform]
}

resource "azurerm_container_registry" "terraform" {
  name                   = "${local.prefix}registry"
  resource_group_name    = local.resource_group_name
  location               = local.location
  sku                    = "Standard"
  admin_enabled          = false
  anonymous_pull_enabled = true #
  tags = local.tags
  lifecycle {
    ignore_changes = [tags]
  }
  depends_on = [azurerm_resource_group.terraform]
}

resource "azurerm_user_assigned_identity" "registry" {
  name                = "${azurerm_container_registry.terraform.name}identity"
  resource_group_name = local.resource_group_name
  location            = local.location
  tags                = local.tags
  lifecycle {
    ignore_changes = [tags]
  }
  depends_on = [azurerm_container_registry.terraform]
}

resource "azurerm_role_assignment" "registry" {
  scope                = azurerm_container_registry.terraform.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.registry.principal_id
  depends_on = [azurerm_container_registry.terraform]
}

resource "azurerm_cognitive_account" "terraform" {
  name                = "${local.prefix}cognitiveaccount"
  resource_group_name = local.resource_group_name
  location            = local.location
  kind                = "FormRecognizer"
  sku_name            = "S0"
  tags                = local.tags
  lifecycle {
    ignore_changes = [tags]
  }
  depends_on = [azurerm_resource_group.terraform]
}

resource "azurerm_key_vault" "terraform" {
  name                         = "${local.prefix}vault"
  resource_group_name          = local.resource_group_name
  location                     = local.location
  enabled_for_disk_encryption  = true
  tenant_id                    = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days   = 7
  purge_protection_enabled     = false #
  sku_name = "standard"
  tags = local.tags
  lifecycle {
    ignore_changes = [tags]
  }
  depends_on = [azurerm_resource_group.terraform]
}

resource "azurerm_user_assigned_identity" "vault" {
  name                = "${azurerm_key_vault.terraform.name}identity"
  resource_group_name = local.resource_group_name
  location            = local.location
  tags                = local.tags
  lifecycle {
    ignore_changes = [tags]
  }
  depends_on = [azurerm_key_vault.terraform]
}

resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.terraform.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Create",
    "Get"
  ]

  secret_permissions = [
    "Set",
    "Get",
    "Delete",
    "Purge",
    "Recover",
    "List"
  ]
  depends_on = [azurerm_key_vault.terraform]
}

resource "azurerm_key_vault_access_policy" "vault" {
  key_vault_id = azurerm_key_vault.terraform.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.vault.principal_id

  key_permissions = [
    "Get"
  ]

  secret_permissions = [
    "Get"
  ]
  depends_on = [azurerm_key_vault.terraform]
}

resource "random_password" "jwtsecretkey" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>"
}

resource "random_password" "apikey" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>"
}

resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>"
}

resource "random_password" "snpassword" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>"
}

resource "azurerm_key_vault_secret" "endpoint" {
  name         = "endpoint"
  value        = "https://formrecognizer-ocr-dev-sandbox.cognitiveservices.azure.com"
  key_vault_id = azurerm_key_vault.terraform.id
  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "key" {
  name         = "key"
  value        = "b8567b38e9804234adccf56ce1c980df"
  key_vault_id = azurerm_key_vault.terraform.id
  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "dburi" {
  name         = "dburi"
  value        = "postgresql+psycopg2://${local.db_administrator_login}@${local.prefix}db:${random_password.db_administrator_password.result}@${local.prefix}db.postgres.database.azure.com:5432/${local.prefix}?sslmode=require"
  key_vault_id = azurerm_key_vault.terraform.id
  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "jwtsecretkey" {
  name         = "jwtsecretkey"
  value        = random_password.jwtsecretkey.result
  key_vault_id = azurerm_key_vault.terraform.id
  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "apikey" {
  name         = "apikey"
  value        = random_password.apikey.result
  key_vault_id = azurerm_key_vault.terraform.id
  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "username" {
  name         = "username"
  value        = local.ui_username
  key_vault_id = azurerm_key_vault.terraform.id
  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "password" {
  name         = "password"
  value        = random_password.password.result
  key_vault_id = azurerm_key_vault.terraform.id
  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "snusername" {
  name         = "snusername"
  value        = local.sn_username
  key_vault_id = azurerm_key_vault.terraform.id
  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_key_vault_secret" "snpassword" {
  name         = "snpassword"
  value        = random_password.snpassword.result
  key_vault_id = azurerm_key_vault.terraform.id
  depends_on = [azurerm_key_vault_access_policy.terraform]
}

resource "azurerm_storage_account" "terraform" {
  name                            = "${local.prefix}storageaccount"
  resource_group_name             = local.resource_group_name
  location                        = local.location
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  allow_nested_items_to_be_public = "false"
  tags                            = local.tags
  lifecycle {
    ignore_changes = [tags]
  }
  depends_on = [azurerm_resource_group.terraform]
}

resource "azurerm_storage_container" "terraform" {
  name                  = "${local.prefix}storagecontainer"
  storage_account_name  = azurerm_storage_account.terraform.name
  container_access_type = "private"
  depends_on = [azurerm_storage_account.terraform]
}

resource "azurerm_user_assigned_identity" "storageaccount" {
  name                = "${azurerm_storage_account.terraform.name}identity"
  resource_group_name = local.resource_group_name
  location            = local.location
  tags                = local.tags
  lifecycle {
    ignore_changes = [tags]
  }
  depends_on = [azurerm_storage_account.terraform]
}

resource "azurerm_role_assignment" "storageaccount" {
  scope                = azurerm_storage_account.terraform.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.storageaccount.principal_id
  depends_on = [azurerm_storage_account.terraform]
}

resource "azapi_resource" "back" {
  type      = "Microsoft.App/containerApps@2022-06-01-preview"
  name      = "${local.prefix}back"
  parent_id = azurerm_resource_group.terraform.id
  location  = local.location
  lifecycle {
    ignore_changes = [tags]
  }

  identity {
    type = "UserAssigned"
    identity_ids = sort([
      azurerm_user_assigned_identity.registry.id,
      azurerm_user_assigned_identity.storageaccount.id,
      azurerm_user_assigned_identity.vault.id
    ])
  }
  
  body = jsonencode({
    properties: {
      managedEnvironmentId = azurerm_container_app_environment.terraform.id
      configuration = {
        ingress = {
          external = local.back_allow_external
          targetPort = local.back_target_port
          allowInsecure = local.back_allow_insecure
          ipSecurityRestrictions = [{
            name = "1"
            ipAddressRange = local.back_allowed_ip1,
            action = "Allow"
          },
          {
            name = "2"
            ipAddressRange = local.back_allowed_ip2,
            action = "Allow"
          },
          {
            name = "3"
            ipAddressRange = local.back_allowed_ip3,
            action = "Allow"
          },
          {
            name = "4"
            ipAddressRange = local.back_allowed_ip4,
            action = "Allow"
          }]
	      }
        dapr = {
          appId   = "${local.prefix}back"
          appPort = local.back_target_port
          enabled = true
        }
      }
      template = {
        containers = [{
          name = "${local.prefix}back"
          image = "${local.registry}/${local.back_image}" #
          resources = {
            cpu = local.back_cpu
            memory = local.back_memory
          }
          env = [{
            name = "modelid"
            value = local.back_modelid
          }]
        }]
        scale = {
          minReplicas = local.back_min_replicas
          maxReplicas = local.back_max_replicas
        }
      }
    }
  })
  depends_on = [
    azurerm_storage_container.terraform,
    azurerm_container_app_environment.terraform,
    azurerm_container_registry.terraform
    # postgresql
    # vault
  ]
}

resource "azapi_resource" "front" {
  type      = "Microsoft.App/containerApps@2022-06-01-preview"
  name      = "${local.prefix}front"
  parent_id = azurerm_resource_group.terraform.id
  location  = local.location
  lifecycle {
    ignore_changes = [tags]
  }

  identity {
    type = "UserAssigned"
    identity_ids = sort([
      azurerm_user_assigned_identity.registry.id,
    ])
  }
  
  body = jsonencode({
    properties: {
      managedEnvironmentId = azurerm_container_app_environment.terraform.id
      configuration = {
        ingress = {
          external = local.front_allow_external
          targetPort = local.front_target_port
          allowInsecure = local.front_allow_insecure
	      }
      }
      template = {
        containers = [{
          name = "${local.prefix}front"
          image = "${local.registry}/${local.front_image}" #
          resources = {
            cpu = local.front_cpu
            memory = local.front_memory
          }
          env = [{
            name = "REACT_APP_ENDPOINT"
              value = "http://uatocrback:5000"
          }]
        }]
        scale = {
          minReplicas = local.front_min_replicas
          maxReplicas = local.front_max_replicas
        }
      }
    }
  })
  depends_on = [
    azurerm_container_app_environment.terraform,
    azapi_resource.back,
    azurerm_container_registry.terraform
  ]
}

resource "azapi_resource" "keyvault" {
  type      = "Microsoft.App/managedEnvironments/daprComponents@2022-03-01"
  parent_id = azurerm_container_app_environment.terraform.id
  name      = local.dapr_keyvault_component
  body      = jsonencode({
    properties = {
      componentType = "secretstores.azure.keyvault"
      version       = "v1"
      metadata = [{
        name        = "vaultName"
        value       = azurerm_key_vault.terraform.name
      },
      {
        name        = "azureClientId"
        value       = azurerm_user_assigned_identity.vault.client_id
	    }]
      scopes = [azapi_resource.back.name]
    }
  })
  depends_on = [
    azurerm_container_app_environment.terraform
  ]
}

resource "azapi_resource" "blobstorage" {
  type      = "Microsoft.App/managedEnvironments/daprComponents@2022-03-01"
  parent_id = azurerm_container_app_environment.terraform.id
  name      = local.dapr_blobstorage_component
  body = jsonencode({
    properties = {
      componentType = "state.azure.blobstorage"
      version       = "v1"
      metadata = [{
        name        = "accountName"
        value       = azurerm_storage_account.terraform.name
      },
      {
        name        = "containerName"
        value       = azurerm_storage_container.terraform.name
      },
      {
        name        = "azureClientId"
        value       = azurerm_user_assigned_identity.storageaccount.client_id
      }]
      scopes = [azapi_resource.back.name]
    }
  })
  depends_on = [
    azurerm_container_app_environment.terraform
  ]
}

resource "random_password" "db_administrator_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>"
}

module "postgresql" {
  tags = local.tags
  source                        = "Azure/postgresql/azurerm"
  resource_group_name           = local.resource_group_name
  location                      = local.location
  server_name                   = "${local.prefix}db"
  sku_name                      = "GP_Gen5_2"
  storage_mb                    = local.storage_mb
  auto_grow_enabled             = false
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  administrator_login           = local.db_administrator_login
  administrator_password        = random_password.db_administrator_password.result
  server_version                = "11"
  ssl_enforcement_enabled       = true
  public_network_access_enabled = true #
  db_names                      = [local.prefix]
  db_charset                    = "UTF8"
  db_collation                  = "English_United States.1252"
  postgresql_configurations     = {
    backslash_quote = "safe_encoding"
  }
  depends_on = [azurerm_resource_group.terraform]
}