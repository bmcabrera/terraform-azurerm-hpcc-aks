resource "random_string" "random" {
  length  = 43
  upper   = false
  number  = false
  special = false
}

resource "random_password" "admin" {
  length  = 6
  special = true
}

module "subscription" {
  source          = "github.com/Azure-Terraform/terraform-azurerm-subscription-data.git?ref=v1.0.0"
  subscription_id = data.azurerm_subscription.current.subscription_id
}

module "naming" {
  source = "github.com/Azure-Terraform/example-naming-template.git?ref=v1.0.0"
}

module "metadata" {
  source = "github.com/Azure-Terraform/terraform-azurerm-metadata.git?ref=v1.5.1"

  naming_rules = module.naming.yaml

  market              = var.metadata.market
  location            = var.resource_group.location
  sre_team            = var.metadata.sre_team
  environment         = var.metadata.environment
  product_name        = var.metadata.product_name
  business_unit       = var.metadata.business_unit
  product_group       = var.metadata.product_group
  subscription_type   = var.metadata.subscription_type
  resource_group_type = var.metadata.resource_group_type
  subscription_id     = module.subscription.output.subscription_id
  project             = var.metadata.project
}

module "resource_group" {
  source = "github.com/Azure-Terraform/terraform-azurerm-resource-group.git?ref=v2.0.0"

  unique_name = var.resource_group.unique_name
  location    = var.resource_group.location
  names       = local.names
  tags        = local.tags
}

module "virtual_network" {
  source = "github.com/Azure-Terraform/terraform-azurerm-virtual-network.git?ref=v2.9.0"

  naming_rules = var.disable_naming_conventions ? "" : module.naming.yaml

  resource_group_name = module.resource_group.name
  location            = var.resource_group.location
  names               = local.names
  tags                = local.tags

  address_space = ["10.1.0.0/22"]

  subnets = {
    iaas-private = {
      cidrs                   = ["10.1.0.0/24"]
      route_table_association = "default"
      configure_nsg_rules     = false
      service_endpoints       = ["Microsoft.Storage"]
    }
    iaas-public = {
      cidrs                                          = ["10.1.1.0/24"]
      route_table_association                        = "default"
      configure_nsg_rules                            = false
      enforce_private_link_endpoint_network_policies = true
      enforce_private_link_service_network_policies  = true
    }
  }

  route_tables = {
    default = {
      disable_bgp_route_propagation = true
      routes = {
        internet = {
          address_prefix = "0.0.0.0/0"
          next_hop_type  = "Internet"
        }
        local-vnet = {
          address_prefix = "10.1.0.0/22"
          next_hop_type  = "vnetlocal"
        }
      }
    }
  }
}

resource "azurerm_private_endpoint" "pe" {
  count = can(var.storage.account.storage_account_name) ? 1 : 0

  name                = "sa_endpoint"
  location            = var.resource_group.location
  resource_group_name = module.resource_group.name
  subnet_id           = module.virtual_network.subnets["iaas-public"].id

  private_service_connection {
    name                           = "sa_privateserviceconnection"
    private_connection_resource_id = data.azurerm_storage_account.hpccsa[0].id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }
}

module "kubernetes" {
  source = "github.com/Azure-Terraform/terraform-azurerm-kubernetes.git?ref=v4.2.1"

  cluster_name        = local.cluster_name
  location            = var.resource_group.location
  names               = local.names
  tags                = local.tags
  resource_group_name = module.resource_group.name
  identity_type       = "UserAssigned" # Allowed values: UserAssigned or SystemAssigned

  rbac = {
    enabled        = false
    ad_integration = false
  }

  network_plugin         = "azure"
  configure_network_role = true

  virtual_network = {
    subnets = {
      private = {
        id = module.virtual_network.subnets["iaas-private"].id
      }
      public = {
        id = module.virtual_network.subnets["iaas-public"].id
      }
    }
    route_table_id = module.virtual_network.route_tables["default"].id
  }

  node_pools = var.node_pools

  default_node_pool = "system" //name of the sub-key, which is the default node pool.

  api_server_authorized_ip_ranges = local.access_map_cidr

}

resource "kubernetes_secret" "sa_secret" {
  count = can(var.storage.account.storage_account_name) ? 1 : 0

  metadata {
    name = "azure-secret"
  }

  data = {
    "azurestorageaccountname" = var.storage.storage_account_name
    "azurestorageaccountkey"  = data.azurerm_storage_account.hpccsa[0].primary_access_key
  }

  type = "Opaque"
}

resource "helm_release" "hpcc" {
  count = var.disable_helm ? 0 : 1

  name                       = var.hpcc.name
  chart                      = "hpcc"
  repository                 = "https://hpcc-systems.github.io/helm-chart/"
  version                    = var.hpcc.version
  create_namespace           = true
  namespace                  = try(var.hpcc.namespace, terraform.workspace)
  atomic                     = try(var.hpcc.atomic, null)
  recreate_pods              = try(var.hpcc.recreate_pods, null)
  cleanup_on_fail            = try(var.hpcc.cleanup_on_fail, null)
  disable_openapi_validation = try(var.hpcc.disable_openapi_validation, null)
  wait                       = try(var.hpcc.wait, null)
  dependency_update          = try(var.hpcc.dependency_update, null)
  timeout                    = try(var.hpcc.timeout, 900)
  wait_for_jobs              = try(var.hpcc.wait_for_jobs, null)
  lint                       = try(var.hpcc.lint, null)

  values = concat(
                   # var.expose_services ? [file("${path.root}/values/esp.yaml")] : [],
                   can(var.storage.account.storage_account_name) ? [file("${path.root}/values/values-retained-azurefile.yaml")] : [],
                   try([for v in var.hpcc.values : file(v)], [])
  )

  dynamic "set" {
    for_each = var.image_root != "" && var.image_root != null ? [1] : []
    content {
      name  = "global.image.root"
      value = var.image_root
    }
  }

  dynamic "set" {
    for_each = var.image_name != "" && var.image_name != null ? [1] : []
    content {
      name  = "global.image.name"
      value = var.image_name
    }
  }

  dynamic "set" {
    for_each = var.image_version != "" && var.image_version != null ? [1] : []
    content {
      name  = "global.image.version"
      value = var.image_version
    }

  }

  depends_on = [helm_release.storage]
}

resource "helm_release" "elk" {
  count = var.disable_helm || !var.elk.enable ? 0 : 1

  name                       = var.elk.name
  namespace                  = try(var.hpcc.namespace, terraform.workspace)
  chart                      = local.elk_chart
  values                     = concat(try([for v in var.elk.values : file(v)], []), var.expose_services ? [file("${path.root}/values/elk.yaml")] : [])
  create_namespace           = true
  atomic                     = try(var.elk.atomic, null)
  recreate_pods              = try(var.elk.recreate_pods, null)
  cleanup_on_fail            = try(var.elk.cleanup_on_fail, null)
  disable_openapi_validation = try(var.elk.disable_openapi_validation, null)
  wait                       = try(var.elk.wait, null)
  dependency_update          = try(var.elk.dependency_update, null)
  timeout                    = try(var.elk.timeout, 600)
  wait_for_jobs              = try(var.elk.wait_for_jobs, null)
  lint                       = try(var.elk.lint, null)
}

resource "helm_release" "storage" {
  count = var.disable_helm ? 0 : 1

  name                       = "azstorage"
  chart                      = local.storage_chart
  values                     = concat(can(var.storage.account.storage_account_name) ? [file("${path.root}/values/hpcc-azurefile.yaml")] : [], try([for v in var.storage.values : file(v)], []))
  create_namespace           = true
  namespace                  = try(var.hpcc.namespace, terraform.workspace)
  atomic                     = try(var.storage.atomic, null)
  recreate_pods              = try(var.storage.recreate_pods, null)
  cleanup_on_fail            = try(var.storage.cleanup_on_fail, null)
  disable_openapi_validation = try(var.storage.disable_openapi_validation, null)
  wait                       = try(var.storage.wait, null)
  dependency_update          = try(var.storage.dependency_update, null)
  timeout                    = try(var.storage.timeout, 600)
  wait_for_jobs              = try(var.storage.wait_for_jobs, null)
  lint                       = try(var.storage.lint, null)
}

resource "azurerm_public_ip" "public_ip" {
  count = can(var.storage.account.storage_account_name) ? 1 : 0

  name                = "private_link_public_ip"
  sku                 = "Standard"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  allocation_method   = "Static"
}

resource "azurerm_lb" "private_link_lb" {
  count = can(var.storage.account.storage_account_name) ? 1 : 0

  name                = "private_link_lb"
  sku                 = "Standard"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name

  frontend_ip_configuration {
    name                 = azurerm_public_ip.public_ip[0].name
    public_ip_address_id = azurerm_public_ip.public_ip[0].id
  }
}

resource "azurerm_private_link_service" "private_link_svc" {
  count = can(var.storage.account.storage_account_name) ? 1 : 0

  name                = "sa_privatelink"
  resource_group_name = module.resource_group.name
  location            = module.resource_group.location

  auto_approval_subscription_ids              = [data.azurerm_subscription.current.subscription_id]
  visibility_subscription_ids                 = [data.azurerm_subscription.current.subscription_id]
  load_balancer_frontend_ip_configuration_ids = [azurerm_lb.private_link_lb[0].frontend_ip_configuration.0.id]

  nat_ip_configuration {
    name                       = "primary"
    private_ip_address         = "10.1.1.17"
    private_ip_address_version = "IPv4"
    subnet_id                  = module.virtual_network.subnets["iaas-public"].id
    primary                    = true
  }

  nat_ip_configuration {
    name                       = "secondary"
    private_ip_address         = "10.1.1.18"
    private_ip_address_version = "IPv4"
    subnet_id                  = module.virtual_network.subnets["iaas-public"].id
    primary                    = false
  }
}

resource "azurerm_network_security_rule" "ingress_internet" {
  count = var.expose_services ? 1 : 0

  name                        = "Allow_Internet_Ingress"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["8010", "8002", "5601"]
  source_address_prefixes     = values(local.access_map_bare)
  destination_address_prefix  = "*"
  resource_group_name         = module.virtual_network.subnets["iaas-public"].resource_group_name
  network_security_group_name = module.virtual_network.subnets["iaas-public"].network_security_group_name
}


resource "null_resource" "az" {
  count = var.auto_connect ? 1 : 0

  provisioner "local-exec" {
    command     = local.az_command
    interpreter = local.is_windows_os ? ["PowerShell", "-Command"] : ["/bin/bash", "-c"]
  }

  triggers = { kubernetes_id = module.kubernetes.id } //must be run after the Kubernetes cluster is deployed.
}
