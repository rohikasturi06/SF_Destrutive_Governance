'use strict';

const { execFile } = require('child_process');

const DEFAULT_BATCH_SIZE = 20;
const DEFAULT_CONCURRENCY = 4;
const MAX_RETRIES = 3;

function chunkArray(items, batchSize) {
  const chunks = [];
  for (let i = 0; i < items.length; i += batchSize) {
    chunks.push(items.slice(i, i + batchSize));
  }
  return chunks;
}

function escapeSoql(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

function runSfQuery({ alias, query }) {
  return new Promise((resolve, reject) => {
    execFile(
      'sf',
      ['data', 'query', '--target-org', alias, '--query', query, '--use-tooling-api', '--json'],
      { maxBuffer: 10 * 1024 * 1024 },
      (error, stdout, stderr) => {
        if (error) {
          reject(new Error(`sf query failed: ${stderr || stdout || error.message}`));
          return;
        }
        try {
          const parsed = JSON.parse(stdout);
          const records = parsed.result && Array.isArray(parsed.result.records) ? parsed.result.records : [];
          resolve(records);
        } catch (parseError) {
          reject(new Error(`Unable to parse sf output: ${parseError.message}`));
        }
      }
    );
  });
}

async function runWithRetry(runFn, retries = MAX_RETRIES) {
  let lastError;
  for (let attempt = 1; attempt <= retries; attempt += 1) {
    try {
      return await runFn();
    } catch (error) {
      lastError = error;
      if (attempt < retries) {
        await new Promise((resolve) => setTimeout(resolve, attempt * 1000));
      }
    }
  }
  throw lastError;
}

function buildBatchQuery(batch, includeIsDependency = true) {
  const clauses = batch.map((component) => {
    const type = escapeSoql(component.type);
    const name = escapeSoql(component.name);
    return `(MetadataComponentType = '${type}' AND MetadataComponentName = '${name}')`;
  });

  const queryParts = [
    'SELECT MetadataComponentType, MetadataComponentName, RefMetadataComponentType, RefMetadataComponentName',
    'FROM MetadataComponentDependency',
    includeIsDependency ? 'WHERE IsDependency = true' : 'WHERE 1 = 1',
    `AND (${clauses.join(' OR ')})`,
    'ORDER BY RefMetadataComponentType, RefMetadataComponentName',
  ];

  return queryParts.join(' ');
}

async function mapLimit(items, limit, iteratee) {
  const results = [];
  let index = 0;

  async function worker() {
    while (index < items.length) {
      const current = index;
      index += 1;
      results[current] = await iteratee(items[current], current);
    }
  }

  const workers = Array.from({ length: Math.min(limit, items.length) }, () => worker());
  await Promise.all(workers);
  return results;
}

async function queryDependencies({ alias, components, batchSize = DEFAULT_BATCH_SIZE, concurrency = DEFAULT_CONCURRENCY }) {
  const batches = chunkArray(components, batchSize);
  const batchResults = await mapLimit(batches, concurrency, async (batch) => {
    const query = buildBatchQuery(batch, true);
    try {
      return await runWithRetry(() => runSfQuery({ alias, query }));
    } catch (error) {
      // Some orgs/tooling API versions do not expose IsDependency. Retry without that column filter.
      if (/IsDependency|No such column|MALFORMED_QUERY/i.test(error.message)) {
        const fallbackQuery = buildBatchQuery(batch, false);
        return runWithRetry(() => runSfQuery({ alias, query: fallbackQuery }));
      }
      throw error;
    }
  });

  const flattened = batchResults.flat();
  const seen = new Set();

  return flattened.filter((row) => {
    const key = [
      row.MetadataComponentType,
      row.MetadataComponentName,
      row.RefMetadataComponentType,
      row.RefMetadataComponentName,
    ].join('::');

    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
    return true;
  });
}

module.exports = {
  queryDependencies,
};
