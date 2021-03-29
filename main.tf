variable "subscription_id" {
  default = " "
}

#############
# Providers #
#############

provider "azurerm" {
  version = ">=2.0.0"
  subscription_id = var.subscription_id
  features {}
}

provider "helm" {
  alias = "aks"
  kubernetes {
    host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
  }
}

provider "kubernetes" {
  load_config_file = "false"
  host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
}

#####################
# Pre-Built Modules #
#####################

module "subscription" {
  source = "github.com/Azure-Terraform/terraform-azurerm-subscription-data.git?ref=v1.0.0"
  subscription_id = var.subscription_id
}

module "rules" {
  source = "git@github.com:openrba/python-azure-naming.git?ref=tf"
}

module "metadata"{
  source = "github.com/Azure-Terraform/terraform-azurerm-metadata.git?ref=v1.0.0"

  naming_rules = module.rules.yaml
  
  market              = "us"
  project             = "acig"
  location            = "useast2"
  sre_team            = "ccoe"
  environment         = "sandbox"
  product_name        = "poc"
  business_unit       = "iog"
  product_group       = "poc"
  subscription_id     = module.subscription.output.subscription_id
  subscription_type   = "nonprod"
  resource_group_type = "app"
}

module "resource_group" {
  source = "github.com/Azure-Terraform/terraform-azurerm-resource-group.git?ref=v1.0.0"
  
  location = module.metadata.location
  names    = module.metadata.names
  tags     = module.metadata.tags
}

# Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "${module.metadata.names.product_group}-${module.metadata.names.subscription_type}-${module.metadata.names.location}-vnet"
  location            = module.resource_group.location
  resource_group_name = module.resource_group.name
  address_space       = ["192.168.0.0/16"]
  tags                = module.metadata.tags
}

resource "azurerm_subnet" "appgateway" {
  name                 = "azure-appgateway-subnet"
  resource_group_name  = module.resource_group.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["192.168.123.0/27"]
}

resource "azurerm_subnet" "aks" {
  name                 = "iaas-outbound-subnet"
  resource_group_name  = module.resource_group.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["192.168.128.0/17"]
}

##############
# Kubernetes #
##############
locals {
  cluster_name = "aks-${module.metadata.names.resource_group_type}-${module.metadata.names.product_name}-${module.metadata.names.environment}-${module.metadata.names.location}"
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                 = local.cluster_name
  location             = module.resource_group.location
  resource_group_name  = module.resource_group.name
  #node_resource_group  = module.resource_group.name
  dns_prefix           = "${module.metadata.names.product_name}-${module.metadata.names.environment}-${module.metadata.names.location}"

  kubernetes_version = "1.18.4"
  
  network_profile {
    network_plugin     = "azure"
    dns_service_ip     = "10.0.0.10"
    docker_bridge_cidr = "172.17.0.1/16"
    service_cidr       = "10.0.0.0/16"
  }

  default_node_pool {
    name                = "default"
    vm_size             = "Standard_D2s_v3"
    enable_auto_scaling = "true"
    node_count          = 1
    min_count           = 1
    max_count           = 5
    availability_zones  = [1,2,3]

    vnet_subnet_id = azurerm_subnet.aks.id
  }

  addon_profile {
    kube_dashboard {
      enabled = true
    }
  }

  identity {
      type = "SystemAssigned"
  }
}

# Pod Identity
module "aad_pod_identity" {
  source = "github.com/Azure-Terraform/terraform-azurerm-kubernetes.git//aad-pod-identity?ref=v1.2.0"
  providers = { helm = helm.aks }

  helm_chart_version = "2.0.0"
  node_resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
  additional_scopes        = [module.resource_group.id]
  principal_id =azurerm_kubernetes_cluster.aks.kubelet_identity.0.object_id
}

#######################
# Application Gateway #
#######################

resource "azurerm_public_ip" "appgw" {
  name                = "${module.resource_group.name}-pip"
  resource_group_name = module.resource_group.name
  location            = module.metadata.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "network" {
  name                = "${module.resource_group.name}-appgw"
  resource_group_name = module.resource_group.name
  location            = module.metadata.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }
  
  gateway_ip_configuration {
    name      = "${module.resource_group.name}-appgw-ip-config"
    subnet_id = azurerm_subnet.appgateway.id
  }

  frontend_port {
    name = "${module.resource_group.name}-appgw-frontend"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "${module.resource_group.name}-appgw-frontend-config"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  backend_address_pool {
    name = "${module.resource_group.name}-appgw-pool"
  }

  backend_http_settings {
    name                  = "${module.resource_group.name}-appgw-settings-default"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  request_routing_rule {
    name                       = "${module.resource_group.name}-rqrt"
    rule_type                  = "Basic"
    http_listener_name         = "${module.resource_group.name}-appgw-frontend-listener"
    backend_address_pool_name  = "${module.resource_group.name}-appgw-pool"
    backend_http_settings_name = "${module.resource_group.name}-appgw-settings-default"
  }

  http_listener {
    name                           = "${module.resource_group.name}-appgw-frontend-listener"
    frontend_ip_configuration_name = "${module.resource_group.name}-appgw-frontend-config"
    frontend_port_name             = "${module.resource_group.name}-appgw-frontend"
    protocol                       = "Http"
  }

  # Ignore changes by Kubernetes (AGIC)
  lifecycle {
    ignore_changes = [
      tags,
      ssl_certificate,
      trusted_root_certificate,
      frontend_port,
      backend_address_pool,
      backend_http_settings,
      http_listener,
      url_path_map,
      request_routing_rule,
      probe,
      redirect_configuration,
      ssl_policy,
    ]
  }

}

# Managed Identity
resource "azurerm_user_assigned_identity" "ingress" {
  resource_group_name = module.resource_group.name
  location            = module.metadata.location

  name = "${module.resource_group.name}-mi"
}

# Role Assignments
resource "azurerm_role_assignment" "ra1" {
  scope                = azurerm_subnet.appgateway.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.ingress.principal_id
  depends_on = [azurerm_user_assigned_identity.ingress, azurerm_kubernetes_cluster.aks]
}

resource "azurerm_role_assignment" "ra2" {
  scope                = azurerm_user_assigned_identity.ingress.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity.0.object_id
  depends_on = [azurerm_user_assigned_identity.ingress, azurerm_kubernetes_cluster.aks]
}

resource "azurerm_role_assignment" "ra3" {
  scope                = azurerm_application_gateway.network.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.ingress.principal_id
  depends_on = [azurerm_user_assigned_identity.ingress, azurerm_application_gateway.network]
}

resource "azurerm_role_assignment" "ra4" {
  scope                = module.resource_group.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.ingress.principal_id
  depends_on = [azurerm_user_assigned_identity.ingress, azurerm_kubernetes_cluster.aks]
}

# Ingress Helm
data "helm_repository" "azure-ingress" {
  name = "application-gateway-kubernetes-ingress"
  url  = "https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/"
}

resource "helm_release" "ingress" {
  provider    = helm.aks

  name       = "ingress-azure"
  namespace  = "default"
  repository = data.helm_repository.azure-ingress.metadata[0].name
  chart      = "ingress-azure"
  version    = "1.2.0"

  set {
    name  = "appgw.subscriptionId"
    value = module.subscription.output.subscription_id
  }

  set {
    name  = "appgw.resourceGroup"
    value = module.resource_group.name
  }

  set {
    name  = "appgw.name"
    value = "${module.resource_group.name}-appgw"
  }

  set {
    name  = "rbac.enabled"
    value = true
  }

  set {
    name  = "armAuth.type"
    value = "aadPodIdentity"
  }

  set {
    name  = "armAuth.identityResourceID"
    value = azurerm_user_assigned_identity.ingress.id
  }

  set {
    name  = "armAuth.identityClientID"
    value = azurerm_user_assigned_identity.ingress.client_id
  }

  depends_on = [module.aad_pod_identity, azurerm_application_gateway.network]
}

##############
# App Deploy #
##############

# Pod
resource "kubernetes_pod" "helloworld" {
  metadata {
    name = "helloworld"
    labels = {
      app = "helloworld"
    }
  }

  spec {
    container {
      image  = "xhissy/helloworld-php:v1.0.0"
      name   = "helloworld"

      port {
        container_port = 80
      }

      port {
        container_port = 81
      }
    }
  }
}

# Service
resource "kubernetes_service" "helloworld" {

  metadata {
    name = "helloworld-service"
    labels = {
      app = "helloworld"
    }
  }

  spec {
    selector = {
      app = "helloworld"
    }
    port {
      port        = 80
      target_port = 80
    }
  }

}

resource "kubernetes_service" "helloworld-81" {

  metadata {
    name = "helloworld-service-81"
    labels = {
      app = "helloworld"
    }
  }

  spec {
    selector = {
      app = "helloworld"
    }
    port {
      port        = 80
      target_port = 80
    }
  }

}

# Ingress
resource "kubernetes_ingress" "helloworld" {
  metadata {
    name = "helloworld-ingress"
    annotations = {
      "kubernetes.io/ingress.class" = "azure/application-gateway"
      "appgw.ingress.kubernetes.io/backend-path-prefix" = "/"
    }
  }

  spec {
    rule {
      http {
        path {
          path = "/"
          backend {
            service_name = "helloworld-service"
            service_port = "80"
          }
        }

        path {
          path = "/WsMarketing"
          backend {
            service_name = "helloworld-service-81"
            service_port = "80"
          }
        }
      }
    }    
  }
}

##########
# Output #
##########

output "resource_group_name" {
  value = module.resource_group.name
}

output "aks_cluster_name" {
  value = local.cluster_name
}

output "aks_login" {
  value = "az aks get-credentials --name ${local.cluster_name} --resource-group ${module.resource_group.name}"
}

output "aks_browse"{
  value = "az aks browse --name ${local.cluster_name} --resource-group ${module.resource_group.name}"
}
