'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const core = require('@actions/core');
const { parseDestructiveXml } = require('./parse-destructive');
const { queryDependencies } = require('./dependency-engine');

function parseArgs() {
  const args = process.argv.slice(2);
  const options = {
    changedFiles: 'changed-files.txt',
    outputJson: 'dependency-report.json',
    outputMd: 'dependency-report.md',
    metricsJson: 'dependency-metrics.json',
    cacheDir: '.cache/dependency-check',
    auditDir: 'audit-evidence',
  };

  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--changed-files' && args[i + 1]) {
      options.changedFiles = args[i + 1];
    }
    if (args[i] === '--output-json' && args[i + 1]) {
      options.outputJson = args[i + 1];
    }
    if (args[i] === '--output-md' && args[i + 1]) {
      options.outputMd = args[i + 1];
    }
    if (args[i] === '--metrics-json' && args[i + 1]) {
      options.metricsJson = args[i + 1];
    }
    if (args[i] === '--cache-dir' && args[i + 1]) {
      options.cacheDir = args[i + 1];
    }
    if (args[i] === '--audit-dir' && args[i + 1]) {
      options.auditDir = args[i + 1];
    }
  }

  return options;
}

function getForceDeployOverride() {
  try {
    const labels = JSON.parse(process.env.PR_LABELS_JSON || '[]');
    return labels.some((label) => String(label.name || '').toLowerCase() === 'force-deploy');
  } catch (_err) {
    return false;
  }
}

function loadChangedFiles(filePath) {
  const resolved = path.resolve(filePath);
  if (!fs.existsSync(resolved)) {
    return [];
  }

  return fs
    .readFileSync(resolved, 'utf8')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function detectDestructiveFiles(changedFiles) {
  return changedFiles.filter((file) => /destructivechanges\.xml$/i.test(file));
}

function buildTypeSummary(components) {
  const counts = {};
  for (const component of components) {
    counts[component.type] = (counts[component.type] || 0) + 1;
  }
  return Object.entries(counts)
    .map(([type, count]) => ({ type, count }))
    .sort((a, b) => b.count - a.count || a.type.localeCompare(b.type));
}

function ensureDirectory(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function pruneCacheDirectory(cacheDir) {
  const maxFiles = Number(process.env.CACHE_MAX_FILES || 250);
  const maxAgeDays = Number(process.env.CACHE_MAX_AGE_DAYS || 30);
  const now = Date.now();
  const maxAgeMs = maxAgeDays * 24 * 60 * 60 * 1000;

  const entries = fs
    .readdirSync(cacheDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
    .map((entry) => {
      const fullPath = path.join(cacheDir, entry.name);
      const stat = fs.statSync(fullPath);
      return { fullPath, mtimeMs: stat.mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  for (const file of entries) {
    if (now - file.mtimeMs > maxAgeMs) {
      fs.rmSync(file.fullPath, { force: true });
    }
  }

  const remaining = fs
    .readdirSync(cacheDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name.endsWith('.json'))
    .map((entry) => {
      const fullPath = path.join(cacheDir, entry.name);
      const stat = fs.statSync(fullPath);
      return { fullPath, mtimeMs: stat.mtimeMs };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);

  if (remaining.length > maxFiles) {
    const toDelete = remaining.slice(maxFiles);
    for (const file of toDelete) {
      fs.rmSync(file.fullPath, { force: true });
    }
  }
}

function computeCacheKey({ alias, components }) {
  const normalized = components
    .map((c) => `${c.type}::${c.name}`)
    .sort()
    .join('|');
  return crypto
    .createHash('sha256')
    .update(`${alias}::${normalized}`, 'utf8')
    .digest('hex');
}

function buildMetrics({ destructiveFiles, components, dependencies, overrideEnabled, blocked, cacheHit }) {
  const byDeletedType = {};
  const byRefType = {};

  for (const component of components) {
    byDeletedType[component.type] = (byDeletedType[component.type] || 0) + 1;
  }
  for (const dep of dependencies) {
    const refType = dep.RefMetadataComponentType || 'Unknown';
    byRefType[refType] = (byRefType[refType] || 0) + 1;
  }

  const dependencyHotspots = Object.entries(byRefType)
    .map(([type, count]) => ({ type, count }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 10);

  return {
    scannedAt: new Date().toISOString(),
    destructiveFileCount: destructiveFiles.length,
    componentCount: components.length,
    dependencyCount: dependencies.length,
    overrideEnabled,
    blocked,
    cacheHit,
    byDeletedType,
    byRefType,
    dependencyHotspots,
    github: {
      repository: process.env.GITHUB_REPOSITORY || null,
      runId: process.env.GITHUB_RUN_ID || null,
      runNumber: process.env.GITHUB_RUN_NUMBER || null,
      workflow: process.env.GITHUB_WORKFLOW || null,
      sha: process.env.GITHUB_SHA || null,
      ref: process.env.GITHUB_REF || null,
    },
  };
}

function writeAuditBundle({ auditDir, report, markdownPath, jsonPath, metricsPath }) {
  ensureDirectory(auditDir);
  const summaryPath = path.join(auditDir, 'release-audit-summary.md');
  const summary = [
    '# Release Audit Evidence',
    '',
    `- Scanned at: ${report.scannedAt}`,
    `- Dependency count: ${report.dependencyCount}`,
    `- Override enabled: ${report.overrideEnabled}`,
    `- Blocked by policy: ${report.hasDependencies && !report.overrideEnabled}`,
    `- Cache hit: ${report.cacheHit}`,
    '',
    '## Inputs',
    ...report.destructiveFiles.map((f) => `- ${f}`),
  ].join('\n');

  fs.writeFileSync(summaryPath, summary);
  if (fs.existsSync(markdownPath)) {
    fs.copyFileSync(markdownPath, path.join(auditDir, path.basename(markdownPath)));
  }
  if (fs.existsSync(jsonPath)) {
    fs.copyFileSync(jsonPath, path.join(auditDir, path.basename(jsonPath)));
  }
  if (fs.existsSync(metricsPath)) {
    fs.copyFileSync(metricsPath, path.join(auditDir, path.basename(metricsPath)));
  }
}

function toMarkdown({ dependencies, overrideEnabled, parsedComponents, destructiveFiles }) {
  if (destructiveFiles.length === 0) {
    return [
      '## Salesforce Destructive Dependency Check',
      '',
      ':white_check_mark: No `destructiveChanges.xml` detected in this PR diff.',
    ].join('\n');
  }

  const header = [
    '## Salesforce Destructive Dependency Check',
    '',
    `Scanned destructive manifests: ${destructiveFiles.map((x) => `\`${x}\``).join(', ')}`,
    `Components analyzed: **${parsedComponents.length}**`,
    '',
  ];

  if (dependencies.length === 0) {
    header.push(':white_check_mark: No active dependencies found. Destructive change gate passed.');
    return header.join('\n');
  }

  const grouped = new Map();
  for (const dep of dependencies) {
    const key = dep.RefMetadataComponentType || 'Unknown';
    if (!grouped.has(key)) {
      grouped.set(key, []);
    }
    grouped.get(key).push(dep);
  }

  const lines = [
    ...header,
    `:x: Dependencies found: **${dependencies.length}**`,
    overrideEnabled
      ? ':warning: `force-deploy` label is present; workflow is allowed to continue by policy override.'
      : ':no_entry: Merge is blocked until dependencies are removed or refactored.',
    '',
    '| Deleted Component | Type | Referenced By | Ref Type |',
    '|---|---|---|---|',
  ];

  const sortedTypes = [...grouped.keys()].sort();
  for (const type of sortedTypes) {
    const rows = grouped.get(type).slice(0, 20);
    for (const row of rows) {
      lines.push(
        `| ${row.MetadataComponentName || '-'} | ${row.MetadataComponentType || '-'} | ${row.RefMetadataComponentName || '-'} | ${row.RefMetadataComponentType || '-'} |`
      );
    }

    const remaining = grouped.get(type).length - rows.length;
    if (remaining > 0) {
      lines.push(`| ... | ... | ${remaining} more dependencies in ${type} | ... |`);
    }
  }

  lines.push('', '### Action Required', '- Remove or refactor references before destructive deployment.', '- If this is an approved emergency change, add the `force-deploy` label with change-management approval.');

  return lines.join('\n');
}

function toExecutiveSummary({
  changedFiles,
  destructiveFiles,
  components,
  dependencies,
  report,
  metricsPath,
  reportPath,
  overrideEnabled,
}) {
  const typeSummary = buildTypeSummary(components);
  const lines = [
    '# Destructive Validation Executive Summary',
    '',
    `- Repository: ${process.env.GITHUB_REPOSITORY || 'local-run'}`,
    `- Run ID: ${process.env.GITHUB_RUN_ID || 'local-run'}`,
    `- PR Number: ${process.env.GITHUB_REF_NAME || 'n/a'}`,
    `- Scanned At: ${report.scannedAt}`,
    '',
    '## Validations Executed',
    '',
    '- PR diff changed-file analysis',
    '- Destructive manifest XML parsing',
    '- MetadataComponentDependency dependency validation',
    '- Blocking policy decision evaluation',
    '',
    '## Changed Files',
    '',
    '| File |',
    '|---|',
  ];

  if (changedFiles.length === 0) {
    lines.push('| No changed files detected |');
  } else {
    changedFiles.slice(0, 200).forEach((file) => lines.push(`| ${file} |`));
    if (changedFiles.length > 200) {
      lines.push(`| ... ${changedFiles.length - 200} more files |`);
    }
  }

  lines.push('', '## Destructive Manifest Summary', '');
  lines.push(`- Files detected: ${destructiveFiles.length}`);
  if (destructiveFiles.length > 0) {
    destructiveFiles.forEach((file) => lines.push(`- ${file}`));
  }

  lines.push('', `- Components parsed: ${components.length}`, '', '| Metadata Type | Members |', '|---|---:|');
  if (typeSummary.length === 0) {
    lines.push('| None | 0 |');
  } else {
    typeSummary.forEach((entry) => lines.push(`| ${entry.type} | ${entry.count} |`));
  }

  lines.push(
    '',
    '## Dependency Decision',
    '',
    `- Dependencies found: ${dependencies.length}`,
    `- Override label enabled: ${overrideEnabled}`,
    `- Merge blocked: ${dependencies.length > 0 && !overrideEnabled}`,
    `- Cache hit: ${report.cacheHit}`,
    '',
    '## Report References',
    '',
    `- Machine report: \`${reportPath}\``,
    `- Metrics report: \`${metricsPath}\``,
    '- Artifact bundle: `destructive-dependency-report`',
    ''
  );

  return lines.join('\n');
}

async function run() {
  const { changedFiles, outputJson, outputMd, metricsJson, cacheDir, auditDir } = parseArgs();
  const alias = process.env.SF_ALIAS || 'ci-org';
  const overrideEnabled = getForceDeployOverride();

  const changed = loadChangedFiles(changedFiles);
  const destructiveFiles = detectDestructiveFiles(changed);

  let parsedComponents = [];
  for (const destructiveFile of destructiveFiles) {
    if (!fs.existsSync(path.resolve(destructiveFile))) {
      // File may be renamed/deleted in diff; skip gracefully.
      continue;
    }
    const components = await parseDestructiveXml(destructiveFile);
    parsedComponents = parsedComponents.concat(components);
  }

  const uniqueComponents = [];
  const seen = new Set();
  for (const component of parsedComponents) {
    const key = `${component.type}::${component.name}`;
    if (!seen.has(key)) {
      seen.add(key);
      uniqueComponents.push(component);
    }
  }

  ensureDirectory(cacheDir);
  pruneCacheDirectory(cacheDir);
  let dependencies = [];
  let cacheHit = false;
  if (uniqueComponents.length > 0) {
    const cacheKey = computeCacheKey({ alias, components: uniqueComponents });
    const cachePath = path.join(cacheDir, `${cacheKey}.json`);
    if (fs.existsSync(cachePath)) {
      const cached = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
      dependencies = Array.isArray(cached.dependencies) ? cached.dependencies : [];
      cacheHit = true;
    } else {
      dependencies = await queryDependencies({ alias, components: uniqueComponents });
      fs.writeFileSync(
        cachePath,
        JSON.stringify(
          {
            cachedAt: new Date().toISOString(),
            alias,
            componentCount: uniqueComponents.length,
            dependencies,
          },
          null,
          2
        )
      );
    }
  }

  const blocked = dependencies.length > 0 && !overrideEnabled;
  const report = {
    scannedAt: new Date().toISOString(),
    destructiveFiles,
    componentsAnalyzed: uniqueComponents,
    dependencyCount: dependencies.length,
    dependencies,
    overrideEnabled,
    cacheHit,
    hasDependencies: dependencies.length > 0,
  };

  const metrics = buildMetrics({
    destructiveFiles,
    components: uniqueComponents,
    dependencies,
    overrideEnabled,
    blocked,
    cacheHit,
  });

  fs.writeFileSync(outputJson, JSON.stringify(report, null, 2));
  fs.writeFileSync(metricsJson, JSON.stringify(metrics, null, 2));
  fs.writeFileSync(outputMd, toMarkdown({ dependencies, overrideEnabled, parsedComponents: uniqueComponents, destructiveFiles }));
  fs.writeFileSync(
    'destructive-executive-summary.md',
    toExecutiveSummary({
      changedFiles: changed,
      destructiveFiles,
      components: uniqueComponents,
      dependencies,
      report,
      metricsPath: metricsJson,
      reportPath: outputJson,
      overrideEnabled,
    })
  );
  writeAuditBundle({
    auditDir,
    report,
    markdownPath: outputMd,
    jsonPath: outputJson,
    metricsPath: metricsJson,
  });

  core.setOutput('has_dependencies', String(report.hasDependencies));
  core.setOutput('override_enabled', String(overrideEnabled));
  core.setOutput('cache_hit', String(cacheHit));

  if (blocked) {
    core.setFailed('Dependencies detected for destructive changes.');
  }
}

run().catch((error) => {
  fs.writeFileSync(
    'dependency-report.md',
    ['## Salesforce Destructive Dependency Check', '', `:x: Workflow failed: ${error.message}`].join('\n')
  );
  fs.writeFileSync(
    'destructive-executive-summary.md',
    ['# Destructive Validation Executive Summary', '', `- Workflow failed: ${error.message}`].join('\n')
  );
  core.setFailed(error.message);
});
