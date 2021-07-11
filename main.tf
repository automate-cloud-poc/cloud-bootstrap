
variable "project_id" {
  default = "multi-region-prj2-319322"
}

variable "project_region" {
  default = "us-central1"
}

// Configure the Google Cloud provider
provider "google" {
// credentials = file("CREDENTIALS_FILE.json")
 project     = var.project_id
 region      = var.project_region
}

provider "google-beta" {
//  credentials = file("CREDENTIALS_FILE.json")
  project     = var.project_id
  region      = var.project_region
}

module "network" {
  source  = "terraform-google-modules/network/google"
  version = "3.3.0"
  # insert the 3 required variables here
  project_id = var.project_id
  network_name = "network-name"

  subnets = [
    {
      subnet_name           = "subnet-01"
      subnet_ip             = "10.0.0.0/24"
      subnet_region         = var.project_region
    },
  ]

  secondary_ranges = {
    subnet-01 = [
      {
        range_name    = "subnet-01-secondary-01"
        ip_cidr_range = "10.1.0.0/16"
      },
      {
        range_name    = "subnet-02-secondary-01"
        ip_cidr_range = "10.2.0.0/16"
      },
    ]
  }
}

module "gke" {
  source                     = "terraform-google-modules/kubernetes-engine/google//modules/beta-private-cluster"
  project_id                 =  var.project_id
  regional                   = false
  zones                      = ["${var.project_region}-a"]
  name                       = "gke-test-1"
  network                    = module.network.network_name
  subnetwork                 =  module.network.subnets_names[0]
  ip_range_pods              = "subnet-01-secondary-01"
  ip_range_services          = "subnet-02-secondary-01"
  http_load_balancing        = false
  horizontal_pod_autoscaling = false
  network_policy             = false
  istio                      = true
  create_service_account     = true

  node_pools = [
    {
      name                      = "default-node-pool"
      machine_type              = "e2-medium"
      node_location             = var.project_region
      min_count                 = 1
      max_count                 = 1
      local_ssd_count           = 0
      disk_size_gb              = 100
      disk_type                 = "pd-standard"
      image_type                = "COS"
      preemptible               = false
      initial_node_count        = 1
    },
  ]

  node_pools_oauth_scopes = {
    all = []

    default-node-pool = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  node_pools_labels = {
    all = {}

    default-node-pool = {
      default-node-pool = true
    }
  }

  node_pools_metadata = {
    all = {}

    default-node-pool = {
      node-pool-metadata-custom-value = "my-node-pool"
    }
  }

  node_pools_taints = {
    all = []

    default-node-pool = [
      {
        key    = "default-node-pool"
        value  = true
        effect = "PREFER_NO_SCHEDULE"
      },
    ]
  }

  node_pools_tags = {
    all = []

    default-node-pool = [
      "default-node-pool",
    ]
  }
}

data "google_client_config" "provider" {}


provider "kubernetes" {
  host = "https://${module.gke.endpoint}"
  token = data.google_client_config.provider.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}

resource "kubernetes_namespace" "sandbox" {
  metadata {
    name = "sandbox"
  }
}

provider "helm" {
  kubernetes {
    host = "https://${module.gke.endpoint}"
    token = data.google_client_config.provider.access_token
    cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  }
}

resource "helm_release" "nginx_ingress" {
  name       = "nginx-ingress-controller"

  repository = "https://charts.bitnami.com/bitnami"
  chart      = "nginx-ingress-controller"

  set {
    name  = "service.type"
    value = "ClusterIP"
  }
}
