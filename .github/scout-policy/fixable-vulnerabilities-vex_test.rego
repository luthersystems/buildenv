package docker.scout_test

import rego.v1
import data.docker.scout

vulns := {"statement": {"predicate": [
	{"purl": "pkg:golang/github.com/docker/docker@v28.0.0", "vulnerabilities": [
		{"source_id": "CVE-2026-34040", "cvss": {"severity": "HIGH"}, "fixed_by": "29.0.0"},
	]},
	{"purl": "pkg:pypi/urllib3@2.7.0", "vulnerabilities": [
		{"source_id": "CVE-2026-97689", "cvss": {"severity": "HIGH"}, "fixed_by": "2.8.0"},
	]},
	{"purl": "pkg:apk/alpine/openssl@3.3.7-r1?os_name=alpine", "vulnerabilities": [
		{"source_id": "CVE-2026-84782", "cvss": {"severity": "CRITICAL"}, "fixed_by": "3.3.7-r2"},
		{"source_id": "CVE-2026-1", "cvss": {"severity": "HIGH"}},
		{"source_id": "CVE-2026-2", "cvss": {"severity": "MEDIUM"}, "fixed_by": "x"},
	]},
]}}

vex_image_form := {"statement": {"predicate": {"statements": [
	{"vulnerability": {"name": "CVE-2026-34040"}, "status": "not_affected",
	 "products": [{"@id": "pkg:docker/luthersystems/build-godynamic", "subcomponents": [{"@id": "pkg:golang/github.com/docker/docker"}]}]},
	{"vulnerability": {"name": "CVE-2026-97689"}, "status": "not_affected",
	 "products": [{"@id": "pkg:docker/luthersystems/build-godynamic", "subcomponents": [{"@id": "pkg:pypi/urllib3@2.7.0"}]}]},
	# affected status must NOT waive
	{"vulnerability": {"name": "CVE-2026-84782"}, "status": "affected",
	 "products": [{"@id": "pkg:docker/luthersystems/x", "subcomponents": [{"@id": "pkg:apk/alpine/openssl"}]}]},
]}}}

vex_purl_form := {"statement": {"predicate": {"statements": [
	{"vulnerability": {"name": "CVE-2026-34040"}, "status": "not_affected",
	 "products": [{"@id": "pkg:golang/github.com/docker/docker@v28.0.0"}]},
]}}}

mock_none(_) := null

mock_image(t) := vulns if t == "https://scout.docker.com/vulnerabilities/v0.1"
mock_image(t) := vex_image_form if t == "https://openvex.dev/ns/v0.2.0"

mock_purl(t) := vulns if t == "https://scout.docker.com/vulnerabilities/v0.1"
mock_purl(t) := vex_purl_form if t == "https://openvex.dev/ns/v0.2.0"

mock_novex(t) := vulns if t == "https://scout.docker.com/vulnerabilities/v0.1"
mock_novex(t) := null if t == "https://openvex.dev/ns/v0.2.0"

ids(vs) := {v.detail.vulnerability | some v in vs}

test_no_vex_flags_all_fixable_ch if {
	got := ids(scout.violation) with oci.referrer as mock_novex with data.config as {}
	got == {"CVE-2026-34040", "CVE-2026-97689", "CVE-2026-84782"}
	not scout.pass with oci.referrer as mock_novex with data.config as {}
}

test_image_subcomponent_vex_waives if {
	got := ids(scout.violation) with oci.referrer as mock_image with data.config as {}
	got == {"CVE-2026-84782"} # affected-status statement does not waive
}

test_builtin_purl_form_still_waives if {
	got := ids(scout.violation) with oci.referrer as mock_purl with data.config as {}
	got == {"CVE-2026-97689", "CVE-2026-84782"}
}

test_wrong_version_subcomponent_does_not_waive if {
	not scout.purl_matches("pkg:pypi/urllib3@2.6.0", "pkg:pypi/urllib3@2.7.0")
	scout.purl_matches("pkg:pypi/urllib3", "pkg:pypi/urllib3@2.7.0?x=y")
	scout.purl_matches("pkg:pypi/urllib3@2.7.0", "pkg:pypi/urllib3@2.7.0?x=y")
	not scout.purl_matches("pkg:pypi/urllib3-extra", "pkg:pypi/urllib3@2.7.0")
}

test_non_image_product_with_subcomponent_does_not_waive if {
	not scout.product_covers({"@id": "pkg:pypi/foo", "subcomponents": [{"@id": "pkg:pypi/urllib3"}]}, "pkg:pypi/urllib3@2.7.0")
}

test_pass_when_all_waived if {
	scout.pass with oci.referrer as mock_image with data.config as {"severities": ["HIGH"]}
}
