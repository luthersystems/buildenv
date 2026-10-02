# buildenv copy of scout-cli v1.26.0's built-in `fixable-vulnerabilities`
# policy (#98). The ONLY change is the VEX match at the bottom. The built-in
# honors a not_affected statement only when the statement's product @id IS the
# vulnerable package purl. Our OpenVEX docs (.github/vex/) use the standard
# form instead: the IMAGE is the product, the package is a subcomponent. So the
# built-in ignored every waiver. policy-config.json disables the built-in and
# enables this one. Keep everything above the VEX block in sync with upstream
# when SCOUT_CLI_VERSION moves (`docker scout policy publish` dumps the set).

# METADATA
# title: No fixable critical or high vulnerabilities
# description: Flags packages with critical or high severity CVEs that already have a fix available, minus OpenVEX not_affected statements (product purl OR image product + subcomponent).
# custom:
#   name: fixable-vulnerabilities-vex
#   result_type: vulnerability
#   weight: 20
#   not_compliant_title: Fixable critical or high vulnerabilities found
#   details_order:
#   - purl
#   - vulnerability
#   - severity
#   - fixedBy
#   - cvssScore
package docker.scout

import rego.v1

default pass := false

pass if {
	count(violation) == 0
}

# Severities that count as a violation.
# Configurable via --policy-config: {"severities": ["CRITICAL", "HIGH"]}
severities := object.get(data.config, "severities", ["CRITICAL", "HIGH"])

# When enabled (the default) the policy only considers vulnerabilities that have
# a known fix. Set to false to also flag vulnerabilities without an available
# fix. Configurable via --policy-config: {"fixable_only": false}
fixable_only := object.get(data.config, "fixable_only", true)

# Optional allowlist of PURL package types to consider (e.g. "deb", "npm").
# When empty (the default) packages of every type are considered.
# Configurable via --policy-config: {"package_types": ["deb", "rpm"]}
package_types := object.get(data.config, "package_types", [])

# Number of days a newly disclosed CVE is exempt before it counts against the
# image. Defaults to 0 (no grace period).
# Configurable via --policy-config: {"grace_period_days": 14}
grace_ns := object.get(data.config, "grace_period_days", 0) * ((24 * 3600) * 1000000000)

violation contains v if {
	some entry in oci.referrer("https://scout.docker.com/vulnerabilities/v0.1").statement.predicate
	some cve in entry.vulnerabilities

	cve.cvss.severity in severities
	fixable_satisfied(cve)
	package_type_satisfied(entry.purl)

	not vex_not_affected(cve, entry.purl)
	not within_grace_period(cve)

	v := {
		"message": sprintf("Package %s is affected by %s", [entry.purl, cve.source_id]),
		"detail": {
			"purl": entry.purl,
			"vulnerability": cve.source_id,
			"severity": cve.cvss.severity,
			"fixedBy": object.get(cve, "fixed_by", ""),
			"cvssScore": sprintf("%.1f", [object.get(cve.cvss, "score", 0)]),
		},
	}
}

# A vulnerability satisfies the fixability filter when the policy is not limited
# to fixable issues, or when it has a known fix.
fixable_satisfied(_) if {
	not fixable_only
}

fixable_satisfied(cve) if {
	cve.fixed_by
}

# A package satisfies the package-type filter when no types are configured, or
# when its PURL type is in the configured list.
package_type_satisfied(_) if {
	count(package_types) == 0
}

package_type_satisfied(purl) if {
	count(package_types) > 0
	scout.parse_purl(purl).type in package_types
}

# A CVE is within the grace period when it was published less than
# grace_period_days ago. Only evaluated when a grace period is configured.
within_grace_period(cve) if {
	grace_ns > 0
	cve.published_at != ""
	published := time.parse_rfc3339_ns(cve.published_at)
	(time.now_ns() - published) < grace_ns
}

vex_not_affected(cve, purl) if {
	vex := oci.referrer("https://openvex.dev/ns/v0.2.0").statement.predicate
	some stmt in vex.statements
	stmt.status == "not_affected"
	stmt.vulnerability.name == cve.source_id
	some product in stmt.products
	product_covers(product, purl)
}

# Built-in behaviour: the product IS the vulnerable package.
product_covers(product, purl) if {
	product["@id"] == purl
}

# Standard OpenVEX image form: the product is an image (pkg:docker/...) and the
# vulnerable package is one of its subcomponents.
product_covers(product, purl) if {
	startswith(product["@id"], "pkg:docker/")
	some sub in product.subcomponents
	purl_matches(sub["@id"], purl)
}

# Same matching as the built-in copyleft policy's ignored_packages: an entry
# with qualifiers ("?") matches the full purl, an entry with a version ("@")
# matches the purl without qualifiers, and a bare entry matches the purl
# without version or qualifiers.
purl_matches(entry, purl) if {
	contains(entry, "?")
	entry == purl
}

purl_matches(entry, purl) if {
	not contains(entry, "?")
	contains(entry, "@")
	entry == split(purl, "?")[0]
}

purl_matches(entry, purl) if {
	not contains(entry, "?")
	not contains(entry, "@")
	entry == split(split(purl, "?")[0], "@")[0]
}
