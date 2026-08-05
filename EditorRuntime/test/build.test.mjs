import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  symlink,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const runtimeRoot = new URL('../', import.meta.url);
const output = new URL('dist/MonacoRuntime.bundle/', runtimeRoot);
const runtimePath = fileURLToPath(runtimeRoot);
const distPath = fileURLToPath(new URL('dist', runtimeRoot));
const outputPath = fileURLToPath(new URL('dist/MonacoRuntime.bundle', runtimeRoot));
const runFile = promisify(execFile);
const expectedFiles = ['editor.css', 'editor.js', 'editor.js.map', 'index.html'];

async function runBuild() {
  await runFile(process.execPath, ['build.mjs'], {
    cwd: runtimePath,
    env: process.env,
  });
}

async function snapshotBundle() {
  const files = (await readdir(outputPath)).sort();
  const entries = await Promise.all(files.map(async (file) => {
    const contents = await readFile(join(outputPath, file));
    return {
      file,
      bytes: contents.length,
      sha256: createHash('sha256').update(contents).digest('hex'),
    };
  }));
  return { files, entries };
}

async function expectRejectedBuild(message) {
  await assert.rejects(runBuild, /symbolic link/i, message);
}

async function removeTestReplacement(path) {
  const metadata = await lstat(path);
  if (metadata.isSymbolicLink()) {
    await unlink(path);
    return;
  }
  await rm(path, { recursive: true, force: true });
}

test('package pins the exact runtime toolchain', async () => {
  const manifest = JSON.parse(
    await readFile(new URL('package.json', runtimeRoot), 'utf8'),
  );
  assert.equal(manifest.packageManager, 'pnpm@11.20.0');
  assert.deepEqual(manifest.engines, { node: '26.7.0', pnpm: '11.20.0' });
  assert.deepEqual(manifest.dependencies, { 'monaco-editor': '0.56.0' });
  assert.deepEqual(manifest.devDependencies, { esbuild: '0.28.1' });
  assert.equal(process.versions.node, '26.7.0');
  assert.match(process.env.npm_config_user_agent ?? '', /^pnpm\/11\.20\.0\b/);
});

test('build emits a self-contained local editor bundle', async () => {
  const html = await readFile(new URL('index.html', output), 'utf8');
  const js = await readFile(new URL('editor.js', output), 'utf8');
  const css = await readFile(new URL('editor.css', output), 'utf8');
  const sourceMap = JSON.parse(
    await readFile(new URL('editor.js.map', output), 'utf8'),
  );
  const source = await readFile(new URL('src/bootstrap.ts', runtimeRoot), 'utf8');
  const files = await readdir(output);
  const assetReferences = [
    ...html.matchAll(/\b(?:src|href)=["']([^"']+)["']/g),
  ].map((match) => match[1]).sort();

  assert.deepEqual(files.sort(), expectedFiles);
  assert.deepEqual(assetReferences, ['./editor.css', './editor.js']);
  assert.match(js, /cockpitEditorProtocol/);
  assert.match(js, /version:1/);
  assert.ok(js.length > 0);
  assert.ok(css.length > 0);
  assert.doesNotMatch(html, /(?:src|href)=["'](?:https?:|\/\/)/);
  assert.doesNotMatch(css, /(?:https?:|\/\/)[^\s)'";]*/);
  assert.doesNotMatch(source, /\b(?:fetch|WebSocket|EventSource)\s*\(/);
  assert.doesNotMatch(js, /\b(?:fetch|WebSocket|EventSource)\s*\(/);
  assert.ok(sourceMap.sources.every((sourcePath) => !isAbsolute(sourcePath)));
  assert.ok(sourceMap.sources.every((sourcePath) => !sourcePath.startsWith('file:')));
  assert.doesNotMatch(JSON.stringify(sourceMap), new RegExp(runtimePath));
  assert.match(source, /editor\/contrib\/find\/browser\/findController/);
  assert.match(source, /monaco\.editor\.getModel\(modelURI\)/);
  assert.match(source, /model\.setValue\(text\)/);
  assert.match(source, /model\.getLanguageId\(\) !== language/);
  assert.match(source, /monaco\.editor\.setModelLanguage\(model, language\)/);
});

test('two clean builds have identical files, sizes, and SHA-256 digests', async () => {
  await runBuild();
  const first = await snapshotBundle();
  await runBuild();
  const second = await snapshotBundle();

  assert.deepEqual(first.files, expectedFiles);
  assert.deepEqual(second, first);
});

test('build rejects a dist symbolic link without changing external bytes', async () => {
  const externalRoot = await mkdtemp(join(tmpdir(), 'cockpit-runtime-dist-link-'));
  const externalBundle = join(externalRoot, basename(outputPath));
  const sentinel = join(externalBundle, 'sentinel.txt');
  const sentinelContents = Buffer.from('dist-link-sentinel\n');
  const backup = join(runtimePath, `.dist-test-backup-${randomUUID()}`);

  await mkdir(externalBundle);
  await writeFile(sentinel, sentinelContents);
  await rename(distPath, backup);
  await symlink(externalRoot, distPath, 'dir');
  try {
    await expectRejectedBuild('build must reject a symbolic-link dist directory');
    assert.deepEqual(await readFile(sentinel), sentinelContents);
  } finally {
    await removeTestReplacement(distPath);
    await rename(backup, distPath);
    await rm(externalRoot, { recursive: true, force: true });
  }
});

test('build rejects an output symbolic link without changing external bytes', async () => {
  const externalRoot = await mkdtemp(join(tmpdir(), 'cockpit-runtime-output-link-'));
  const sentinel = join(externalRoot, 'sentinel.txt');
  const sentinelContents = Buffer.from('output-link-sentinel\n');
  const backup = join(distPath, `.bundle-test-backup-${randomUUID()}`);

  await writeFile(sentinel, sentinelContents);
  await rename(outputPath, backup);
  await symlink(externalRoot, outputPath, 'dir');
  try {
    await expectRejectedBuild('build must reject a symbolic-link output directory');
    assert.deepEqual(await readFile(sentinel), sentinelContents);
  } finally {
    await removeTestReplacement(outputPath);
    await rename(backup, outputPath);
    await rm(externalRoot, { recursive: true, force: true });
  }
});
