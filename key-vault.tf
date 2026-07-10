resource "azurerm_key_vault" "tfvars" {
  name                       = local.key_vault_name
  location                   = local.azure_location
  resource_group_name        = local.resource_group.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  enable_rbac_authorization  = local.key_vault_access_use_rbac_authorization
  purge_protection_enabled   = true

  dynamic "access_policy" {
    for_each = data.azuread_user.key_vault_access

    content {
      tenant_id = data.azurerm_client_config.current.tenant_id
      object_id = access_policy.value["object_id"]

      key_permissions = [
        "Create",
        "Get",
      ]

      secret_permissions = [
        "Set",
        "Get",
        "Delete",
        "Purge",
        "Recover",
        "List",
      ]
    }

  }

  network_acls {
    bypass                     = "AzureServices"
    default_action             = "Deny"
    ip_rules                   = length(local.key_vault_access_ipv4) > 0 ? local.key_vault_access_ipv4 : null
    virtual_network_subnet_ids = length(local.key_vault_access_subnet_ids) > 0 ? local.key_vault_access_subnet_ids : null
  }

  tags = local.tags

  lifecycle {
    ignore_changes = [
      access_policy,
      # network_acls[0].ip_rules
    ]
  }
}

resource "null_resource" "check_key_vault_secret_age_against_local_tfvars" {
  count = var.enable_tfvars_backup && local.enable_tfvars_file_age_check ? 1 : 0

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/check-key-vault-secret-age-against-local-tfvars.sh -v \"${azurerm_key_vault.tfvars.name}\" -s \"${local.resource_prefix}-tfvars\" -f ${local.tfvars_filename}"
  }

  triggers = {
    tfvar_file_md5 = filemd5(local.tfvars_filename)
  }
}

resource "azurerm_key_vault_secret" "tfvars" {
  count = var.enable_tfvars_backup ? 1 : 0

  name            = "${local.resource_prefix}-tfvars"
  value           = base64encode(file(local.tfvars_filename))
  key_vault_id    = azurerm_key_vault.tfvars.id
  content_type    = "text/plain+base64"
  expiration_date = local.year_from_now

  depends_on = [
    null_resource.check_key_vault_secret_age_against_local_tfvars
  ]

  lifecycle {
    ignore_changes = [
      value,
      expiration_date
    ]
  }

  tags = merge(local.tags, {
    ResourceType = "TfvarsBackupChunk"
  })

}

resource "azurerm_key_vault_secret" "tfvars_chunks" {
  for_each = var.enable_tfvars_backup ? {
    for idx, chunk in local.tfvars_content_chunks :
    format("%03d", idx + 1) => chunk
  } : {}

  name            = "${local.resource_prefix}-tfvars-${each.key}"
  value           = each.value
  key_vault_id    = azurerm_key_vault.tfvars.id
  content_type    = "text/plain+base64-part"
  expiration_date = local.year_from_now

  depends_on = [
    null_resource.check_key_vault_secret_age_against_local_tfvars
  ]

  tags = merge(local.tags, {
    ResourceType = "TfvarsBackupChunk"
  })

}