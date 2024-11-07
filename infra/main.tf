locals {
  tags                 = { azd-env-name : var.environment_name, spring-cloud-azure : true }
  sha                  = base64encode(sha256("${var.environment_name}${var.location}${data.azurerm_client_config.current.subscription_id}"))
  resource_token       = substr(replace(lower(local.sha), "[^A-Za-z0-9_]", ""), 0, 13)
  psql_connection_string_key = "AZURE-POSTGRESQL-URL"
  enable_telemetry = true
}
# ------------------------------------------------------------------------------------------------------
# Deploy resource Group
# ------------------------------------------------------------------------------------------------------
resource "azurecaf_name" "rg_name" {
  name          = var.environment_name
  resource_type = "azurerm_resource_group"
  random_length = 0
  clean_input   = true
}

resource "azurerm_resource_group" "rg" {
  name     = azurecaf_name.rg_name.result
  location = var.location

  tags = local.tags
}

resource "random_password" "password" {
  count            = 2
  length           = 32
  special          = true
  override_special = "_%@"
}

# ------------------------------------------------------------------------------------------------------
# Deploy application insights
# ------------------------------------------------------------------------------------------------------
module "applicationinsights" {
  source              = "Azure/avm-res-insights-component/azurerm"
  version             = "0.1.3"
  enable_telemetry    = local.enable_telemetry
  location            = var.location
  name                = "appi-${local.resource_token}"
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = module.loganalytics.resource_id
  tags                = azurerm_resource_group.rg.tags
  application_type    = "web"
}

module "dashboard" {
  source                  = "Azure/avm-res-portal-dashboard/azurerm"
  version                 = "0.1.0"
  enable_telemetry        = local.enable_telemetry
  location                = var.location
  name                    = "dash-${local.resource_token}"
  resource_group_name     = azurerm_resource_group.rg.name
  template_file_path      = "./dashboard.tpl"
  template_file_variables = {
    subscriptions_id         = data.azurerm_client_config.current.subscription_id
    resource_group_name      = azurerm_resource_group.rg.name
    applicationinsights_name = module.applicationinsights.name
  }
  tags = azurerm_resource_group.rg.tags
}

# ------------------------------------------------------------------------------------------------------
# Deploy log analytics
# ------------------------------------------------------------------------------------------------------
module "loganalytics" {
  source                                    = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version                                   = "0.4.1"
  enable_telemetry                          = local.enable_telemetry
  location                                  = var.location
  resource_group_name                       = azurerm_resource_group.rg.name
  name                                      = "log-${local.resource_token}"
  tags                                      = azurerm_resource_group.rg.tags
  log_analytics_workspace_retention_in_days = 30
  log_analytics_workspace_sku               = "PerGB2018"
}

# ------------------------------------------------------------------------------------------------------
# Deploy PostgreSQL
# ------------------------------------------------------------------------------------------------------
# module "postgresql" {
#   source         = "./modules/postgresql"
#   location       = var.location
#   rg_name        = azurerm_resource_group.rg.name
#   tags           = azurerm_resource_group.rg.tags
#   resource_token = local.resource_token
# }

module "postgresql" {
  source                 = "Azure/avm-res-dbforpostgresql-flexibleserver/azurerm"
  version                = "0.1.2"
  location               = var.location
  name                   = "psqlf-${local.resource_token}"
  resource_group_name    = azurerm_resource_group.rg.name
  enable_telemetry       = local.enable_telemetry
  administrator_login    = "psqladmin"
  administrator_password = random_password.password[0].result
  server_version         = 12
  sku_name               = "GP_Standard_D4s_v3"
  zone                   = 1
  public_network_access_enabled = true
  databases = {
    pgdb = {
      charset   = "UTF8"
      collation = "en_US.utf8"
      name      = "todo"
    }
  }
  tags = azurerm_resource_group.rg.tags 
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "firewall_rule" {
  name             = "AllowAllFireWallRule"
  server_id        = module.postgresql.resource_id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "255.255.255.255"
}

resource "azurerm_resource_deployment_script_azure_cli" "psql-script" {
  name                = "psql-script-${local.resource_token}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  version             = "2.40.0"
  retention_interval  = "PT1H"
  cleanup_preference  = "OnSuccess"
  timeout             = "PT5M"

  environment_variable {
    name              = "PSQLADMINNAME"
    value             = "psqladmin" //azurerm_postgresql_flexible_server.psql_server.administrator_login
  }
  environment_variable {
    name              = "PSQLADMINPASSWORD"
    value             = random_password.password[0].result
  }
  environment_variable {
    name              = "PSQLUSERNAME"
    value             = "psqluser"
  }
  environment_variable {
    name              = "PSQLUSERPASSWORD"
    value             = random_password.password[1].result
  }
  environment_variable {
    name              = "DBNAME"
    value             = "todo"
  }
  environment_variable {
    name              = "DBSERVER"
    value             = module.postgresql.fqdn
  }

  script_content = <<-EOT

      apk add postgresql-client

      cat << EOF > create_user.sql
      CREATE ROLE "$PSQLUSERNAME" WITH LOGIN PASSWORD '$PSQLUSERPASSWORD';
      GRANT ALL PRIVILEGES ON DATABASE $DBNAME TO "$PSQLUSERNAME";
      EOF

      psql "host=$DBSERVER user=$PSQLADMINNAME dbname=$DBNAME port=5432 password=$PSQLADMINPASSWORD sslmode=require" < create_user.sql
  EOT

  depends_on = [ module.postgresql.name ]
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service plan
# ------------------------------------------------------------------------------------------------------
module "appserviceplan" {
  source                 = "Azure/avm-res-web-serverfarm/azurerm"
  version                = "0.2.0"
  enable_telemetry       = local.enable_telemetry
  name                   = "plan-${local.resource_token}"
  resource_group_name    = azurerm_resource_group.rg.name
  location               = var.location
  os_type                = "Linux"
  tags                   = azurerm_resource_group.rg.tags
  sku_name               = "B3"
  worker_count           = 1
  zone_balancing_enabled = false
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service web app
# ------------------------------------------------------------------------------------------------------
module "web" {
  source                   = "Azure/avm-res-web-site/azurerm"
  version                  = "0.10.0"
  enable_telemetry         = local.enable_telemetry
  name                     = "app-web-${local.resource_token}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  https_only               = true
  tags                     = merge(local.tags, { azd-service-name : "web" })
  kind                     = "webapp"
  os_type                  = "Linux"
  service_plan_resource_id = module.appserviceplan.resource_id
  app_settings      = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "false"
  }
  site_config              = {
    always_on         = true
    use_32_bit_worker = false
    ftps_state        = "FtpsOnly"
    app_command_line  = "pm2 serve /home/site/wwwroot --no-daemon --spa"
    application_stack = {
      node = {
        current_stack = "node"
        node_version  = "20-lts"
      }
    }
    health_check_path = ""
    logs = {
      app_service_logs = {
        http_logs = {
          config1 = {
            file_system = {
              retention_in_days = 1
              retention_in_mb   = 35
            }
          }
        }
        application_logs = {
          config1 = {
            file_system_level = "Verbose"
          }
        }
        detailed_error_messages = true
        failed_request_tracing  = true
      }
    }
  }
}

# This is a temporary solution until the azurerm provider supports the basicPublishingCredentialsPolicies resource type
resource "null_resource" "webapp_basic_auth_disable" {
  triggers = {
    account = module.web.name
  }

  provisioner "local-exec" {
    command = "az resource update --resource-group ${azurerm_resource_group.rg.name} --name ftp --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies --parent sites/${module.web.name} --set properties.allow=false && az resource update --resource-group ${azurerm_resource_group.rg.name} --name scm --namespace Microsoft.Web --resource-type basicPublishingCredentialsPolicies --parent sites/${module.web.name} --set properties.allow=false"
  }
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service api
# ------------------------------------------------------------------------------------------------------
module "api" {
  source              = "Azure/avm-res-web-site/azurerm"
  version             = "0.10.0"
  enable_telemetry    = local.enable_telemetry
  name                = "app-api-${local.resource_token}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  https_only          = true
  tags                = merge(local.tags, { "azd-service-name" : "api" })
  kind                = "webapp" 
  os_type             = "Linux"
  service_plan_resource_id = module.appserviceplan.resource_id
  managed_identities  = {
    system_assigned = true
  }
  app_settings        = {
    "SCM_DO_BUILD_DURING_DEPLOYMENT"        = "true"
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = module.applicationinsights.connection_string
    "AZURE_KEY_VAULT_ENDPOINT"              = module.keyvault.uri
    "JAVA_OPTS"                             = "-Djdk.attach.allowAttachSelf=true"
  }
  site_config         = {
    always_on         = true
    ftps_state        = "FtpsOnly"
    app_command_line  = ""
    application_stack = {
      java = {
        current_stack = "java"
        java_version  = "17"
        java_server  = "JAVA"
        java_server_version = "17"
      }
    }
    logs = {
      app_service_logs = {
        http_logs = {
          config1 = {
            file_system = {
              retention_in_days = 1
              retention_in_mb   = 35
            }
          }
        }
        application_logs = {
          config1 = {
            file_system_level = "Verbose"
          }
        }
        detailed_error_messages = true
        failed_request_tracing  = true
      }
    }    
  }
}

# ------------------------------------------------------------------------------------------------------
# Deploy key vault
# ------------------------------------------------------------------------------------------------------
module "keyvault" {
  source                         = "Azure/avm-res-keyvault-vault/azurerm"
  version                        = "0.9.1"
  enable_telemetry               = local.enable_telemetry
  name                           = "kv-${local.resource_token}"
  location                       = var.location
  resource_group_name            = azurerm_resource_group.rg.name
  tags                           = azurerm_resource_group.rg.tags
  tenant_id                      = data.azurerm_client_config.current.tenant_id
  public_network_access_enabled  = true
  purge_protection_enabled       = false
  sku_name                       = "standard"

  secrets = {
    psql_connection_string_key = {
      name = local.psql_connection_string_key
    }
    AZURE-POSTGRESQL-USERNAME = {
      name = "AZURE-POSTGRESQL-USERNAME"
    }
    AZURE-POSTGRESQL-PASSWORD = {
      name = "AZURE-POSTGRESQL-PASSWORD"
    }
  }
  secrets_value = {
    psql_connection_string_key = "jdbc:postgresql://${module.postgresql.fqdn}:5432/todo?sslmode=require" //module.postgresql.AZURE_POSTGRESQL_SPRING_DATASOURCE_URL //
    AZURE-POSTGRESQL-USERNAME = "psqladmin"
    AZURE-POSTGRESQL-PASSWORD = random_password.password[0].result //module.postgresql.AZURE_POSTGRESQL_PASSWORD //
  }
  role_assignments = {
    user = {
      role_definition_id_or_name = "Key Vault Administrator"
      principal_id               = var.principal_id
    }
    api = {
      role_definition_id_or_name = "Key Vault Administrator"
      principal_id               = module.api.identity_principal_id
    }
  }
  wait_for_rbac_before_secret_operations = {
    create = "60s"
  }
  network_acls = null
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service apim
# ------------------------------------------------------------------------------------------------------
module "apim" {
  count                     = var.useAPIM ? 1 : 0
  source                    = "./modules/apim"
  name                      = "apim-${local.resource_token}"
  location                  = var.location
  rg_name                   = azurerm_resource_group.rg.name
  tags                      = merge(local.tags, { "azd-service-name" : var.environment_name })
  application_insights_name = module.applicationinsights.name
  sku                       = "Consumption"
}

# ------------------------------------------------------------------------------------------------------
# Deploy app service apim-api
# ------------------------------------------------------------------------------------------------------
module "apimApi" {
  count                    = var.useAPIM ? 1 : 0
  source                   = "./modules/apim-api"
  name                     = module.apim[0].APIM_SERVICE_NAME
  rg_name                  = azurerm_resource_group.rg.name
  web_front_end_url        = module.web.resource_uri
  api_management_logger_id = module.apim[0].API_MANAGEMENT_LOGGER_ID
  api_name                 = "todo-api"
  api_display_name         = "Simple Todo API"
  api_path                 = "todo"
  api_backend_url          = module.api.resource_uri
}