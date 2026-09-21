#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Container variant of vm/www-apidocs.sh — DELIBERATELY UNIMPLEMENTED.
#
# www-apidocs has no Docker image / build target today, and unlike the other
# stubs here it is not obvious that it ever should have one: it is not an app
# at all in the Tomcat sense. It is an nginx location block plus a systemd
# oneshot that clones github.com/deployza/www-apidocs and runs `mkdocs build`
# on the host — see vm/www-apidocs.sh. None of that has a meaning inside an app
# container, which runs Tomcat as PID 1 with no nginx and no systemd.
#
# This file exists to keep this repo's own "when adding a new app" checklist
# honest (a docker/<app>.sh sibling for every vm/<app>.sh), as an explicit, loud
# stub rather than a silent gap or a guessed implementation with no Docker image
# to test it against. Its sibling docker/www-website.sh is a stub for the same
# reason.
#
# Nothing on the deploy path invokes this today: docker-startup.sh only runs
# docker/<APP_NAME>.sh inside a www-apidocs container image, and no such image
# exists. If containerised docs are ever wanted, the shape is almost certainly
# NOT this script — it is a build-time `mkdocs build` baked into a static-nginx
# image, with no deploy script at all.
# -----------------------------------------------------------------------------

echo "ERROR: docker/www-apidocs.sh has no implementation." >&2
echo "  www-apidocs has no Docker image/build target — it deploys only via" >&2
echo "  vm/www-apidocs.sh onto the 'nginx' GCE image family, where it needs" >&2
echo "  nginx and systemd. See this file's header comment before adding one." >&2
exit 1
