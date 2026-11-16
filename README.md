# terraform-cato-bulk-st-rules

> [!IMPORTANT]
> **Early access (beta).** This module targets the Cato Terraform provider
> `2.0.0-prerelease.1`, an **early-access / beta** release. A general-availability
> (GA) release is planned shortly, following the current evaluation period.
> Until GA ships, pin the exact prerelease version.


Bulk-manages the Cato **Split Tunnel (splitTunnel)** policy from a single
JSON export: sections and rules (flat policy - no sub-policies exist for this
type), with ordering and publishing via `cato_bulk_st_move_rule`.

## Resources managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_split_tunnel_section.sections` | `section_name` | created `LAST_IN_POLICY`; ordered by the move resource |
| `cato_split_tunnel_rule.rules` | rule name | placement: managed section -> `LAST_IN_SECTION`; sectionless -> `LAST_IN_POLICY` |
| `cato_bulk_st_move_rule.all_st_rules` | - | orders sections (`section_index`) and rules (`index_in_section`) and **publishes** |
| `cato_split_tunnel_policy.policy` | - | optional account-level enable/disable toggle (`policy_enabled` variable) |

**Publishing:** the rule/section resources save to the draft policy only -
`cato_bulk_st_move_rule` is this stack's single publisher. Split Tunnel ships
**disabled** on new tenants - set `policy_enabled = true` (or enable it in
the CMA) for published rules to take effect.

**Empty-policy guard:** `terraform plan` fails early if the decoded JSON
contains 0 rules, unless `allow_empty_policy = true` is set. This protects
against a truncated export, a renamed upstream JSON key, or an
accidentally wrong-tenant JSON file silently destroying every live rule.
Set `allow_empty_policy = true` only for an intentional greenfield or
teardown apply.

## Usage

The module reads a JSON configuration file that defines:
- **Rules**: Individual Split Tunnel rules with their configurations
- **Sections**: Logical groupings for organizing rules
- **Rule ordering**: Defines which rules belong to which sections and their order within sections

### Basic Example

```hcl
module "st_rules" {
  source                  = "catonetworks/bulk-st-rules/cato"
  st_rules_json_file_path = "${path.module}/config_data/all_st_rules_and_sections.json"
}
```

### JSON Configuration Structure

Produced by:

```bash
catocli export st_rules --json-filename all_st_rules_and_sections.json
```

The JSON file should contain a nested structure with the following key components:

- `data.policy.splitTunnel.policy.rules[]` - Array of Split Tunnel rules (each wrapped as `{audit, rule, properties}`; ids are retained for brownfield import)
- `data.policy.splitTunnel.policy.sections[]` - Array of sections with index and name
- `data.policy.splitTunnel.policy.rules_in_sections[]` - Mapping of rules to sections with ordering

#### Key Fields:

**Rules Array**: Each rule wrapper's `rule` object carries the standard Split Tunnel rule properties: `action`, `coverage`, `routingPriority`, `country`, `platform`, `destination` (`application`/`domain`/`fqdn`/`globalIpRange`), `dnsExclusion.domain`, `source` (`user`/`usersGroup`), and `sourceNetwork.sourceNetworkType`.

**Sections Array**: Defines sections with:
- `section_index`: The order of the section in the policy
- `section_name`: The display name of the section

**Rules in Sections Array**: Maps rules to sections with:
- `index_in_section`: The order of the rule within its section
- `section_name`: The section this rule belongs to (empty string `""` for rules that sit at the policy root, outside any section)
- `rule_name`: The name of the rule to place in the section

### How Rule Ordering Works

`cato_bulk_st_move_rule.all_st_rules` is the single resource that orders both
sections and rules and republishes the policy. It is built from two locals:

1. `move_section_data` - every section's `section_index`, keyed by
   `section_name`.
2. `move_rule_data` - every `rules_in_sections` row whose `section_name` is
   non-empty **and** resolves to a managed section, keyed by `rule_name`,
   carrying `index_in_section` and `section_name`.

Rows with `section_name: ""` (rules living at the policy root rather than
inside a section) can't be expressed as "ordered within a section", so
they're excluded from `move_rule_data` and surfaced instead via the
`unordered_rules` output - their order is creation order, best-effort.

### Parameters

- `st_rules_json_file_path`: Path to your JSON configuration file (`data.policy.splitTunnel.policy` root)
- `policy_enabled`: (Optional) Manage the account-level Split Tunnel policy toggle via `cato_split_tunnel_policy`. `null` (default) leaves the toggle unmanaged.
- `allow_empty_policy`: (Optional) Safety guard - set `true` to allow planning against a policy JSON with 0 rules (intentional greenfield/teardown only)

## Working with Existing Rules (Brownfield Deployments)

For brownfield deployments where you have existing Split Tunnel rules in your Cato Management Application, you can use the Cato CLI to export and import these rules into Terraform state.

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

To export your existing Split Tunnel rules and sections into the JSON format required by this module:

```bash
catocli export st_rules --json-filename all_st_rules_and_sections.json
```

This command will generate a JSON file containing all your existing Split Tunnel rules and sections in the correct format for this Terraform module.

### Importing Existing Rules into Terraform State (native import blocks)

Requires Terraform **>= 1.7**. Every `for_each` address in this module
(`rules_by_name`, `sections_data`) is keyed by name, exactly matching the
exported JSON's `rule.name` / `section_name` fields - that's why the import
blocks below line up one-to-one with the JSON with no re-keying.

<details>
<summary>Option A (recommended) - native Terraform import blocks (migration.tf)</summary>

```hcl
# migration.tf - one-time adoption of existing Split Tunnel rules/sections.
# Place beside the module call (same directory as main.tf), run once, then delete.

locals {
  st_migration_json     = jsondecode(file("${path.module}/config_data/all_st_rules_and_sections.json"))
  st_migration_policy   = local.st_migration_json.data.policy.splitTunnel.policy
  st_migration_sections = { for s in local.st_migration_policy.sections : s.section_name => s.section_id }
  st_migration_rules    = { for rw in local.st_migration_policy.rules : rw.rule.name => rw.rule.id }
}

import {
  for_each = local.st_migration_sections
  to       = module.st_rules.cato_split_tunnel_section.sections[each.key]
  id       = each.value
}

import {
  for_each = local.st_migration_rules
  to       = module.st_rules.cato_split_tunnel_rule.rules[each.key]
  id       = each.value
}
```

Preview the adoption before anything touches state:

```bash
terraform plan
```

Expect `N to import, 0 to add, 0 to change, 0 to destroy`. Any non-zero "to change" means the JSON export is stale relative to the live policy - **re-export** (`catocli export st_rules --json-filename all_st_rules_and_sections.json`) and regenerate the locals above, rather than letting `terraform apply` overwrite the live policy with stale config.

Once the plan is clean, adopt the resources into state:

```bash
terraform apply
```

Then delete `migration.tf` - its job is done, and leaving it in place just re-runs the same (no-op) import blocks on every future plan.

`cato_bulk_st_move_rule` is plan-time orchestration - it republishes the
whole policy on every apply and has no persisted object of its own to
import, so it never appears in `migration.tf`. Same for the optional
`cato_split_tunnel_policy` enable/disable toggle: it's a tenant-wide
singleton with no name/`for_each` to key an import block on.

</details>

<details>
<summary>Option B - catocli import st_rules_to_tf (imperative alternative)</summary>

An imperative alternative to Option A, for when native import blocks aren't practical (e.g. scripting a fully automated onboarding pipeline). Unlike Option A, this mutates Terraform state immediately - there is no plan preview before the import happens.

```bash
catocli import st_rules_to_tf config_data/all_st_rules_and_sections.json \
  --module-name module.st_rules --auto-approve
terraform plan   # expect: only cato_bulk_st_move_rule to add
```

**Parameters:**
- `config_data/all_st_rules_and_sections.json`: Path to your exported JSON file
- `--module-name module.st_rules`: The name of your Terraform module instance

</details>

### Typical Brownfield Workflow

1. **Export existing rules:**
   ```bash
   catocli export st_rules --json-filename all_st_rules_and_sections.json
   ```

2. **Create your Terraform configuration:**
   ```hcl
   module "st_rules" {
     source                  = "catonetworks/bulk-st-rules/cato"
     st_rules_json_file_path = "./config_data/all_st_rules_and_sections.json"
   }
   ```

3. **Adopt existing state (Option A - recommended):** create `migration.tf` with the import blocks shown above, then:
   ```bash
   terraform plan    # preview: expect only "to import"
   terraform apply   # adopt into state
   ```
   Delete `migration.tf` afterwards. (Option B: `catocli import st_rules_to_tf config_data/all_st_rules_and_sections.json --module-name module.st_rules` - imperative, no plan preview.)

4. **Run Terraform plan to verify:**
   ```bash
   terraform plan
   ```
   This should show no changes if the import was successful.

### Backup and Restore Workflow

If unintended changes are made directly to rules and sections in the Cato Management Application, you can restore to the last known good state:

1. **Apply your last known good configuration:**
   ```bash
   terraform apply
   ```
   This will restore rules and sections to match your Terraform configuration.

2. **Alternatively, re-export and compare:**
   ```bash
   catocli export st_rules --json-filename all_st_rules_and_sections.json
   # Compare with your existing JSON file to identify changes
   ```

## Known Limitations

- Ordering rows with `section_name: ""` are excluded from the move resource
  and surfaced via `unordered_rules`; their order is creation order.
- Run applies with `-parallelism=1` when several module instances share an
  account.
- Only `cato_split_tunnel_rule`/`cato_split_tunnel_section` support import;
  `cato_bulk_st_move_rule` and the `cato_split_tunnel_policy` toggle are
  outside the JSON-driven import flow (see above).

## Using Module Outputs

The module's outputs are intentionally compact for this policy type - mapping
names to ids, basic deployment counts, and visibility into rows the move
resource can't order. Below are practical examples of using them.

<details>
<summary>Click to expand example client-side outputs</summary>

```hcl
# Basic deployment information
output "deployment_info" {
  description = "Basic information about the Split Tunnel deployment"
  value = {
    total_sections = module.st_rules.deployment_summary.sections
    total_rules    = module.st_rules.deployment_summary.rules
  }
}

# Quick reference for rule and section IDs
output "quick_reference" {
  description = "Quick reference maps for rules and sections"
  value = {
    section_ids = module.st_rules.section_ids
    rule_ids    = module.st_rules.rule_ids
  }
}

# Visibility into rules the move resource can't order
output "unordered_rules_report" {
  description = "Rules_in_sections rows outside any managed section (creation-order best-effort)"
  value       = module.st_rules.unordered_rules
}
```
</details>

### Output Use Cases

- **`deployment_info`**: Quick deployment overview for dashboards
- **`quick_reference`**: ID mappings for referencing resources in other modules
- **`unordered_rules_report`**: Flagging rules at the policy root (outside a section) whose order isn't guaranteed, so they can be reviewed or moved into a section

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 2.0.0-prerelease.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | >= 2.0.0-prerelease.1 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_bulk_st_move_rule.all_st_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/bulk_st_move_rule) | resource |
| [cato_split_tunnel_policy.policy](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/split_tunnel_policy) | resource |
| [cato_split_tunnel_rule.rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/split_tunnel_rule) | resource |
| [cato_split_tunnel_section.sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/split_tunnel_section) | resource |
| [terraform_data.guard_empty_policy](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_policy_enabled"></a> [policy\_enabled](#input\_policy\_enabled) | Manage the account-level Split Tunnel policy toggle. null leaves the toggle unmanaged; true/false manages it via cato\_split\_tunnel\_policy. | `bool` | `null` | no |
| <a name="input_st_rules_json_file_path"></a> [st\_rules\_json\_file\_path](#input\_st\_rules\_json\_file\_path) | Path to the Split Tunnel JSON export produced by `catocli export st_rules` (data.policy.splitTunnel.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed Split Tunnel objects. |
| <a name="output_rule_ids"></a> [rule\_ids](#output\_rule\_ids) | Map of rule name to rule id. |
| <a name="output_section_ids"></a> [section\_ids](#output\_section\_ids) | Map of section name to section id. |
| <a name="output_unordered_rules"></a> [unordered\_rules](#output\_unordered\_rules) | rules\_in\_sections rows excluded from cato\_bulk\_st\_move\_rule (no managed section to order within). |
<!-- END_TF_DOCS -->
