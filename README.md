# Salesforce Destructive Guard (Plug and Play)

Reusable CI product to block unsafe `destructiveChanges.xml` deployments in Salesforce pull requests.

## Included Product Core

- `/.github/workflows/destructive-dependency-check.yml` - reusable GitHub Actions gate
- `/scripts/dependency-check` - parser, dependency engine, policy evaluator
- `/scripts/shell/sf-jwt-auth.sh` - auth URL login with retry + `sf org display` verification
- `/package.json` - runtime dependencies

## Required GitHub Secrets

- `SF_AUTH_URL` (SFDX auth URL string)

## Authentication Mode

- Uses `sf org login sfdx-url` with `SF_AUTH_URL`
- Verifies session and org context using `sf org display --verbose --json`
- Retries authentication up to 3 attempts with backoff

## Runtime Outputs

- `dependency-report.json`
- `dependency-report.md`
- `dependency-metrics.json`
- `audit-evidence/*`

## Cache Controls

- `DEP_CACHE_VERSION` - cache invalidation version
- `DEP_CACHE_MAX_FILES` - max cache files (default `250`)
- `DEP_CACHE_MAX_AGE_DAYS` - stale cache TTL (default `30`)

## Local Run

Prerequisite: Node.js LTS + npm installed.

```powershell
npm install
node scripts/dependency-check/check-destructive-dependencies.js --changed-files changed-files.txt
```

## Org Validation Pipeline

- Workflow: `.github/workflows/salesforce-org-validation.yml`
- Auth: uses `SF_AUTH_URL` repository secret
- Mode: check-only deploy (`--dry-run`) against your org
- Source: `src/salesforce/force-app`
- Artifacts: `reports/org-validation-result.json`

### Dummy metadata included for validation

- Field: `Account.Dummy_Validation_Field__c`
- Access assignment: `permissionsets/Dummy_Validation.permissionset-meta.xml`

### Trigger validation now

- Open PR from `dev` to `main` with these metadata files, or
- Run workflow manually from GitHub Actions (`workflow_dispatch`).
