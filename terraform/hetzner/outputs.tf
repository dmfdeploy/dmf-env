output "nodes" {
  description = "Cluster nodes — name, public IPv4, private IPv4."
  value       = module.cluster.nodes
}

output "control_node" {
  description = "Bootstrap control-plane node name."
  value       = module.cluster.control_node
}

output "lb_ipv4" {
  description = "CCM-managed load-balancer public IPv4 (Cloudflare A records point at this)."
  value       = module.cluster.lb_ipv4
}

output "agent_nodes" {
  description = "Agent node map (name, IPs, labels, taints) — empty when no node_groups declared."
  value       = module.cluster.agent_nodes
}
