# terraform-cato-bulk-st-rules
#
# Bulk-manages the Cato Split Tunnel (splitTunnel) policy from one JSON
# export produced by `catocli export st_rules`:
#   sections[] / rules[] / rules_in_sections[] - flat policy, no sub-policies.
# cato_bulk_st_move_rule applies ordering and republishes.
# Rule fields: action, coverage, routingPriority, country, platform, destination{application,domain,fqdn,globalIpRange}, dnsExclusion{domain}, source{user,usersGroup}, sourceNetwork.sourceNetworkType.

locals {
  st_json = jsondecode(file("${var.st_rules_json_file_path}"))
  st      = local.st_json.data.policy.splitTunnel.policy

  sections_data_raw      = try(local.st.sections, [])
  rules_data_raw         = try(local.st.rules, [])
  rules_in_sections_data = try(local.st.rules_in_sections, [])

  sections_data = {
    for s in local.sections_data_raw : s.section_name => s
  }

  rules_by_name = {
    for rw in local.rules_data_raw : rw.rule.name => rw
  }

  move_section_data = {
    for name, s in local.sections_data : name => {
      section_index = s.section_index
    }
  }

  move_rule_data = {
    for row in local.rules_in_sections_data :
    row.rule_name => {
      index_in_section = row.index_in_section
      section_name     = row.section_name
    }
    if row.section_name != "" && contains(keys(local.sections_data), row.section_name)
  }

  unordered_rules_data = [
    for row in local.rules_in_sections_data : row
    if !contains(keys(local.move_rule_data), try(row.rule_name, ""))
  ]

  rule_bodies = {
    for name, rw in local.rules_by_name : name => merge(
      {
        name             = rw.rule.name
        enabled          = try(rw.rule.enabled, true)
        action           = try(rw.rule.action, "EXCLUDE")
        routing_priority = try(rw.rule.routingPriority, "LAN")
      },
      try(rw.rule.description, "") != "" ? { description = rw.rule.description } : {},
      try(rw.rule.coverage, null) != null ? { coverage = rw.rule.coverage } : {},
      try(length(rw.rule.country), 0) > 0 ? { country = [for x in rw.rule.country : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
      try(length(rw.rule.platform), 0) > 0 ? { platform = rw.rule.platform } : {},
      anytrue([
        try(length(rw.rule.destination.application), 0) > 0,
        try(length(rw.rule.destination.domain), 0) > 0,
        try(length(rw.rule.destination.fqdn), 0) > 0,
        try(length(rw.rule.destination.globalIpRange), 0) > 0,
        ]) ? {
        destination = merge(
          try(length(rw.rule.destination.application), 0) > 0 ? { application = [for x in rw.rule.destination.application : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(rw.rule.destination.domain), 0) > 0 ? { domain = rw.rule.destination.domain } : {},
          try(length(rw.rule.destination.fqdn), 0) > 0 ? { fqdn = rw.rule.destination.fqdn } : {},
          try(length(rw.rule.destination.globalIpRange), 0) > 0 ? { global_ip_range = [for x in rw.rule.destination.globalIpRange : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )
      } : {},
      try(length(rw.rule.dnsExclusion.domain), 0) > 0 ? {
        dns_exclusion = { domain = rw.rule.dnsExclusion.domain }
      } : {},
      try(length(rw.rule.source.user), 0) > 0 || try(length(rw.rule.source.usersGroup), 0) > 0 ? {
        source = merge(
          try(length(rw.rule.source.user), 0) > 0 ? { user = [for x in rw.rule.source.user : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(rw.rule.source.usersGroup), 0) > 0 ? { users_group = [for x in rw.rule.source.usersGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )
      } : {},
      try(rw.rule.sourceNetwork.sourceNetworkType, null) != null ? {
        source_network = { source_network_type = rw.rule.sourceNetwork.sourceNetworkType }
      } : {}
    )
  }
}

# Optional account-level policy toggle (Split Tunnel ships disabled on new
# tenants - without enabling it, published rules have no effect).
resource "cato_split_tunnel_policy" "policy" {
  count   = var.policy_enabled == null ? 0 : 1
  enabled = var.policy_enabled
}

resource "cato_split_tunnel_section" "sections" {
  for_each = local.sections_data
  at = {
    position = "LAST_IN_POLICY"
  }
  section = {
    name = each.value.section_name
  }
}

resource "cato_split_tunnel_rule" "rules" {
  depends_on = [cato_split_tunnel_section.sections]
  for_each   = local.rules_by_name

  at = contains(keys(local.sections_data), each.value.rule.section.name) ? {
    position = "LAST_IN_SECTION"
    ref      = cato_split_tunnel_section.sections[each.value.rule.section.name].id
    } : {
    position = "LAST_IN_POLICY"
  }

  rule = local.rule_bodies[each.key]
}

# Ordering + republish on changes.
resource "cato_bulk_st_move_rule" "all_st_rules" {
  depends_on = [cato_split_tunnel_section.sections, cato_split_tunnel_rule.rules]

  section_data = local.move_section_data
  rule_data    = local.move_rule_data
}
