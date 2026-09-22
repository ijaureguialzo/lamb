#!/usr/bin/env bash
# LAMB Next -- lambctl.sh : idempotent deploy orchestrator.
# The .py fixers live locally but EXECUTE inside lamb-lamb-1 via docker cp+exec.
set -euo pipefail

CONTAINER="lamb-lamb-1"
COMPOSE_FILE="$(dirname "$0")/docker-compose.next.yaml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ADMIN_FIX="${SCRIPT_DIR}/apply_admin_fix.py"
OLLAMA_FIX="${SCRIPT_DIR}/apply_ollama_fix.py"

log() { echo "[lambctl] $*"; }

ensure_env() {
  local env_path="${SCRIPT_DIR}/.env"
  if [[ ! -f "${env_path}" ]]; then
    log ".env missing -- creating"
    OLLAMA=http://host.docker.internal:11434
    {
      echo "LAMB_WEB_HOST=http://localhost:9099"
      echo "LAMB_BACKEND_HOST=http://lamb:9099"
      echo "OWI_PATH=/data/openwebui"
      echo "OWI_BASE_URL=http://openwebui:8080"
      echo "LAMB_KB_SERVER=http://kb:9090"
      echo "OPENAI_BASE_URL=http://host.docker.internal:11434/v1"
      echo "OPENAI_MODEL=qwen3.6:35b-mlx"
      echo "OPENAI_MODELS=qwen3.6:35b-mlx,qwen3.8:27b-mlx,qwen3.6:27b-mlx,gemma4:31b-mlx"
      echo "OWI_ADMIN_NAME=Admin User"
      echo "OWI_ADMIN_EMAIL=admin@owi.com"
      echo "OWI_ADMIN_PASSWORD=b907ccba531351c359877602dd0dfa36"
      echo "OWI_PUBLIC_BASE_URL=http://localhost:8080"
      echo "SIGNUP_ENABLED=true"
      echo "DEV_MODE=true"
      echo "GLOBAL_LOG_LEVEL=DEBUG"
      echo "OLLAMA_BASE_URL=http://host.docker.internal:11434"
      echo "EMBEDDINGS_VENDOR=ollama"
      echo "EMBEDDINGS_MODEL=nomic-embed-text"
      echo "EMBEDDINGS_ENDPOINT=http://host.docker.internal:11434"
      echo "LAMB_KB_SERVER_TOKEN=0p3n-w3bu!"
       # bearer + library token share one secret for service interop
      echo "LAMB_BEARER_TOKEN=lamb-dev-shared-token"
      echo "LAMB_LIBRARY_TOKEN=lamb-dev-shared-token"
    } > "${env_path}"
  else
    log ".env exists -- enforcing local ollama values"
  fi
}

build() {
  log "building containers"
  docker compose -f "${COMPOSE_FILE}" build
}

up() {
  log "starting containers"
  docker compose -f "${COMPOSE_FILE}" up -d --force-recreate
  log "waiting for ${CONTAINER} healthy (max ~5 min)"
  for i in $(seq 1 60); do
    st="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${CONTAINER}" 2>/dev/null || echo unknown)"
    if [[ "${st}" == "healthy" ]]; then
      log "${CONTAINER} healthy"
      return 0
    fi
    if (( i % 6 == 0 )); then
      log "   still waiting (${i}/60, status=${st})"
    fi
    sleep 5
  done
  log "WARN not healthy in time -- continuing"
}

down() {
  log "stopping containers (volumes preserved)"
  docker compose -f "${COMPOSE_FILE}" down --remove-orphans
}

destroy() {
  log "removing containers + volumes + images"
  docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
}

run_admin_fix() {
  log "admin-fix: copy + run apply_admin_fix.py"
  docker cp "${ADMIN_FIX}" "${CONTAINER}:/tmp/apply_admin_fix.py"
     # OWI admin user materializes lazily; retry until the row exists.
  for i in $(seq 1 20); do
    if docker exec "${CONTAINER}" python3 /tmp/apply_admin_fix.py; then
      log "admin-fix ok"
      return 0
    fi
     # apply_admin_fix.py exits non-zero if the user row is not there yet
    if (( i % 5 == 0 )); then
      log "   user not materialized yet -- waiting (${i}/20)..."
    fi
    sleep 10
  done
  log "admin-fix: user still not materialized -- log in at OpenWebUI, then 'make admin-fix'"
  return 0
}

run_ollama_fix() {
  log "ollama-fix: copy + run apply_ollama_fix.py"
  docker cp "${OLLAMA_FIX}" "${CONTAINER}:/tmp/apply_ollama_fix.py"
  docker exec "${CONTAINER}" python3 /tmp/apply_ollama_fix.py
  log "ollama-fix ok"
}

rebuild() {
  ensure_env
  destroy
  up
  run_admin_fix
  run_ollama_fix
  status_
}

status_() {
  log "stack:"
  docker compose -f "${COMPOSE_FILE}" ps || true
  log "verifying admin role from DB"
  cat > /tmp/lamb_verify_roles.py <<'PY'
import sqlite3, json
c = sqlite3.connect("/data/lamb/lamb_v4.db")
cr = c.cursor()
cr.execute("SELECT role FROM LAMB_Creator_users WHERE id=1")
ur = cr.fetchone()
cr.execute("SELECT role FROM LAMB_organization_roles WHERE user_id=1")
orow = cr.fetchall()
creator = ur[0] if ur else None
ok = creator == "admin" and any(r[0] == "admin" for r in orow)
print("  LAMB_Creator_users.role  =", creator)
print("  LAMB_organization_roles  =", [r[0] for r in orow])
print("  ADMIN MENU WILL APPEAR   =", ok)
cr.execute("SELECT config FROM LAMB_organizations WHERE id=1")
row = cr.fetchone()
if row and row[0]:
    p = json.loads(row[0]).get("setups", {}).get("default", {}).get("providers", {})
    print("  openai.base_url          =", p.get("openai", {}).get("base_url"))
    print("  ollama.base_url          =", p.get("ollama", {}).get("base_url"))
c.close()
PY
  docker cp /tmp/lamb_verify_roles.py "${CONTAINER}:/tmp/lamb_verify_roles.py" 2>/dev/null || true
  docker exec "${CONTAINER}" python3 /tmp/lamb_verify_roles.py 2>/dev/null || true
}

usage() {
  cat <<USAGE
lambctl -- LAMB Next deploy orchestrator
  setup     env + up + admin-fix + ollama-fix   (default)
  build     build containers
  start     start containers + wait
  stop      stop containers (data preserved)
  clean.    remove containers + volumes
  admin-fix / ollama-fix   run a single fix
  rebuild   destroy + clean redeploy
  status    show stack + verify admin roles
USAGE
}

case "${1:-setup}" in
  setup|deploy) ensure_env; up; run_admin_fix; run_ollama_fix; status_;;
  up)           up;;
  down)         down;;
  build)         build;;
  destroy)      destroy;;
  admin-fix)    run_admin_fix;;
  ollama-fix)   run_ollama_fix;;
  rebuild)      rebuild;;
  status)       status_;;
  help|-h|*)    usage;;
esac
