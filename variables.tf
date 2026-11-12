variable "st_rules_json_file_path" {
  description = "Path to the Split Tunnel JSON export produced by `catocli export st_rules` (data.policy.splitTunnel.policy root)."
  type        = string
}

variable "policy_enabled" {
  description = "Manage the account-level Split Tunnel policy toggle. null leaves the toggle unmanaged; true/false manages it via cato_split_tunnel_policy."
  type        = bool
  default     = null
}

variable "allow_empty_policy" {
  type        = bool
  default     = false
  description = "Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown."
}
