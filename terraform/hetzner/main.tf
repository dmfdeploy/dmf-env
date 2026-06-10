locals {
  manifest = yamldecode(file(var.manifest_path))
  spec     = local.manifest.spec
}

module "cluster" {
  source = "../modules/hetzner/cluster"

  spec                             = local.spec
  ssh_pubkey_path                  = var.ssh_pubkey_path
  awx_control_node_ssh_pubkey_path = var.awx_control_node_ssh_pubkey_path
}

# B2 object-storage buckets are created and configured via the B2 native
# API; see dmf-env/bin/b2-buckets.sh. The Terraform AWS provider cannot
# manage B2-side aux state cleanly (CORS casing mismatch, 501 on
# PutBucketTagging, side-paths clobbering Object Lock state on
# PutBucketEncryption). Old generic-s3 TF module deleted; no migration
# path back through the AWS provider.

resource "local_file" "hosts_ini" {
  filename = var.hosts_ini_output_path
  content = templatefile("${path.module}/../modules/hetzner/cluster/templates/hosts.ini.tftpl", {
    nodes        = module.cluster.nodes
    admin_user   = module.cluster.admin_user
    control_node = module.cluster.control_node
    agent_nodes  = module.cluster.agent_nodes
  })
  file_permission = "0644"
}
