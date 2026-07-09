provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

resource "random_password" "jvb_auth" {
  length  = 16
  special = false
}

resource "random_password" "jicofo_auth" {
  length  = 16
  special = false
}

resource "random_password" "jibri_recorder" {
  length  = 16
  special = false
}

resource "random_password" "jibri_xmpp" {
  length  = 16
  special = false
}

resource "random_password" "turn_secret" {
  length  = 16
  special = false
}

locals {
  labels = {
    app     = "jitsi"
    managed = "terraform"
  }

  common_metadata = {
    enable-oslogin = "FALSE"
    ssh-keys       = "ubuntu:${var.ssh_public_key}"
  }

  secrets = {
    jvb_password         = random_password.jvb_auth.result
    jicofo_password      = random_password.jicofo_auth.result
    jibri_recorder_pass  = random_password.jibri_recorder.result
    jibri_xmpp_pass      = random_password.jibri_xmpp.result
    turn_secret          = random_password.turn_secret.result
  }
}

# ---------- Firewall ----------
resource "google_compute_firewall" "jitsi_web" {
  name    = "jitsi-allow-web"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["jitsi-control"]
}

resource "google_compute_firewall" "jitsi_ssh" {
  name    = "jitsi-allow-ssh"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["jitsi-control", "jitsi-jvb", "jitsi-jibri"]
}

resource "google_compute_firewall" "jitsi_media" {
  name    = "jitsi-allow-media"
  network = var.network

  allow {
    protocol = "udp"
    ports    = ["10000", "3478"]
  }

  allow {
    protocol = "tcp"
    ports    = ["4443", "3478", "5349"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["jitsi-control", "jitsi-jvb"]
}

resource "google_compute_firewall" "jitsi_internal" {
  name    = "jitsi-allow-internal"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["5222", "5347", "5280", "5281", "8080", "8888", "9090"]
  }

  allow {
    protocol = "udp"
  }

  source_tags = ["jitsi-control", "jitsi-jvb", "jitsi-jibri"]
  target_tags = ["jitsi-control", "jitsi-jvb", "jitsi-jibri"]
}

# ---------- Static IPs (yalnız control + jvb) ----------
resource "google_compute_address" "control" {
  name   = "jitsi-control-ip"
  region = var.region
}

resource "google_compute_address" "jvb" {
  name   = "jitsi-jvb-ip"
  region = var.region
}

# ---------- meet-control ----------
resource "google_compute_instance" "control" {
  name         = "meet-control"
  machine_type = var.control_machine_type
  zone         = var.zone
  tags         = ["jitsi-control", "jitsi-server"]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.control_disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = var.network
    access_config {
      nat_ip = google_compute_address.control.address
    }
  }

  metadata = merge(local.common_metadata, {
    role             = "control"
    domain           = var.domain
    admin_email      = var.admin_email
    jvb_password     = local.secrets.jvb_password
    jicofo_password  = local.secrets.jicofo_password
    jibri_rec_pass   = local.secrets.jibri_recorder_pass
    jibri_xmpp_pass  = local.secrets.jibri_xmpp_pass
    turn_secret      = local.secrets.turn_secret
    jvb_public_ip    = google_compute_address.jvb.address
  })

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
  }

  allow_stopping_for_update = true
}

# ---------- meet-jvb ----------
resource "google_compute_instance" "jvb" {
  name         = "meet-jvb"
  machine_type = var.jvb_machine_type
  zone         = var.zone
  tags         = ["jitsi-jvb", "jitsi-server"]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.jvb_disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = var.network
    access_config {
      nat_ip = google_compute_address.jvb.address
    }
  }

  metadata = merge(local.common_metadata, {
    role            = "jvb"
    domain          = var.domain
    control_ip      = google_compute_instance.control.network_interface[0].network_ip
    jvb_password    = local.secrets.jvb_password
    jvb_public_ip   = google_compute_address.jvb.address
  })

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  allow_stopping_for_update = true

  depends_on = [google_compute_instance.control]
}

# ---------- recorder-1 .. recorder-N (hər VM-də bir neçə Jibri prosesi) ----------
resource "google_compute_instance" "jibri" {
  count        = var.recorder_count
  name         = "recorder-${count.index + 1}"
  machine_type = var.jibri_machine_type
  zone         = var.zone
  tags         = ["jitsi-jibri"]
  labels       = merge(local.labels, { role = "recorder" })

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.jibri_disk_gb
      type  = "pd-balanced"
    }
  }

  # Yalnız daxili IP — regional IN_USE_ADDRESSES quota qənaəti (SSH: meet-control bastion)
  network_interface {
    network = var.network
  }

  metadata = merge(local.common_metadata, {
    role                 = "recorder"
    domain               = var.domain
    control_ip           = google_compute_instance.control.network_interface[0].network_ip
    jibri_recorder_pass  = local.secrets.jibri_recorder_pass
    jibri_xmpp_pass      = local.secrets.jibri_xmpp_pass
    bunny_library_id     = var.bunny_library_id
    bunny_api_key        = var.bunny_api_key
    bunny_cdn_hostname   = var.bunny_cdn_hostname
    recorder_host_id     = "recorder-${count.index + 1}"
    jibri_per_vm         = tostring(var.jibri_per_vm)
  })

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  allow_stopping_for_update = true

  depends_on = [google_compute_instance.control]
}

# ---------- Schedule start/stop ----------
resource "google_service_account" "scheduler" {
  count        = var.enable_schedule ? 1 : 0
  account_id   = "jitsi-scheduler"
  display_name = "Jitsi VM start/stop scheduler"
  # Yarımçıq destroy / itmiş state: SA GCP-də qalır, recreate 409 verir
  create_ignore_already_exists = true
}

resource "google_project_iam_member" "scheduler_compute" {
  count   = var.enable_schedule ? 1 : 0
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.scheduler[0].email}"
}

resource "google_project_iam_member" "scheduler_sa_user" {
  count   = var.enable_schedule ? 1 : 0
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.scheduler[0].email}"
}

# Cloud Scheduler jobs (bütün VM-lər) deploy.sh → scripts/install-scheduler-jobs.sh
# ilə yaradılır. Terraform yalnız SA + IAM hazırlayır.

resource "local_file" "secrets_json" {
  content = jsonencode({
    domain              = var.domain
    admin_email         = var.admin_email
    control_public_ip   = google_compute_address.control.address
    jvb_public_ip       = google_compute_address.jvb.address
    control_private_ip  = google_compute_instance.control.network_interface[0].network_ip
    jvb_private_ip      = google_compute_instance.jvb.network_interface[0].network_ip
    jibri_private_ips   = [for i in google_compute_instance.jibri : i.network_interface[0].network_ip]
    jibri_names         = [for i in google_compute_instance.jibri : i.name]
    recorder_count      = var.recorder_count
    jibri_per_vm        = var.jibri_per_vm
    concurrent_recordings = var.recorder_count * var.jibri_per_vm
    secrets             = local.secrets
    bunny = {
      library_id   = var.bunny_library_id
      cdn_hostname = var.bunny_cdn_hostname
    }
  })
  filename        = "${path.module}/generated/outputs.json"
  file_permission = "0600"
}
