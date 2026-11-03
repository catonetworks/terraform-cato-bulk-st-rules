variable "st_rules_json_file_path" {
  description = "Path to the Split Tunnel JSON export produced by `catocli export st_rules` (data.policy.splitTunnel.policy root)."
  type        = string
}

variable "policy_enabled" {
  description = "Manage the account-level Split Tunnel policy toggle. null leaves the toggle unmanaged; true/false manages it via cato_split_tunnel_policy."
  type        = bool
  default     = null
}
