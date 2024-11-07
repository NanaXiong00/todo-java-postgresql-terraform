output "AZURE_POSTGRESQL_ENDPOINT" {
  value     = module.postgresql.fqdn //AZURE_POSTGRESQL_FQDN
  sensitive = true
}

output "REACT_APP_WEB_BASE_URL" {
  value = "https://${module.web.resource_uri}"
}

output "API_BASE_URL" {
  value = var.useAPIM ? module.apimApi[0].SERVICE_API_URI : "https://${module.api.resource_uri}"
}

output "AZURE_LOCATION" {
  value = var.location
}

output "APPLICATIONINSIGHTS_CONNECTION_STRING" {
  value     = module.applicationinsights.connection_string
  sensitive = true
}

output "AZURE_KEY_VAULT_ENDPOINT" {
  value     = module.keyvault.uri
  sensitive = true
}