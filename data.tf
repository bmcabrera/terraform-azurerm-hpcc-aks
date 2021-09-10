data "azurerm_advisor_recommendations" "advisor" {

  filter_by_category        = ["security", "cost"]
  filter_by_resource_groups = concat([module.resource_group.name], can(var.storage.account.storage_account_name) ? var.storage.resource_group_name : [])
}

data "http" "host_ip" {
  url = "http://ipv4.icanhazip.com"
}

data "azurerm_subscription" "current" {
}

data "azurerm_storage_account" "hpccsa" {
  count = can(var.storage.account.storage_account_name) ? 1 : 0

  name                = var.storage.storage_account_name
  resource_group_name = var.storage.resource_group_name
}
