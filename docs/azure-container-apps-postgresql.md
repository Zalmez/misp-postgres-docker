# MISP 2.5.48 with PostgreSQL on Azure Container Apps

This fork is based on `misp-docker` commit `d2b82533d5335b2ff81eb7a8548757bbdbf4076c` and pins MISP `v2.5.48` at build time. PostgreSQL is a fresh-install path only. It does not migrate MySQL data.

## Image interface

Set `DB_ENGINE=postgres` and provide `POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DATABASE`. Optional values are `POSTGRES_PORT` (default `5432`), `POSTGRES_SCHEMA` (default `public`), `POSTGRES_SSLMODE` (default `verify-full`), and `POSTGRES_SSLROOTCERT` (default system CA bundle). The password is written to the mounted `database.php` with PHP serialization and is never placed in a command line.

Use the same image in two modes:

- App: `MISP_CONTAINER_MODE=server` (default). It requires an initialized schema and never imports or migrates it.
- Job: `MISP_CONTAINER_MODE=bootstrap`. It takes a PostgreSQL advisory lock, rejects partial schemas, imports `POSTGRESQL.sql` only into an empty schema, runs `Admin runUpdates`, initializes the first user only on a fresh database, and verifies `migrationStatus`.

Network-heavy galaxy, taxonomy, warning-list, notice-list, and object-template refreshes are excluded from the migration critical path. Set `MISP_BOOTSTRAP_UPDATE_COMPONENTS=true` only for a separately monitored bootstrap execution when those refreshes are required.

PostgreSQL uses the Default correlation engine. On Demand correlation, search benchmarking, and `schemaDiagnostics` are not supported by MISP 2.5.48. Use `Admin verifyInstallBaseline` and `Admin migrationStatus` where appropriate.

## Build and local verification

```bash
docker build --platform linux/amd64 \
  --build-arg CORE_TAG=v2.5.48 \
  --build-arg CORE_FLAVOR=slim \
  --build-arg PHP_API_VERSION=20240924 \
  --build-arg PHP_PACKAGE_VERSION=8.4 \
  --build-arg PYPI_SETUPTOOLS_VERSION='==84.0.0' \
  --build-arg PYPI_SUPERVISOR_VERSION='==4.3.0' \
  -t misp-core-postgres:v2.5.48 core

cp template.env .env
docker compose -f docker-compose.yml -f docker-compose.postgres.yml up -d db redis
docker compose -f docker-compose.yml -f docker-compose.postgres.yml \
  --profile bootstrap run --rm misp-bootstrap
docker compose -f docker-compose.yml -f docker-compose.postgres.yml up -d
```

Rerun the bootstrap command to verify idempotence. To test lock serialization, launch two bootstrap runs concurrently; the second waits for the advisory lock. Remove local test data only after confirming it is disposable:

```bash
docker compose -f docker-compose.yml -f docker-compose.postgres.yml down -v
```

## Azure topology and ordering

Use one single-revision Container App with the custom core container and version-matched Nginx sidecar. Route external HTTPS ingress to Nginx HTTP; Nginx reaches FPM on shared `localhost:9002`. Keep `min_replicas = 1` and `max_replicas = 1` while workers and scheduler are bundled. A manually triggered Container Apps Job uses the exact same immutable core image digest in bootstrap mode.

Deploy in this order:

1. Back up and test restoration of PostgreSQL and persistent MISP data.
2. Build AMD64 core and Nginx images from `v2.5.48`, push to ACR, and resolve immutable digests.
3. Apply only references, secret bindings, storage registrations/mounts, the inactive app revision, and the manual job.
4. Start the job with `az containerapp job start`, record the execution name, and wait for a successful terminal state.
5. Activate the app revision only after the job succeeds; verify FPM-backed readiness through Nginx.
6. For upgrades, drain workers/scheduler first. Restore the database backup for an incompatible schema failure; reverting only the image is not rollback.

## Upgrade runbook

Do not change `CORE_TAG` on a running container or let the app update itself. Build a new immutable image, test it against a restored backup, run the bootstrap job, and then move the app to the new digest.

### 1. Review and record

Read the target MISP release notes and PostgreSQL guide. Record the current app image digest, migration status, and database backup identifier. Check whether the release adds migrations, changes submodules, raises PHP/PostgreSQL requirements, or changes the PostgreSQL support limitations.

```bash
export FROM_VERSION=v2.5.47
export TO_VERSION=v2.5.48

docker exec <current-core-container> \
  sudo -E -u www-data /var/www/MISP/app/Console/cake Admin migrationStatus --json \
  > "migration-status-${FROM_VERSION}.json"
```

Create a PostgreSQL backup and verify that it can be restored to a separate database before proceeding. Also back up the persistent MISP configuration, attachments, and GPG volumes. Never test an upgrade against the only copy of production data.

For `v2.5.48`, upstream states that the schema is unchanged from `v2.5.47`, no migration ships, and no submodule pointer moved. It is still a security release and should follow the complete validation and rollout process.

### 2. Build and inspect

Build from the explicit MISP release tag. Do not reuse an image layer built with a different `CORE_TAG`.

```bash
docker build --pull --platform linux/amd64 \
  --build-arg CORE_TAG="${TO_VERSION}" \
  --build-arg CORE_FLAVOR=slim \
  --build-arg PHP_API_VERSION=20240924 \
  --build-arg PHP_PACKAGE_VERSION=8.4 \
  --build-arg PYPI_SETUPTOOLS_VERSION='==84.0.0' \
  --build-arg PYPI_SUPERVISOR_VERSION='==4.3.0' \
  -t "misp-core-postgres:${TO_VERSION}" core

docker run --rm --entrypoint jq "misp-core-postgres:${TO_VERSION}" \
  -er '.major == 2 and .minor == 5 and .hotfix == 48' /var/www/MISP/VERSION.json
docker run --rm --entrypoint sh "misp-core-postgres:${TO_VERSION}" -c '
  php -m | grep -Fx pdo_pgsql
  php-fpm -i 2>/dev/null | grep "PDO drivers" | grep -q pgsql
  test -s /var/www/MISP/INSTALL/POSTGRESQL.sql
'
```

Run the local PostgreSQL lifecycle against disposable volumes: fresh bootstrap, bootstrap rerun, app startup, login/API smoke tests, event and attribute creation, Default correlation, publication, Redis sessions, one worker job, and one scheduler task.

### 3. Test the upgrade path

Restore the production backup to an isolated PostgreSQL 16 database and point the new image's bootstrap mode at that database. Do not import `POSTGRESQL.sql`; bootstrap detects the existing MISP schema and runs only updates and idempotent configuration.

```bash
export MISP_CORE_IMAGE="misp-core-postgres:${TO_VERSION}"
docker compose -f docker-compose.yml -f docker-compose.postgres.yml \
  --profile bootstrap run --rm misp-bootstrap
docker compose -f docker-compose.yml -f docker-compose.postgres.yml up -d
```

Require `migrationStatus` to show no failed, pending, or orphaned migration before promoting the image. For a release with migrations, also inspect `migrationApply --dry-run` and its PostgreSQL rendering before running bootstrap.

### 4. Publish and pin

Publish a versioned tag, then use the returned digest for every app and job reference. Never deploy `latest`.

```bash
export ACR_NAME=socprodacr402ng
export ACR_SERVER=socprodacr402ng.azurecr.io
export SOURCE_REVISION=$(git rev-parse --short=12 HEAD)
export IMAGE_TAG="${TO_VERSION}-${SOURCE_REVISION}"

az acr login --name "${ACR_NAME}" --subscription 1cf38666-898d-4461-9f6f-3bc1e66360c0
docker tag "misp-core-postgres:${TO_VERSION}" \
  "${ACR_SERVER}/misp-core-postgres:${IMAGE_TAG}"
docker push "${ACR_SERVER}/misp-core-postgres:${IMAGE_TAG}"

az acr repository show-tags --name "${ACR_NAME}" \
  --repository misp-core-postgres --detail \
  --query "[?name=='${IMAGE_TAG}'].digest | [0]" -o tsv
```

Set `MISP_CORE_IMAGE` to `repository@sha256:digest` for Compose. Use the same digest for the ACA bootstrap job and app revision.

### 5. Roll out

1. Stop or drain the old app revision so workers and scheduler cannot overlap with the upgrade job.
2. Start the manually triggered bootstrap job using the new digest.
3. Wait for the job execution to succeed and archive its logs and migration status.
4. Activate one app replica using the same digest.
5. Verify readiness through Nginx, version, login/API, secure sessions, event workflows, Default correlation, publication, workers, scheduler, Redis, and persistent files/GPG identity.
6. Monitor migration diagnostics and application errors before removing the old revision.

If bootstrap fails before a schema change, correct the cause and rerun it. If any migration changed the database incompatibly, stop the new revision and restore the pre-upgrade database and persistent-data backups before using the old image. Switching only the image digest is not a database rollback.

Do not put PostgreSQL data on an ACA file share. Persist MISP configuration, attachments, and GPG material with least-privilege ownership; caches, sockets, and runtime files remain ephemeral. Mount an Azure PostgreSQL CA only when a private CA requires it; public Flexible Server certificates validate against the system bundle with `verify-full` and the server hostname.

## Terraform boundary

This repository contains no Terraform configuration, backend, provider lock, CAE identifiers, storage registration, ACR, identity, Key Vault, PostgreSQL, Redis, DNS, or workload-profile definitions. Adding guessed resources here would risk duplicate ownership and replacement of live infrastructure. The infrastructure repository must supply these verified inputs before Terraform can be implemented safely:

- Existing CAE resource ID, resource group, location, workload profile, and Terraform state ownership.
- Existing environment storage registration names, Azure Files share names, SMB/NFS type, mount options, and required paths.
- ACR login server and the user-assigned identity with `AcrPull` authorization.
- PostgreSQL FQDN/database/role, private DNS path, and secret-reference names.
- Redis endpoint, TLS/auth mode, persistence, and secret-reference names.
- Key Vault secret references and the identity authorized to resolve them.
- Canonical `BASE_URL`, ingress policy, trusted proxy ranges, and custom DNS/certificate ownership.

Use `data` sources or input resource IDs for resources owned by other states. Never import or recreate the CAE/storage implicitly. Prefer ACA Key Vault secret references; do not read secret values into Terraform state. Terraform must create an initially inactive revision or keep the app absent until the bootstrap job execution succeeds, because `depends_on` cannot model job completion.

## Production checks

After authorized deployment, verify DNS and TLS from both app and job, persistent mount ownership, secure cookies and redirects, login/API/event/attribute/publication flows, Default correlation, a background job, a scheduler task, Redis sessions/workers, and FPM-backed readiness/liveness. MISP 2.5.48 PostgreSQL support has no full upstream CI or scale-performance qualification, so startup alone is not production readiness.