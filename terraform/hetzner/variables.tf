variable "manifest_path" {
  description = "Path to the manifest.yaml file (Resource Profile)."
  type        = string
}

variable "hosts_ini_output_path" {
  description = "Path where the rendered hosts.ini file will be written."
  type        = string
}

variable "ssh_pubkey_path" {
  description = "Path to the SSH public key to be uploaded to Hetzner and used by Ansible."
  type        = string
}

variable "awx_control_node_ssh_pubkey_path" {
  description = "Path to the per-env AWX→control-node SSH public key (ADR-0016 Path A), rendered into cloud-init. Supplied by bin/tf-apply.sh from the resolver."
  type        = string
}

variable "hcloud_token" {
  description = "Hetzner Cloud API token."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare DNS-edit token."
  type        = string
  sensitive   = true
}

# ── Object storage credentials (S3-compatible, e.g. Backblaze B2) ────────
#
# These are NOT committed. The operator sources them at `tofu apply` time via
# a private -var-file under $DMF_BOOTSTRAP_BUNDLE_DIR, e.g.:
#
#   tofu apply -var-file="${DMF_BOOTSTRAP_BUNDLE_DIR}/hetzner/object-storage.tfvars"
#
# The .tfvars file contains:
#   object_storage_access_key_id     = "<from B2 console / operator vault>"
#   object_storage_secret_access_key = "<from B2 console / operator vault>"
#
# Per ADR-0007: never embed these values in tracked files, env, or argv.

variable "object_storage_access_key_id" {
  description = "S3-compatible access key ID for the object-storage endpoint (from bundle -var-file). Dormant — see main.tf for why the object_storage module is currently disabled."
  type        = string
  sensitive   = true
  default     = ""
}

variable "object_storage_secret_access_key" {
  description = "S3-compatible secret access key for the object-storage endpoint (from bundle -var-file)."
  type        = string
  sensitive   = true
  default     = ""
}
