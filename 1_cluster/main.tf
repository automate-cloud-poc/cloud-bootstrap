terraform {
  required_providers {
    kubectl = {
      source = "Altinity/kubectl"
      version = "1.7.3"
    }
    http = {
      source = "hashicorp/http"
      version = "2.1.0"
    }
    k8s = {
      source = "ophelan/k8s"
      version = "0.6.1"
    }
    local = {
      source = "hashicorp/local"
      version = "2.1.0"
    }
  }
}

provider "google" {
  project     = var.project_id
  region      = var.project_region
}

data "google_service_account" "cicd_account" {
  project      = var.project_id
  account_id   = "cicd-service-account-id"
}

data "google_service_account_access_token" "gcloud_access_token" {
  provider               = google
  target_service_account = data.google_service_account.cicd_account.email
  scopes                 = ["userinfo-email", "cloud-platform"]
  lifetime               = "600s"
}

data "google_client_config" "provider" {}

resource "google_container_cluster" "primary" {
  project  = var.project_id
  name     = "my-gke-cluster"
  location = "${var.project_region}-a"

  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
}

provider "kubernetes" {
  host  = "https://${google_container_cluster.primary.endpoint}"
//  token = data.google_client_config.provider.access_token
  token = data.google_service_account_access_token.gcloud_access_token.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

# Small Linux node pool to run some Linux-only Kubernetes Pods.
resource "google_container_node_pool" "primary_nodes" {
  project    = var.project_id
  name       = "my-node-pool"
  location   = "${var.project_region}-a"
  cluster    = google_container_cluster.primary.name
  node_count = 2

  node_config {
    machine_type = "e2-medium"

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = data.google_service_account.cicd_account.email
    oauth_scopes    = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}


resource "kubernetes_namespace" "namespace_api" {
  metadata {
    name = "api"

    labels = {
      istio-injection = "enabled"
    }
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

provider "helm" {
  kubernetes {
    host  = "https://${google_container_cluster.primary.endpoint}"
    token = data.google_service_account_access_token.gcloud_access_token.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
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

  depends_on = [google_container_node_pool.primary_nodes]
}

resource "kubernetes_namespace" "istio-system-namespace" {
  metadata {
    name = "istio-system"
  }
  depends_on = [google_container_node_pool.primary_nodes]
}

// curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.9.2 sh -
resource "helm_release" "istio_base" {
  name  = "istio-base"
  chart = "istio-1.9.2/manifests/charts/base"

  timeout = 120
  cleanup_on_fail = true
  force_update    = true
  namespace       = "istio-system"


  depends_on = [kubernetes_namespace.istio-system-namespace]
}

resource "helm_release" "istio_istiod" {
  name  = "istiod"
  chart = "istio-1.9.2/manifests/charts/istio-control/istio-discovery"

  timeout = 120
  cleanup_on_fail = true
  force_update    = true
  namespace       = "istio-system"

  set {
    name = "pilot.resources.requests.cpu"
    value = "50m"
  }

  set {
    name = "pilot.resources.requests.memory"
    value = "512Mi"
  }

  set {
    name = "pilot.cpu.targetAverageUtilization"
    value = "80"
  }

  set {
    name = "global.proxy.resources.requests.cpu"
    value = "50m"
  }

  set {
    name = "global.proxy_init.resources.requests.cpu"
    value = "50m"
  }

  set {
    name = "global.proxy_init.resources.requests.memory"
    value = "512Mi"
  }

  depends_on = [helm_release.istio_base]
}

resource "helm_release" "istio_ingress" {
  name  = "istio-ingress"
  chart = "istio-1.9.2/manifests/charts/gateways/istio-ingress"

  timeout = 120
  cleanup_on_fail = true
  force_update    = true
  namespace       = "istio-system"

  depends_on = [helm_release.istio_istiod]
}

resource "helm_release" "istio_egress" {
  name  = "istio-egress"
  chart = "istio-1.9.2/manifests/charts/gateways/istio-egress"

  timeout = 120
  cleanup_on_fail = true
  force_update    = true
  namespace       = "istio-system"

  depends_on = [helm_release.istio_ingress]
}

