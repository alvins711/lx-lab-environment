#!/bin/bash
# entrypoint.sh
#
# NOT YET WIRED IN. Dockerfile.lab currently has an unresolved git merge
# conflict, so on purpose this script is not referenced by it yet. Once the
# conflict is resolved, wire it in with these three changes:
#
#   1. Remove the build-time secret injection from Dockerfile.lab:
#        - `ARG SSH_PASSWORD=password123` and the `RUN echo ... | chpasswd` line
#        - the `ARG ANTHROPIC_BASE_URL/API_KEY/AUTH_TOKEN/MODEL` block and the
#          `RUN printf ... >> /etc/environment` block that follows it
#      Both bake secrets into the image's layer history/filesystem for good —
#      recoverable via `docker history` or by anyone who gets a copy of the
#      image, and rotating a key requires a full rebuild.
#   2. Add, right before the final CMD:
#        COPY entrypoint.sh /usr/local/bin/entrypoint.sh
#        RUN chmod +x /usr/local/bin/entrypoint.sh
#   3. Replace the final line:
#        CMD ["/usr/sbin/sshd", "-D"]
#      with:
#        CMD ["/usr/local/bin/entrypoint.sh"]
#
# deploy_lab.sh and manage_users.sh (via lab_lib.sh) already pass
# SSH_PASSWORD and the ANTHROPIC_* values as runtime `environment:` entries,
# so no docker-compose changes are needed once the Dockerfile is wired up.
set -euo pipefail

# SSH sessions do not inherit the container's process environment, so the
# values a login shell needs are persisted to /etc/environment (read by
# pam_env for every login) — but at container *start*, not image *build* time.
{
    echo "CLAUDE_CONFIG_DIR=/home/labuser/.claude"
    echo "ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL:-}"
    echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
    echo "ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:-}"
    echo "ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-}"
} > /etc/environment
chmod 600 /etc/environment

# Likewise, set the account password from the runtime env var instead of
# baking it into the image at build time — rotating it becomes a container
# restart with a new SSH_PASSWORD, not an image rebuild.
if [ -n "${SSH_PASSWORD:-}" ]; then
    echo "labuser:${SSH_PASSWORD}" | chpasswd
fi

exec /usr/sbin/sshd -D
