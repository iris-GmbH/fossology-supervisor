This image adds Supervisor to the non-root FOSSology base built by the parent
repository. Supervisor, Apache, the scheduler, and scan agents run as `fossy`
(`10001:10001`). Apache serves `/repo/` on port `8080`.

Build against a locally built base:

```sh
docker build --build-arg FOSSOLOGY_BASE_IMAGE=fossology-nonroot:base-only \
  -t fossology-supervisor:local .
bash tests/smoke.sh fossology-supervisor:local
```

The Dockerfile defaults to the parent GitLab pipeline's published base image.
Override `FOSSOLOGY_BASE_IMAGE` with its release tag or digest for deployment.
The GitHub publishing workflow accepts repository variables
`FOSSOLOGY_BASE_IMAGE` and `FOSSOLOGY_BASE_REGISTRY`, and needs secrets
`FOSSOLOGY_REGISTRY_USERNAME` and `FOSSOLOGY_REGISTRY_PASSWORD` with read access
to that registry.

Supply `FOSSOLOGY_DB_HOST`, `FOSSOLOGY_DB_NAME`, `FOSSOLOGY_DB_USER`, and
`FOSSOLOGY_DB_PASSWORD` for an external PostgreSQL database. The database role
must own the database and schema objects; provision `uuid-ossp` in that database
before starting the container. The base initializes or migrates the schema before
Supervisor starts Apache and the scheduler. `FOSSOLOGY_DB_PORT` defaults to
`5432`, and `FOSSOLOGY_DB_WAIT_TIMEOUT` to `120` seconds. ScanCode retains
`special[] = NOKILL` and `max = 4`.

The default command is `supervisor`; `all` is an alias. `web`, `scheduler`,
`init`, and diagnostic commands pass through to the base entrypoint. `web`
requires an initialized database. The old `/fossology/docker-entrypoint.sh`
path remains available. System cron is not started; run optional scheduled
maintenance separately.

For Kubernetes, set these container security settings:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
```

Use pod-level `securityContext.fsGroup: 10001` and writable `emptyDir` volumes
for `/run/fossology`, `/tmp`, `/var/log/fossology`, `/var/local/cache/fossology`,
and `/var/local/lib/fossology`. Mount the repository PVC at
`/srv/fossology/repository`; prepare existing files for read/write access by
UID/GID `10001:10001`. Point the Service's `targetPort` and HTTP probes at
`8080`. The smoke test exercises these restrictions with an isolated PostgreSQL
database, fresh initialization, restart, and the legacy startup path.

On every entrypoint invocation, including subsequent container starts,
`docker-entrypoint.sh` recreates `/run/fossology/php-conf.d/99-php2shell.ini`:

```ini
session.upload_progress.enabled = 0
session.upload_progress.enabled_sid = 0
```

`PHP_INI_SCAN_DIR=:/run/fossology/php-conf.d` retains each SAPI's normal
configuration and extensions, then reads this drop-in for Apache and CLI (and
FPM if installed). This avoids writing to root-owned, version-specific
`/etc/php/*/{apache2,fpm,cli}/conf.d` directories at startup. Keep the image's
entrypoint when overriding the command so that the file is refreshed.

Both requested lines are retained. Standard PHP does not register
`session.upload_progress.enabled_sid`; the effective control is
`session.upload_progress.enabled = 0`. This mitigates the session upload-progress
vector of CVE-2026-109619 only, as described in the
[PHP advisory](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp).
The smoke test verifies the drop-in and effective PHP settings in both CLI and
Apache after initial startup and restart.
