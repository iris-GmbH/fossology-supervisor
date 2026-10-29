#!/usr/bin/env bash
# Exercise a prebuilt downstream image against an isolated external database.
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "Usage: $0 FOSSOLOGY_SUPERVISOR_IMAGE" >&2
  exit 2
fi
image=$1
timeout=${SMOKE_TIMEOUT:-240}
[[ $timeout =~ ^[1-9][0-9]*$ ]] || { echo 'SMOKE_TIMEOUT must be positive seconds' >&2; exit 2; }
command -v docker >/dev/null

work_dir=$(mktemp -d)
prefix="fossology-supervisor-smoke-$$"
network="$prefix-network"
database="$prefix-db"
app="$prefix-app"
diagnostic="$prefix-diagnostic"
db_password='smoke : spaces and punctuation!'

cleanup() {
  local status=$?
  trap - EXIT
  if ((status != 0)); then
    echo 'Smoke test failed; application logs follow:' >&2
    docker logs --tail 100 "$app" >&2 || true
    docker logs --tail 100 "$database" >&2 || true
    docker logs --tail 100 "$diagnostic" >&2 || true
  fi
  docker rm -fv "$app" "$database" "$diagnostic" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf -- "$work_dir"
  exit "$status"
}
trap cleanup EXIT

# Mount a probe without changing the image or its read-only root filesystem.
cat > "$work_dir/php-probe.php" <<'PHP'
<?php
// FOSSology includes top-level UI PHP files while discovering plugins.
if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') !== __FILE__) {
    return;
}
header('Content-Type: application/json');
echo json_encode([
    'sapi' => PHP_SAPI,
    'enabled' => ini_get('session.upload_progress.enabled'),
    'enabled_sid_registered' => array_key_exists('session.upload_progress.enabled_sid', ini_get_all()),
    'enabled_sid' => ini_get('session.upload_progress.enabled_sid'),
    'scanned' => php_ini_scanned_files(),
]);
PHP

chmod 0644 "$work_dir/php-probe.php"
chmod 0755 "$work_dir"

runtime_args=(
  --read-only --cap-drop ALL --security-opt no-new-privileges
  --tmpfs '/run/fossology:rw,nosuid,nodev,uid=10001,gid=10001,mode=0770'
  --tmpfs '/tmp:rw,nosuid,nodev,mode=1777'
  --tmpfs '/var/log/fossology:rw,nosuid,nodev,uid=10001,gid=10001,mode=0770'
  --tmpfs '/var/local/cache/fossology:rw,nosuid,nodev,uid=10001,gid=10001,mode=0770'
  --tmpfs '/var/local/lib/fossology:rw,nosuid,nodev,uid=10001,gid=10001,mode=0770'
  --tmpfs '/srv/fossology/repository:rw,nosuid,nodev,uid=10001,gid=10001,mode=0770'
  --mount "type=bind,src=$work_dir/php-probe.php,dst=/usr/local/share/fossology/www/ui/nonroot-smoke.php,readonly"
)

run_diagnostic() {
  local expected_exit=$1
  shift
  docker run -d --name "$diagnostic" --network none "${runtime_args[@]}" "$@" >/dev/null
  local deadline=$((SECONDS + 30))
  while [[ $(docker inspect --format '{{.State.Running}}' "$diagnostic") == true ]]; do
    ((SECONDS < deadline)) || { echo 'Diagnostic startup timed out without a database' >&2; return 1; }
    sleep 1
  done
  diagnostic_output=$(docker logs --tail 100 "$diagnostic" 2>&1)
  if [[ $(docker inspect --format '{{.State.ExitCode}}' "$diagnostic") != "$expected_exit" ]]; then
    printf 'Unexpected diagnostic exit status:\n%s\n' "$diagnostic_output" >&2
    return 1
  fi
  docker rm "$diagnostic" >/dev/null
}

docker image inspect "$image" >/dev/null
[[ $(docker image inspect --format '{{.Config.User}}' "$image") == 10001:10001 ]]

echo 'Checking diagnostic startup without a database and root rejection...'
run_diagnostic 0 "$image" php -r '
  exit(in_array(ini_get("session.upload_progress.enabled"), ["", "0"], true) &&
       extension_loaded("pgsql") ? 0 : 1);
'
run_diagnostic 1 --user 0:0 "$image" php -r 'exit(0);'
[[ $diagnostic_output == *'run as fossy (UID/GID 10001), not root'* ]]

echo 'Checking that the runtime PHP settings follow custom scan directories...'
mkdir "$work_dir/php-extra"
chmod 0755 "$work_dir/php-extra"
printf 'session.upload_progress.enabled = 1\n' > "$work_dir/php-extra/99-enable-upload.ini"
chmod 0644 "$work_dir/php-extra/99-enable-upload.ini"
# The variables below belong to PHP, not this shell.
# shellcheck disable=SC2016
run_diagnostic 0 \
  --mount "type=bind,src=$work_dir/php-extra,dst=/smoke-php-extra,readonly" \
  -e PHP_INI_SCAN_DIR=:/run/fossology/php-conf.d:/smoke-php-extra \
  "$image" php -r '
    $files = php_ini_scanned_files();
    $custom = strpos($files, "/smoke-php-extra/99-enable-upload.ini");
    $required = strrpos($files, "/run/fossology/php-conf.d/99-php2shell.ini");
    exit(in_array(ini_get("session.upload_progress.enabled"), ["", "0"], true) &&
         extension_loaded("pgsql") && $custom !== false && $required !== false &&
         $required > $custom ? 0 : 1);
  '

docker network create "$network" >/dev/null
docker run -d --name "$database" --network "$network" --network-alias postgres \
  -e POSTGRES_PASSWORD=smoke-postgres -e POSTGRES_DB=fossology \
  postgres:16 >/dev/null

deadline=$((SECONDS + timeout))
until docker exec "$database" pg_isready -U postgres -d fossology >/dev/null 2>&1; do
  ((SECONDS < deadline)) || { echo 'PostgreSQL startup timed out' >&2; exit 1; }
  sleep 1
done
docker exec "$database" psql -X -U postgres -v ON_ERROR_STOP=1 -d fossology \
  -c "CREATE ROLE fossy LOGIN PASSWORD '$db_password'" \
  -c 'ALTER DATABASE fossology OWNER TO fossy' \
  -c 'CREATE EXTENSION "uuid-ossp"' >/dev/null

start_app() {
  local entrypoint=${1:-}
  shift
  local args=(run -d --name "$app" --network "$network"
    "${runtime_args[@]}"
    -e FOSSOLOGY_DB_HOST=postgres -e FOSSOLOGY_DB_NAME=fossology
    -e FOSSOLOGY_DB_USER=fossy -e "FOSSOLOGY_DB_PASSWORD=$db_password"
    -e FOSSOLOGY_DB_WAIT_TIMEOUT=60)
  if [[ -n $entrypoint ]]; then
    args+=(--entrypoint "$entrypoint")
  fi
  docker "${args[@]}" "$image" "$@" >/dev/null
}

wait_for_health() {
  local deadline=$((SECONDS + timeout))
  local health
  until health=$(docker exec "$app" curl -fsS --max-time 5 \
      http://localhost:8080/repo/api/v1/health 2>/dev/null) &&
    printf '%s' "$health" | docker exec -i "$app" php -r '
      $health = json_decode(stream_get_contents(STDIN), true);
      exit(($health["status"] ?? "") === "OK" &&
           ($health["db"]["status"] ?? "") === "OK" &&
           ($health["scheduler"]["status"] ?? "") === "OK" ? 0 : 1);
    ' && supervisor_running; do
    ((SECONDS < deadline)) || { echo 'FOSSology health check timed out' >&2; return 1; }
    [[ $(docker inspect --format '{{.State.Running}}' "$app") == true ]] || return 1
    sleep 2
  done
}

supervisor_running() {
  docker exec "$app" supervisorctl status 2>/dev/null | awk '
    $1 == "web" && $2 == "RUNNING" {web=1}
    $1 == "scheduler" && $2 == "RUNNING" {scheduler=1}
    END {exit !(web && scheduler)}'
}

assert_php() {
  local sapi=$1
  docker exec -i "$app" php -r '
    $config = json_decode(stream_get_contents(STDIN), true);
    $valid = is_array($config) &&
      ($config["sapi"] ?? "") === $argv[1] &&
      in_array($config["enabled"], ["", "0"], true) &&
      (!$config["enabled_sid_registered"] || in_array($config["enabled_sid"], ["", "0"], true)) &&
      str_contains($config["scanned"] ?? "", "/run/fossology/php-conf.d/99-php2shell.ini");
    if (!$valid) { fwrite(STDERR, "Unexpected PHP settings: " . json_encode($config) . "\n"); }
    exit($valid ? 0 : 1);
  ' "$sapi"
}

check_app() {
  wait_for_health
  docker exec "$app" bash -ec '
    [[ $(id -u) == 10001 && $(id -g) == 10001 ]]
    # All real/effective/saved/filesystem IDs must remain unprivileged.
    awk '\''/^(Uid|Gid):/ && ($2 != 10001 || $3 != 10001 || $4 != 10001 || $5 != 10001) {
      print FILENAME ": " $0; invalid=1
    } END {exit invalid}'\'' /proc/[0-9]*/status
    grep -Eq "^max[[:space:]]*=[[:space:]]*4$" /usr/local/etc/fossology/mods-enabled/scancode/scancode.conf
    grep -Eq "^special\[\][[:space:]]*=[[:space:]]*NOKILL$" /usr/local/etc/fossology/mods-enabled/scancode/scancode.conf
    grep -Fx "session.upload_progress.enabled = 0" /run/fossology/php-conf.d/99-php2shell.ini
    grep -Fx "session.upload_progress.enabled_sid = 0" /run/fossology/php-conf.d/99-php2shell.ini
  ' >/dev/null
  docker exec "$app" php /usr/local/share/fossology/www/ui/nonroot-smoke.php | assert_php cli
  docker exec "$app" curl -fsS --max-time 5 http://localhost:8080/repo/nonroot-smoke.php | assert_php apache2handler
}

echo 'Checking fresh initialization and default non-root startup...'
start_app ''
check_app
licenses=$(docker exec "$database" psql -X -U postgres -d fossology -Atc 'SELECT count(*) FROM license_ref')
[[ $licenses =~ ^[0-9]+$ ]] && ((licenses > 0))

echo 'Checking restart with an existing schema and regenerated PHP settings...'
docker exec "$app" rm /run/fossology/php-conf.d/99-php2shell.ini
docker restart --time 30 "$app" >/dev/null
check_app
[[ $(docker exec "$database" psql -X -U postgres -d fossology -Atc 'SELECT count(*) FROM license_ref') == "$licenses" ]]

echo 'Checking the legacy startup path...'
docker rm -f "$app" >/dev/null
start_app /fossology/docker-entrypoint.sh all
check_app

echo 'Non-root Supervisor and PHP startup smoke checks passed.'
