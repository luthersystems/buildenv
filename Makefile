# Root operator entry points — thin wrappers over scripts/ so repo logic is
# callable from make (image builds stay in images/Makefile: `cd images && make …`).

.PHONY: slack-test next-patch-version scout-setup scout-check docker-cli-check test-scripts scout-cli-install test-scout-policy

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

# Unit tests for the automation logic in scripts/*.cjs (node:test, no deps;
# needs Node >= 18). Also run in CI by build.yml's `script-tests` job.
test-scripts:
	node --test scripts/*.test.cjs

# Guard the Docker Scout policy config in .github/scout-policy and unit-test the
# VEX-only policy verdict (#98). Also run in CI by build.yml's `script-tests` job.
test-scout-policy:
	bash scripts/test-scout-policy.sh
	bash scripts/test-scout-policy-verdict.sh
