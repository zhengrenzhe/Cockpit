import { build } from 'esbuild';
import {
  cp,
  lstat,
  mkdir,
  readdir,
  realpath,
  rmdir,
  unlink,
} from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const runtimeRoot = resolve(fileURLToPath(new URL('.', import.meta.url)));
const dist = join(runtimeRoot, 'dist');
const output = join(dist, 'MonacoRuntime.bundle');
const canonicalRuntimeRoot = await realpath(runtimeRoot);
const expectedCanonicalDist = join(canonicalRuntimeRoot, 'dist');
const expectedCanonicalOutput = join(expectedCanonicalDist, 'MonacoRuntime.bundle');

if (dist !== resolve(runtimeRoot, 'dist')) {
  throw new Error(`unexpected dist output path: ${dist}`);
}
if (output !== resolve(runtimeRoot, 'dist', 'MonacoRuntime.bundle')) {
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

async function requireLocalDirectory(path, expectedCanonicalPath, label) {
  const stats = await metadata(path);
  if (stats?.isSymbolicLink()) {
    throw new Error(`${label} must not be a symbolic link: ${path}`);
  }
  if (stats && !stats.isDirectory()) {
    throw new Error(`${label} must be a directory: ${path}`);
  }
  if (!stats) await mkdir(path);
  const canonicalPath = await realpath(path);
  if (canonicalPath !== expectedCanonicalPath) {
    throw new Error(`${label} resolves outside the runtime: ${canonicalPath}`);
  }
}

async function removePreviousBundle() {
  const stats = await metadata(output);
  if (!stats) return;
  if (stats.isSymbolicLink()) {
    throw new Error(`bundle output must not be a symbolic link: ${output}`);
  }
  if (!stats.isDirectory()) {
    throw new Error(`bundle output must be a directory: ${output}`);
  }
  const canonicalOutput = await realpath(output);
  if (canonicalOutput !== expectedCanonicalOutput) {
    throw new Error(`bundle output resolves outside the runtime: ${canonicalOutput}`);
  }

  for (const entry of await readdir(output)) {
    const child = join(output, entry);
    const childStats = await lstat(child);
    if (!childStats.isFile()) {
      throw new Error(`bundle output contains a non-file entry: ${child}`);
    }
    await unlink(child);
  }
  await rmdir(output);
}

await requireLocalDirectory(dist, expectedCanonicalDist, 'dist');
await removePreviousBundle();
await mkdir(output);
await requireLocalDirectory(output, expectedCanonicalOutput, 'bundle output');
await cp(join(runtimeRoot, 'src/index.html'), join(output, 'index.html'));
await build({
  entryPoints: [join(runtimeRoot, 'src/bootstrap.ts')],
  outfile: join(output, 'editor.js'),
  bundle: true,
  format: 'esm',
  platform: 'browser',
  target: 'safari18',
  minify: true,
  sourcemap: 'external',
  legalComments: 'none',
  logLevel: 'info',
});
await unlink(join(output, 'editor.css.map'));
