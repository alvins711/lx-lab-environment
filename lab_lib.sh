#!/bin/bash
# lab_lib.sh
#
# Shared helpers for deploy_lab.sh and manage_users.sh. This file is meant to
# be sourced, not executed directly — it defines functions that rely on
# variables the calling script has already set: DYNAMIC_COMPOSE, USER_PREFIX,
# CPU_LIMIT, MEM_LIMIT, SSH_PASSWORD, ANTHROPIC_BASE_URL, ANTHROPIC_API_KEY,
# ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL.
#
# Having a single copy of the "dynamic compose file" layout means
# deploy_lab.sh and manage_users.sh can no longer drift out of sync with each
# other. Previously each script hand-rolled its own copy of this block, and
# manage_users.sh's copies silently omitted values that deploy_lab.sh's did
# not, so a user added later differed from a user created at initial deploy.

# Emit one docker-compose service block for a single student workstation.
#
# Secrets are only ever passed as runtime `environment:` values, never as
# build `args:` — build args get baked into the image's layer history and
# are recoverable from the image indefinitely (e.g. via `docker history`),
# even after rotation. Runtime environment values are not.
_emit_service_block() {
    local user_name="$1"
    cat <<EOF
  workstation_${user_name}:
    build:
      context: .
      dockerfile: Dockerfile.lab
    container_name: workstation_${user_name}
    hostname: workstation_${user_name}
    environment:
      - CLAUDE_CONFIG_DIR=/home/labuser/.claude
      - SSH_PASSWORD=${SSH_PASSWORD}
      - ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      - ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN}
      - ANTHROPIC_MODEL=${ANTHROPIC_MODEL}
    volumes:
      - ./workspaces/${user_name}:/home/labuser
      - ./claude_config/${user_name}:/home/labuser/.claude
    deploy:
      resources:
        limits:
          cpus: '${CPU_LIMIT}'
          memory: ${MEM_LIMIT}
    networks:
      - guac_lab_net
    restart: unless-stopped

EOF
}

# Rebuild $DYNAMIC_COMPOSE from scratch based on whichever
# ./workspaces/<USER_PREFIX>* folders currently exist on disk. Callers must
# set DYNAMIC_COMPOSE, USER_PREFIX, and the vars _emit_service_block needs
# before calling this.
rebuild_dynamic_compose() {
    : > "$DYNAMIC_COMPOSE"
    cat >> "$DYNAMIC_COMPOSE" <<EOF
networks:
  guac_lab_net:
    external: true

services:
EOF

    local folder num user_name
    for folder in ./workspaces/"${USER_PREFIX}"*; do
        [ -d "$folder" ] || continue
        num=$(basename "$folder" | sed "s/^${USER_PREFIX}//")
        user_name="${USER_PREFIX}${num}"
        _emit_service_block "$user_name" >> "$DYNAMIC_COMPOSE"
    done

    echo "volumes:" >> "$DYNAMIC_COMPOSE"
    for folder in ./workspaces/"${USER_PREFIX}"*; do
        [ -d "$folder" ] || continue
        num=$(basename "$folder" | sed "s/^${USER_PREFIX}//")
        echo "  claude_config_${USER_PREFIX}${num}:" >> "$DYNAMIC_COMPOSE"
    done
}
