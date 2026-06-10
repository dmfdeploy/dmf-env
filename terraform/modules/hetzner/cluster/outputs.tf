output "nodes" {
  description = "List of cluster node objects: name, public_ipv4, private_ipv4."
  # Iterate the live `hcloud_server.node` map (sorted by key for stable
  # order). Tolerant of partial state during `tofu import`. Pulls the
  # private IP from the explicit `hcloud_server_network` attachment
  # rather than the deprecated server.network computed attribute, which
  # is unreliable post-import.
  value = [
    for k in sort(keys(hcloud_server.node)) : {
      name       = k
      public_ip  = hcloud_server.node[k].ipv4_address
      private_ip = try(hcloud_server_network.node[k].ip, "")
    }
  ]
}

output "control_node" {
  description = "Bootstrap control-plane node name (the --cluster-init member)."
  value       = var.spec.topology.control_plane.bootstrap_node
}

output "admin_user" {
  description = "Non-root admin user provisioned via cloud-init at server-create time."
  value       = var.spec.topology.admin_user
}

output "lb_ipv4" {
  description = "Public IPv4 of the CCM-managed load balancer (looked up by name)."
  value       = try(data.hcloud_load_balancer.dmf_traefik[0].ipv4, "")
}

output "ssh_key_id" {
  description = "Hetzner SSH key resource ID."
  value       = hcloud_ssh_key.k3s.id
}

output "network_id" {
  description = "Hetzner private network resource ID."
  value       = hcloud_network.k3s_private.id
}

output "firewall_id" {
  description = "Hetzner firewall resource ID."
  value       = hcloud_firewall.k3s.id
}

output "agent_nodes" {
  description = "Map of agent node objects keyed by '<group>-<idx>': name, public_ipv4, private_ipv4, group labels + taints for Ansible."
  value = {
    for k in sort(keys(hcloud_server.agent)) : k => {
      name       = hcloud_server.agent[k].name
      public_ip  = hcloud_server.agent[k].ipv4_address
      private_ip = try(hcloud_server_network.agent[k].ip, "")
      labels     = local.agent_map[k].labels
      taints     = local.agent_map[k].taints
    }
  }
}
