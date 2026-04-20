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
          reject(new Error(`sf query failed: ${stderr || error.message}`));
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

function buildBatchQuery(batch) {
  const clauses = batch.map((component) => {
    const type = escapeSoql(component.type);
    const name = escapeSoql(component.name);
    return `(MetadataComponentType = '${type}' AND MetadataComponentName = '${name}')`;
  });

  return [
    'SELECT MetadataComponentType, MetadataComponentName, RefMetadataComponentType, RefMetadataComponentName',
    'FROM MetadataComponentDependency',
    'WHERE IsDependency = true',
    `AND (${clauses.join(' OR ')})`,
    'ORDER BY RefMetadataComponentType, RefMetadataComponentName',
  ].join(' ');
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
    const query = buildBatchQuery(batch);
    return runWithRetry(() => runSfQuery({ alias, query }));
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
