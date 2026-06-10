locals {
  node_names = var.spec.topology.control_plane.members

  env_id               = var.spec.topology.environment_name
  cloud                = var.spec.provider.cloud
  region               = local.cloud.region
  server_type          = local.cloud.server_type
  ssh_key_name         = coalesce(try(local.cloud.ssh_key_name, null), var.ssh_key_name)
  private_network_name = coalesce(try(local.cloud.private_network, null), "${local.env_id}-private")
  private_cidr         = local.cloud.private_cidr
  firewall_name        = coalesce(try(local.cloud.firewall_name, null), var.firewall_name)
  server_label_cluster = coalesce(try(local.cloud.server_label_cluster, null), var.server_label_cluster)
  lb_name              = coalesce(try(local.cloud.load_balancer.name, null), var.lb_name)
  network_zone         = "eu-central"
  admin_user           = var.spec.topology.admin_user
  user_data = templatefile("${path.module}/templates/user-data.yml.tftpl", {
    admin_user         = local.admin_user
    ssh_public_key     = file(pathexpand(var.ssh_pubkey_path))
    awx_ssh_public_key = trimspace(file(pathexpand(var.awx_control_node_ssh_pubkey_path)))
  })

  ssh_allow_ips = concat(
    var.spec.network.ssh_allow_ipv4,
    var.spec.network.ssh_allow_ipv6,
  )

  # Cloudflare stores `name` relative to the zone (e.g. "lab" inside zone
  # "example.com"). The manifest provides the FQDN; trim the zone suffix
  # so the rendered config round-trips against existing state.
  zone_name     = var.spec.domain.tls.cloudflare_zone
  apex_relative = trimsuffix(var.spec.domain.cluster_domain, ".${local.zone_name}")
  auth_relative = trimsuffix(var.spec.domain.hosts.authentik, ".${local.zone_name}")
}

# ── SSH key ─────────────────────────────────────────────────────────────
resource "hcloud_ssh_key" "k3s" {
  name       = local.ssh_key_name
  public_key = file(pathexpand(var.ssh_pubkey_path))
}

# ── Private network + subnet ────────────────────────────────────────────
resource "hcloud_network" "k3s_private" {
  name     = local.private_network_name
  ip_range = var.private_network_ip_range
}

resource "hcloud_network_subnet" "k3s_private" {
  network_id   = hcloud_network.k3s_private.id
  type         = "server"
  network_zone = local.network_zone
  ip_range     = local.private_cidr
}

# ── Firewall ────────────────────────────────────────────────────────────
# Mirrors the rules currently on the live `k3s-nodes` firewall:
# ICMP from anywhere, SSH from harden_ssh_allow_ipv4/ipv6 only,
# TCP/80 + TCP/443 from anywhere ("VIP traffic" — public ingress lane).
resource "hcloud_firewall" "k3s" {
  name = local.firewall_name

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Allow ICMP from anywhere"
  }

  dynamic "rule" {
    for_each = length(local.ssh_allow_ips) > 0 ? [1] : []
    content {
      direction   = "in"
      protocol    = "tcp"
      port        = "22"
      source_ips  = local.ssh_allow_ips
      description = "SSH from allowed sources only"
    }
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Allow TCP 80 from anywhere (VIP traffic)"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Allow TCP 443 from anywhere (VIP traffic)"
  }

  apply_to {
    label_selector = "cluster=${local.server_label_cluster}"
  }
}

# ── Servers ─────────────────────────────────────────────────────────────
resource "hcloud_server" "node" {
  for_each = toset(local.node_names)

  name        = each.value
  server_type = local.server_type
  image       = "debian-12"
  location    = local.region
  ssh_keys    = [hcloud_ssh_key.k3s.name]
  user_data   = local.user_data

  labels = {
    role    = "k3s"
    cluster = local.server_label_cluster
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  lifecycle {
    # `user_data` bootstraps k3s-admin at create-time. Keep it in config so
    # recreated nodes come up ready for Ansible, but ignore drift on already-
    # imported servers where Hetzner does not expose the bootstrap payload.
    ignore_changes = [
      user_data,
      placement_group_id,
      ssh_keys,
      public_net,
      allow_deprecated_images,
      ignore_remote_firewall_ids,
      keep_disk,
      shutdown_before_deletion,
    ]
  }
}

resource "hcloud_server_network" "node" {
  # Iterate the static set of node names rather than `hcloud_server.node`
  # — `for_each` arguments must be statically resolvable for `tofu import`
  # to validate the configuration against an empty state.
  for_each = toset(local.node_names)

  server_id  = hcloud_server.node[each.key].id
  network_id = hcloud_network.k3s_private.id

  lifecycle {
    # IPs were auto-assigned by Hetzner (10.0.0.2/3/4); pinning them in
    # config would force-replace on re-creation. The rendered inventory
    # reads the actual assigned IP from server state, not config.
    ignore_changes = [ip]
  }
}

# ── Load balancer (read-only data source) ───────────────────────────────
# CCM creates dmf-traefik when the ingress playbook deploys the Service of
# type LoadBalancer. First Layer-1 apply must not look it up yet.
data "hcloud_load_balancer" "dmf_traefik" {
  count = var.publish_lb_dns_records ? 1 : 0
  name  = local.lb_name
}

# ── Cloudflare DNS ──────────────────────────────────────────────────────
data "cloudflare_zone" "primary" {
  name = var.spec.domain.tls.cloudflare_zone
}

resource "cloudflare_record" "cluster_apex" {
  count   = var.publish_lb_dns_records ? 1 : 0
  zone_id = data.cloudflare_zone.primary.id
  name    = local.apex_relative
  type    = "A"
  content = data.hcloud_load_balancer.dmf_traefik[0].ipv4
  proxied = false
  ttl     = 1 # 1 = automatic
  comment = "Managed by OpenTofu"
}

resource "cloudflare_record" "cluster_auth" {
  count   = var.publish_lb_dns_records ? 1 : 0
  zone_id = data.cloudflare_zone.primary.id
  name    = local.auth_relative
  type    = "A"
  content = data.hcloud_load_balancer.dmf_traefik[0].ipv4
  proxied = false
  ttl     = 1
  comment = "Managed by OpenTofu"
}

# ── Agent node groups (optional, heterogeneous) ────────────────────────
# When spec.topology.node_groups is declared, each group produces N agent
# servers attached to the same private network / firewall.  When absent
# (the default for all existing envs), this section renders nothing and
# the module output is byte-identical to the homogeneous-only path.

locals {
  node_groups = try(var.spec.topology.node_groups, [])

  # Flat list of { group, idx } tuples — used to generate unique node names
  # so for_each has a stable map key.  idx is 1-based, sequential within
  # each group.
  agent_expanded = flatten([
    for g in local.node_groups : [
      for i in range(g.count) : {
        group_name  = g.name
        server_type = g.server_type
        role        = try(g.role, "agent")
        labels      = try(g.labels, {})
        taints      = try(g.taints, [])
        idx         = i + 1
        # Optional per-group DC override; falls back to the cluster region.
        # Lets a processor node land in a sibling eu-central DC (fsn1/hel1)
        # when the cluster's home DC is out of ARM capacity. Same network
        # zone, so it attaches to the same private network.
        location = try(g.location, local.region)
      }
    ]
  ])

  # Map keyed by "<group_name>-<idx>" for for_each iteration.
  agent_map = {
    for a in local.agent_expanded : "${a.group_name}-${a.idx}" => a
  }
}

resource "hcloud_server" "agent" {
  for_each = local.agent_map

  name        = "${local.env_id}-${each.key}"
  server_type = each.value.server_type
  image       = "debian-12"
  location    = each.value.location
  ssh_keys    = [hcloud_ssh_key.k3s.name]
  user_data   = local.user_data

  labels = merge(
    {
      role    = "k3s-agent"
      cluster = local.server_label_cluster
    },
    each.value.labels,
  )

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  lifecycle {
    ignore_changes = [
      user_data,
      placement_group_id,
      ssh_keys,
      public_net,
      allow_deprecated_images,
      ignore_remote_firewall_ids,
      keep_disk,
      shutdown_before_deletion,
    ]
  }
}

resource "hcloud_server_network" "agent" {
  for_each = local.agent_map

  server_id  = hcloud_server.agent[each.key].id
  network_id = hcloud_network.k3s_private.id

  lifecycle {
    ignore_changes = [ip]
  }
}
