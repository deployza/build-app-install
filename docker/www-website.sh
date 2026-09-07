#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Container variant of vm/www-website.sh — DELIBERATELY UNIMPLEMENTED.
#
# www-website has no Docker image / build target today: it ships only on the
# `nginx` GCE image (build-vm-images/images/ubuntu/nginx/), deployed by
# vm/www-website.sh. This repo's own "when adding a new app" checklist calls
# for a docker/<app>.sh sibling for every vm/<app>.sh, so this file exists to
# keep that contract honest — as an explicit, loud stub rather than a silent
# gap or a guessed implementation with no Docker image to actually test it
# against.
#
# Nothing on the deploy path invokes this today: docker-startup.sh only runs
# docker/<APP_NAME>.sh inside a www-website container image, and no such image
# exists. If one is ever built, replace this stub with a real deploy script —
# most likely modeled on hundi-ui.sh/assess-ui.sh's "static WAR, no database"
# shape, but check build-vm-images/docs/website-nginx-plan.md first for
# whether the /docs/ MkDocs split (vm/www-website.sh's two additions over the
# ziniapps-www.sh template) needs a container-side equivalent at all.
# -----------------------------------------------------------------------------

echo "ERROR: docker/www-website.sh has no implementation." >&2
echo "  www-website has no Docker image/build target — it deploys only via" >&2
echo "  vm/www-website.sh onto the 'nginx' GCE image family. See this file's" >&2
echo "  header comment before adding one." >&2
exit 1
