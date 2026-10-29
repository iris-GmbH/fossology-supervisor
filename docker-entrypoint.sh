#!/bin/bash
# FOSSology docker-entrypoint script
# SPDX-FileCopyrightText: © 2016 Siemens AG
# SPDX-FileCopyrightText: © fabio.huser@siemens.com
# SPDX-FileCopyrightText: © 2016 TNG Technology Consulting GmbH
# SPDX-FileCopyrightText: © maximilian.huber@tngtech.com
#
# SPDX-License-Identifier: FSFAP
#
# Description: startup helper script for the FOSSology Docker container

set -o errexit -o nounset -o pipefail

if [[ $(id -u) == 0 ]]; then
  echo 'FOSSology supervisor: run as fossy (UID/GID 10001), not root' >&2
  exit 1
fi

# Refresh this on every start, including restarts with an existing /run volume.
# /etc/php remains read-only; PHP_INI_SCAN_DIR applies this to every PHP SAPI.
# This disables the session upload-progress vector of CVE-2026-109619 only.
umask 0007
php_ini_dir=/run/fossology/php-conf.d
mkdir -p "$php_ini_dir"
cat > "$php_ini_dir/99-php2shell.ini" <<'INI'
session.upload_progress.enabled = 0
session.upload_progress.enabled_sid = 0
INI
case "${PHP_INI_SCAN_DIR:-}" in
  "$php_ini_dir"|*":$php_ini_dir") ;;
  *) export PHP_INI_SCAN_DIR="${PHP_INI_SCAN_DIR:-}:$php_ini_dir" ;;
esac

case "${1:-supervisor}" in
  supervisor|all)
    # Initialize once before starting either service. Preserve the base's Apache
    # environment and private PostgreSQL passfile for Supervisor's children.
    exec /usr/local/bin/fossology-entrypoint init \
      /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
    ;;
  *) exec /usr/local/bin/fossology-entrypoint "$@" ;;
esac
