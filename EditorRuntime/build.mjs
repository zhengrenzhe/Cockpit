import { build } from 'esbuild';
import { createHash, randomUUID } from 'node:crypto';
import {
  access,
  cp,
  lstat,
  mkdir,
  readFile,
  readdir,
  realpath,
  rename,
  rm,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const runtimeRoot = resolve(fileURLToPath(new URL('.', import.meta.url)));
const dist = join(runtimeRoot, 'dist');
const bundleName = 'MonacoRuntime.bundle';
const output = join(dist, bundleName);
const stagingPrefix = `.${bundleName}.staging-`;
const retiredPrefix = `.${bundleName}.retired-`;
const ownerToken = `${process.pid}-${randomUUID()}`;
const staging = join(dist, `${stagingPrefix}${ownerToken}`);
const expectedFiles = ['editor.css', 'editor.js', 'editor.js.map', 'index.html'];
const canonicalRuntimeRoot = await realpath(runtimeRoot);
const expectedCanonicalDist = join(canonicalRuntimeRoot, 'dist');

if (dist !== resolve(runtimeRoot, 'dist')) {
  throw new Error(`unexpected dist output path: ${dist}`);
}
if (output !== resolve(runtimeRoot, 'dist', bundleName)) {
  throw new Error(`unexpected bundle output path: ${output}`);
}

async function metadata(path) {
  try {
    return await lstat(path);
  } catch (error) {
    if (error?.code === 'ENOENT') return undefined;
    throw error;
  }
}

async function requireLocalDist() {
  const stats = await metadata(dist);
  if (stats?.isSymbolicLink()) {
    throw new Error(`dist must not be a symbolic link: ${dist}`);
  }
  if (stats && !stats.isDirectory()) {
    throw new Error(`dist must be a directory: ${dist}`);
  }
  if (!stats) await mkdir(dist);
  const canonicalDist = await realpath(dist);
  if (canonicalDist !== expectedCanonicalDist) {
    throw new Error(`dist resolves outside the runtime: ${canonicalDist}`);
  }
}

async function rejectInitialOutputLink() {
  const stats = await metadata(output);
  if (stats?.isSymbolicLink()) {
    throw new Error(`bundle output must not be a symbolic link: ${output}`);
  }
}

async function runTestPause(name) {
  if (
    process.env.NODE_ENV !== 'test'
    || process.env.COCKPIT_BUILD_TEST_PAUSE !== name
  ) return;
  const hookDirectory = process.env.COCKPIT_BUILD_TEST_HOOK_DIR;
  if (!hookDirectory) throw new Error('test hook directory is required');
  const prefix = join(hookDirectory, `${process.pid}.${name}`);
  await writeFile(`${prefix}.ready`, 'ready\n');
  while (true) {
    try {
      await access(`${prefix}.continue`);
      return;
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    await delay(5);
  }
}

function injectTestFailure(name) {
  if (
    process.env.NODE_ENV === 'test'
    && process.env.COCKPIT_BUILD_TEST_FAIL === name
  ) throw new Error(`injected build failure ${name.replace('-', ' ')}`);
}

async function bundleSnapshot(path) {
  try {
    const stats = await lstat(path);
    if (stats.isSymbolicLink() || !stats.isDirectory()) return undefined;
    const files = (await readdir(path)).sort();
    if (files.length !== expectedFiles.length) return undefined;
    if (files.some((file, index) => file !== expectedFiles[index])) return undefined;
    const entries = [];
    for (const file of files) {
      const child = join(path, file);
      const childStats = await lstat(child);
      if (childStats.isSymbolicLink() || !childStats.isFile()) return undefined;
      const contents = await readFile(child);
      if (contents.length === 0) return undefined;
      entries.push({
        file,
        bytes: contents.length,
        sha256: createHash('sha256').update(contents).digest('hex'),
      });
    }
    return { files, entries };
  } catch (error) {
    if (error?.code === 'ENOENT') return undefined;
    throw error;
  }
}

function snapshotsEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function assertPrivateArtifactPath(path) {
  const name = basename(path);
  if (
    dirname(path) !== dist
    || (!name.startsWith(stagingPrefix) && !name.startsWith(retiredPrefix))
  ) throw new Error(`refusing to remove non-private build path: ${path}`);
}

async function removePrivateArtifact(path) {
  assertPrivateArtifactPath(path);
  const stats = await metadata(path);
  if (!stats) return;
  if (stats.isSymbolicLink() || !stats.isDirectory()) {
    await unlink(path);
    return;
  }
  await rm(path, { recursive: true, force: true });
}

function artifactOwnerPID(name) {
  const escapedBundleName = bundleName.replace('.', '\\.');
  const match = name.match(
    new RegExp(`^\\.${escapedBundleName}\\.(?:staging|retired)-(\\d+)-`),
  );
  return match ? Number(match[1]) : undefined;
}

function processIsAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === 'EPERM') return true;
    if (error?.code === 'ESRCH') return false;
    throw error;
  }
}

async function cleanupAbandonedArtifacts() {
  for (const name of await readdir(dist)) {
    if (!name.startsWith(stagingPrefix) && !name.startsWith(retiredPrefix)) continue;
    const path = join(dist, name);
    const stats = await metadata(path);
    if (!stats) continue;
    if (stats.isSymbolicLink()) {
      await removePrivateArtifact(path);
      continue;
    }
    const ownerPID = artifactOwnerPID(name);
    if (!processIsAlive(ownerPID)) await removePrivateArtifact(path);
  }
}

async function recoverPublishedBundle() {
  if (await metadata(output)) return;
  const candidates = [];
  for (const name of await readdir(dist)) {
    if (!name.startsWith(retiredPrefix)) continue;
    const path = join(dist, name);
    const stats = await metadata(path);
    if (!stats) continue;
    if (stats.isSymbolicLink()) {
      await removePrivateArtifact(path);
      continue;
    }
    candidates.push({ path, mtimeMs: stats.mtimeMs });
  }
  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
  for (const candidate of candidates) {
    if (!(await bundleSnapshot(candidate.path))) continue;
    try {
      await rename(candidate.path, output);
      return;
    } catch (error) {
      if (error?.code === 'ENOENT') continue;
      if (error?.code === 'EEXIST' || error?.code === 'ENOTEMPTY') return;
      throw error;
    }
  }
}

async function buildStagingBundle() {
  await mkdir(staging);
  await cp(join(runtimeRoot, 'src/index.html'), join(staging, 'index.html'));
  await build({
    entryPoints: [join(runtimeRoot, 'src/bootstrap.ts')],
    outfile: join(staging, 'editor.js'),
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: 'safari18',
    minify: true,
    sourcemap: 'external',
    legalComments: 'none',
    logLevel: 'info',
  });
  await unlink(join(staging, 'editor.css.map'));
  const snapshot = await bundleSnapshot(staging);
  if (!snapshot) throw new Error('staging bundle validation failed');
  return snapshot;
}

async function restoreRetiredBundle(retiredPaths) {
  if (await metadata(output)) return;
  for (let index = retiredPaths.length - 1; index >= 0; index -= 1) {
    const retired = retiredPaths[index];
    if (!(await bundleSnapshot(retired))) continue;
    try {
      await rename(retired, output);
      return;
    } catch (error) {
      if (error?.code === 'ENOENT') continue;
      if (error?.code === 'EEXIST' || error?.code === 'ENOTEMPTY') return;
      throw error;
    }
  }
}

async function publishStagingBundle(stagingSnapshot, retiredPaths) {
  await runTestPause('before-public-detach');
  for (let attempt = 0; attempt < 64; attempt += 1) {
    if (await metadata(output)) {
      const retired = join(
        dist,
        `${retiredPrefix}${ownerToken}-${attempt}-${randomUUID()}`,
      );
      try {
        await rename(output, retired);
        retiredPaths.push(retired);
      } catch (error) {
        if (error?.code === 'ENOENT') continue;
        if (error?.code === 'EEXIST') continue;
        throw error;
      }
    }

    try {
      await rename(staging, output);
      return true;
    } catch (error) {
      if (error?.code !== 'EEXIST' && error?.code !== 'ENOTEMPTY') throw error;
      const publishedSnapshot = await bundleSnapshot(output);
      if (publishedSnapshot && snapshotsEqual(publishedSnapshot, stagingSnapshot)) {
        return false;
      }
    }
  }
  throw new Error('unable to publish bundle after 64 atomic rename attempts');
}

await requireLocalDist();
await rejectInitialOutputLink();
await recoverPublishedBundle();
await cleanupAbandonedArtifacts();

const retiredPaths = [];
let stagingPublished = false;
try {
  const stagingSnapshot = await buildStagingBundle();
  injectTestFailure('before-publish');
  stagingPublished = await publishStagingBundle(stagingSnapshot, retiredPaths);
} catch (error) {
  await restoreRetiredBundle(retiredPaths);
  throw error;
} finally {
  if (!stagingPublished) await removePrivateArtifact(staging);
  for (const retired of retiredPaths) await removePrivateArtifact(retired);
}
