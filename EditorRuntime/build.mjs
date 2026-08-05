import { build } from 'esbuild';
import { execFile } from 'node:child_process';
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
  rmdir,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { basename, dirname, join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const runFile = promisify(execFile);
const runtimeRoot = resolve(fileURLToPath(new URL('.', import.meta.url)));
const dist = join(runtimeRoot, 'dist');
const bundleName = 'MonacoRuntime.bundle';
const output = join(dist, bundleName);
const stagingPrefix = `.${bundleName}.staging-`;
const retiredPrefix = `.${bundleName}.retired-`;
const quarantinePrefix = `.${bundleName}.quarantine-`;
const ownerManifestSuffix = '.owner.json';
const ownerToken = `${process.pid}-${randomUUID()}`;
const staging = join(dist, `${stagingPrefix}${ownerToken}`);
const expectedFiles = ['editor.css', 'editor.js', 'editor.js.map', 'index.html'];
const stagingFileAllowlist = new Set([...expectedFiles, 'editor.css.map']);
const canonicalRuntimeRoot = await realpath(runtimeRoot);
const expectedCanonicalDist = join(canonicalRuntimeRoot, 'dist');
const processIdentityCache = new Map();

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

async function processStartIdentity(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return undefined;
  if (processIdentityCache.has(pid)) return processIdentityCache.get(pid);
  let identity;
  try {
    const { stdout } = await runFile(
      '/bin/ps',
      ['-o', 'lstart=', '-p', String(pid)],
      { encoding: 'utf8', maxBuffer: 4_096 },
    );
    identity = stdout.trim() || undefined;
  } catch (error) {
    if (typeof error?.code !== 'number') throw error;
  }
  processIdentityCache.set(pid, identity);
  return identity;
}

const ownerProcessStartIdentity = await processStartIdentity(process.pid);
if (!ownerProcessStartIdentity) {
  throw new Error(`cannot determine process start identity for PID ${process.pid}`);
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

function ownerManifestPath(path) {
  return `${path}${ownerManifestSuffix}`;
}

function isPrivateArtifactPath(path) {
  if (dirname(path) !== dist) return false;
  const name = basename(path);
  return (
    !name.endsWith(ownerManifestSuffix)
    && (
      name.startsWith(stagingPrefix)
      || name.startsWith(retiredPrefix)
      || name.startsWith(quarantinePrefix)
    )
  );
}

function assertPrivateArtifactPath(path) {
  if (!isPrivateArtifactPath(path)) {
    throw new Error(`refusing to operate on non-private build path: ${path}`);
  }
}

function manifestMatchesPath(manifest, path) {
  const name = basename(path);
  if (name === manifest.artifactName) return true;
  return name.startsWith(
    `${quarantinePrefix}${manifest.kind}-${manifest.ownerToken}-`,
  );
}

function validOwnershipManifest(manifest, path) {
  if (!manifest || typeof manifest !== 'object') return false;
  if (manifest.version !== 1) return false;
  if (manifest.kind !== 'staging' && manifest.kind !== 'retired') return false;
  if (!Number.isSafeInteger(manifest.pid) || manifest.pid <= 0) return false;
  if (typeof manifest.processStartIdentity !== 'string') return false;
  if (typeof manifest.ownerToken !== 'string') return false;
  if (typeof manifest.artifactName !== 'string') return false;
  if (typeof manifest.device !== 'string' || typeof manifest.inode !== 'string') return false;
  const expectedPrefix = manifest.kind === 'staging' ? stagingPrefix : retiredPrefix;
  if (!manifest.artifactName.startsWith(`${expectedPrefix}${manifest.ownerToken}`)) return false;
  return manifestMatchesPath(manifest, path);
}

async function readOwnershipManifest(path, sidecar = ownerManifestPath(path)) {
  const sidecarStats = await metadata(sidecar);
  if (!sidecarStats || sidecarStats.isSymbolicLink() || !sidecarStats.isFile()) {
    return undefined;
  }
  try {
    const manifest = JSON.parse(await readFile(sidecar, 'utf8'));
    return validOwnershipManifest(manifest, path) ? manifest : undefined;
  } catch (error) {
    if (error instanceof SyntaxError || error?.code === 'ENOENT') return undefined;
    throw error;
  }
}

function artifactIdentityMatches(stats, manifest) {
  return (
    String(stats.dev) === manifest.device
    && String(stats.ino) === manifest.inode
  );
}

async function verifiedOwnedArtifact(path, sidecar = ownerManifestPath(path)) {
  const manifest = await readOwnershipManifest(path, sidecar);
  if (!manifest) return undefined;
  const stats = await metadata(path);
  if (!stats || !artifactIdentityMatches(stats, manifest)) return undefined;
  return { manifest, stats };
}

async function writeOwnershipManifest(path, kind, stats) {
  const manifest = {
    version: 1,
    kind,
    pid: process.pid,
    processStartIdentity: ownerProcessStartIdentity,
    ownerToken,
    artifactName: basename(path),
    device: String(stats.dev),
    inode: String(stats.ino),
  };
  await writeFile(
    ownerManifestPath(path),
    `${JSON.stringify(manifest)}\n`,
    { encoding: 'utf8', flag: 'wx', mode: 0o600 },
  );
  return manifest;
}

async function removeManifestSidecar(path) {
  const sidecar = ownerManifestPath(path);
  const stats = await metadata(sidecar);
  if (!stats) return;
  if (stats.isDirectory()) {
    throw new Error(`ownership sidecar must not be a directory: ${sidecar}`);
  }
  await unlink(sidecar);
}

async function restoreDetachedArtifact(path, sidecar, quarantine, quarantineSidecar) {
  if ((await metadata(quarantine)) && !(await metadata(path))) {
    await rename(quarantine, path);
  }
  if ((await metadata(quarantineSidecar)) && !(await metadata(sidecar))) {
    await rename(quarantineSidecar, sidecar);
  }
}

async function quarantinePrivateArtifact(path, owned) {
  const { manifest } = owned;
  const sidecar = ownerManifestPath(path);
  const quarantine = join(
    dist,
    `${quarantinePrefix}${manifest.kind}-${manifest.ownerToken}-${randomUUID()}`,
  );
  const quarantineSidecar = ownerManifestPath(quarantine);
  await rename(path, quarantine);
  try {
    await rename(sidecar, quarantineSidecar);
  } catch (error) {
    await restoreDetachedArtifact(path, sidecar, quarantine, quarantineSidecar);
    throw error;
  }
  return { quarantine, quarantineSidecar };
}

async function cleanupPrivateSymlink(path) {
  const quarantine = join(
    dist,
    `${quarantinePrefix}symlink-${ownerToken}-${randomUUID()}`,
  );
  try {
    await rename(path, quarantine);
  } catch (error) {
    if (error?.code === 'ENOENT') return;
    throw error;
  }
  const stats = await metadata(quarantine);
  if (stats?.isSymbolicLink()) {
    await unlink(quarantine);
    await removeManifestSidecar(path);
    return;
  }
  if (stats && !(await metadata(path))) await rename(quarantine, path);
  throw new Error(`private symlink was replaced before unlink: ${path}`);
}

async function cleanupPrivateArtifact(path) {
  assertPrivateArtifactPath(path);
  const initialStats = await metadata(path);
  if (!initialStats) {
    await removeManifestSidecar(path);
    return;
  }
  if (initialStats.isSymbolicLink()) {
    await cleanupPrivateSymlink(path);
    return;
  }
  const owned = await verifiedOwnedArtifact(path);
  if (!owned) throw new Error(`private artifact ownership is not verified: ${path}`);
  await runTestPause('before-private-delete');
  const sidecar = ownerManifestPath(path);
  const { quarantine, quarantineSidecar } = await quarantinePrivateArtifact(path, owned);
  const detached = await verifiedOwnedArtifact(quarantine, quarantineSidecar);
  if (!detached) {
    await restoreDetachedArtifact(path, sidecar, quarantine, quarantineSidecar);
    throw new Error(`private artifact identity changed before cleanup: ${path}`);
  }

  if (!detached.stats.isDirectory()) {
    if (!detached.stats.isFile()) {
      await restoreDetachedArtifact(path, sidecar, quarantine, quarantineSidecar);
      throw new Error(`private artifact is not a regular file or directory: ${path}`);
    }
    await unlink(quarantine);
    await unlink(quarantineSidecar);
    return;
  }

  const files = await readdir(quarantine);
  const validatedFiles = [];
  for (const file of files) {
    const child = join(quarantine, file);
    const childStats = await lstat(child);
    if (!stagingFileAllowlist.has(file)) {
      await restoreDetachedArtifact(path, sidecar, quarantine, quarantineSidecar);
      throw new Error(`private artifact contains an unexpected entry: ${child}`);
    }
    if (childStats.isDirectory()) {
      await restoreDetachedArtifact(path, sidecar, quarantine, quarantineSidecar);
      throw new Error(`private artifact contains a child directory: ${child}`);
    }
    if (!childStats.isFile() && !childStats.isSymbolicLink()) {
      await restoreDetachedArtifact(path, sidecar, quarantine, quarantineSidecar);
      throw new Error(`private artifact contains a non-file entry: ${child}`);
    }
    validatedFiles.push(child);
  }
  for (const child of validatedFiles) await unlink(child);
  await rmdir(quarantine);
  await unlink(quarantineSidecar);
}

async function cleanupAbandonedArtifacts() {
  const names = await readdir(dist);
  for (const name of names) {
    if (name.endsWith(ownerManifestSuffix)) continue;
    const path = join(dist, name);
    if (!isPrivateArtifactPath(path)) continue;
    const stats = await metadata(path);
    if (!stats) continue;
    if (stats.isSymbolicLink()) {
      await cleanupPrivateSymlink(path);
      continue;
    }
    const owned = await verifiedOwnedArtifact(path);
    if (!owned) continue;
    const liveIdentity = await processStartIdentity(owned.manifest.pid);
    if (liveIdentity !== owned.manifest.processStartIdentity) {
      await cleanupPrivateArtifact(path);
    }
  }

  for (const name of names) {
    if (!name.endsWith(ownerManifestSuffix)) continue;
    const artifactName = name.slice(0, -ownerManifestSuffix.length);
    const path = join(dist, artifactName);
    if (!isPrivateArtifactPath(path) || (await metadata(path))) continue;
    const manifest = await readOwnershipManifest(path, join(dist, name));
    if (!manifest) continue;
    const liveIdentity = await processStartIdentity(manifest.pid);
    if (liveIdentity !== manifest.processStartIdentity) {
      await removeManifestSidecar(path);
    }
  }
}

async function recoverPublishedBundle() {
  if (await metadata(output)) return;
  const candidates = [];
  for (const name of await readdir(dist)) {
    if (!name.startsWith(retiredPrefix) || name.endsWith(ownerManifestSuffix)) continue;
    const path = join(dist, name);
    const stats = await metadata(path);
    if (!stats) continue;
    if (stats.isSymbolicLink()) {
      await cleanupPrivateSymlink(path);
      continue;
    }
    candidates.push({ path, mtimeMs: stats.mtimeMs });
  }
  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
  for (const candidate of candidates) {
    if (!(await bundleSnapshot(candidate.path))) continue;
    try {
      await rename(candidate.path, output);
      await removeManifestSidecar(candidate.path);
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
  await writeOwnershipManifest(staging, 'staging', await lstat(staging));
  await cp(join(runtimeRoot, 'src/index.html'), join(staging, 'index.html'));
  const entryPoint = (
    process.env.NODE_ENV === 'test'
    && process.env.COCKPIT_BUILD_TEST_ESBUILD_ENTRY
  )
    ? resolve(runtimeRoot, process.env.COCKPIT_BUILD_TEST_ESBUILD_ENTRY)
    : join(runtimeRoot, 'src/bootstrap.ts');
  await build({
    entryPoints: [entryPoint],
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
      await removeManifestSidecar(retired);
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
      } catch (error) {
        if (error?.code === 'ENOENT') continue;
        if (error?.code === 'EEXIST') continue;
        throw error;
      }
      await writeOwnershipManifest(retired, 'retired', await lstat(retired));
      retiredPaths.push(retired);
      await runTestPause('after-public-detach');
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
  if (stagingPublished) await removeManifestSidecar(staging);
  else await cleanupPrivateArtifact(staging);
  for (const retired of retiredPaths) await cleanupPrivateArtifact(retired);
}
