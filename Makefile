# Root operator entry points — thin wrappers over scripts/ so repo logic is
# callable from make (image builds stay in images/Makefile: `cd images && make …`).

.PHONY: slack-test next-patch-version scout-setup scout-check docker-cli-check test-scripts scout-cli-install test-scout-grade test-ci-changes

# Send a test alert through scripts/slack-alert.sh to verify the Slack #alerts
# webhook wiring end-to-end. No-op (prints a skip) if SLACK_ALERT_WEBHOOK_URL
# is unset — set it from 1Password when testing locally; in CI it comes from
# the repo secret of the same name.
slack-test:
	bash scripts/slack-alert.sh "🔔 Test alert from buildenv (make slack-test, $$(whoami)) — SLACK_ALERT_WEBHOOK_URL wiring OK."

# Print the next patch release version (see scripts/next-patch-version.sh).
next-patch-version:
	bash scripts/next-patch-version.sh

# Reconcile Docker Scout repo enrollment with scout-required-images.json
# (idempotent; needs a `docker login` or DOCKER_SCOUT_HUB_USER/PASSWORD).
# scout-check is the report-only variant. See scripts/scout-setup.sh.
scout-setup:
	bash scripts/scout-setup.sh

scout-check:
	bash scripts/scout-setup.sh --check

# Report whether the from-source Docker CLI build can be retired yet -- i.e.
# whether Docker has published a CLI compiled with a Go at least as new as our
# GOLANG_VERSION. See scripts/docker-cli-source-build-check.sh for why the
# source build exists (#115) and what to do when this says RETIREABLE.
docker-cli-check:
	bash scripts/docker-cli-source-build-check.sh

# Install the pinned, checksum-verified Docker Scout CLI plugin the CI gates use
# (SCOUT_CLI_VERSION + sums in common.config.mk). See scripts/install-scout-cli.sh.
scout-cli-install:
	bash scripts/install-scout-cli.sh

# Check that every image Dockerfile runs images/distrust-emudhra.sh last
# (CVE-2026-111943). Also run in CI by build.yml's `script-tests` job.
.PHONY: check-distrust-emudhra
check-distrust-emudhra:
	bash scripts/check-distrust-emudhra.sh

# Unit tests for the automation logic in scripts/*.cjs (node:test, no deps;
# needs Node >= 18). Also run in CI by build.yml's `script-tests` job.
test-scripts:
	node --test scripts/*.test.cjs

# Unit-test the CI grade (scripts/scout-grade.sh) and the VEX-aware CVE gate
# with a fake docker; no network. Also run in CI by build.yml's `script-tests` job.
test-scout-grade:
	bash scripts/test-scout-grade.sh

# Unit-test the docs-only CI skip (scripts/ci-changes.sh). Also run in CI by
# build.yml's `script-tests` job.
test-ci-changes:
	bash scripts/test-ci-changes.sh
