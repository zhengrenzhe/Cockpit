import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import {
  access,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rename,
  rm,
  rmdir,
  symlink,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const runtimeRoot = new URL('../', import.meta.url);
const output = new URL('dist/MonacoRuntime.bundle/', runtimeRoot);
const runtimePath = fileURLToPath(runtimeRoot);
const distPath = fileURLToPath(new URL('dist', runtimeRoot));
const outputPath = fileURLToPath(new URL('dist/MonacoRuntime.bundle', runtimeRoot));
const expectedFiles = ['editor.css', 'editor.js', 'editor.js.map', 'index.html'];
const testHookName = 'before-public-detach';

function spawnBuild(extraEnv = {}) {
  const child = spawn(process.execPath, ['build.mjs'], {
    cwd: runtimePath,
    env: { ...process.env, ...extraEnv },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const completion = new Promise((resolve) => {
    child.on('close', (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
  return { child, completion, get stderr() { return stderr; } };
}

async function runBuild(extraEnv = {}) {
  const execution = spawnBuild(extraEnv);
  const result = await execution.completion;
  assert.equal(result.code, 0, result.stderr || result.stdout);
  return result;
}

async function snapshotDirectory(path) {
  const files = (await readdir(path)).sort();
  const entries = await Promise.all(files.map(async (file) => {
    const contents = await readFile(join(path, file));
    return {
      file,
      bytes: contents.length,
      sha256: createHash('sha256').update(contents).digest('hex'),
    };
  }));
  return { files, entries };
}

async function snapshotBundle() {
  return snapshotDirectory(outputPath);
}

function hookPath(hookDirectory, execution, suffix, hookName = testHookName) {
  return join(
    hookDirectory,
    `${execution.child.pid}.${hookName}.${suffix}`,
  );
}

async function waitForHook(hookDirectory, execution, hookName = testHookName) {
  const readyPath = hookPath(hookDirectory, execution, 'ready', hookName);
  const deadline = Date.now() + 3_000;
  while (Date.now() < deadline) {
    try {
      await access(readyPath);
      return;
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
    if (execution.child.exitCode !== null) {
      const result = await execution.completion;
      assert.fail(`build exited before test hook: ${result.stderr || result.stdout}`);
    }
    await delay(10);
  }
  assert.fail(`timed out waiting for deterministic build hook: ${execution.stderr}`);
}

async function releaseHook(hookDirectory, execution, hookName = testHookName) {
  if (execution.child.exitCode === null) {
    await writeFile(
      hookPath(hookDirectory, execution, 'continue', hookName),
      'continue\n',
    );
  }
}

async function stopBuild(execution) {
  if (execution.child.exitCode === null) execution.child.kill('SIGTERM');
  await execution.completion;
}

async function detachAndRemoveTestPath(path) {
  let stats;
  try {
    stats = await lstat(path);
  } catch (error) {
    if (error?.code === 'ENOENT') return;
    throw error;
  }
  if (stats.isSymbolicLink()) {
    await unlink(path);
    return;
  }
  const detached = join(
    dirname(path),
    `.test-cleanup-${basename(path)}-${randomUUID()}`,
  );
  await rename(path, detached);
  const entries = await readdir(detached);
  for (const entry of entries) {
    const child = join(detached, entry);
    const childStats = await lstat(child);
    assert.equal(childStats.isDirectory(), false, `unexpected test cleanup directory: ${child}`);
    await unlink(child);
  }
  await rmdir(detached);
}

async function pathSnapshot(path) {
  try {
    return await snapshotDirectory(path);
  } catch (error) {
    if (error?.code === 'ENOENT') return { missing: true };
    throw error;
  }
}

async function expectRejectedBuild(message) {
  const execution = spawnBuild();
  const result = await execution.completion;
  assert.notEqual(result.code, 0, message);
  assert.match(result.stderr, /symbolic link/i);
}

function buildTestEnv(hookDirectory) {
  return {
    NODE_ENV: 'test',
    COCKPIT_BUILD_TEST_HOOK_DIR: hookDirectory,
    COCKPIT_BUILD_TEST_PAUSE: testHookName,
  };
}

async function privateArtifactNames() {
  return (await readdir(distPath)).filter((entry) => (
    entry.startsWith('.MonacoRuntime.bundle.staging-')
    || entry.startsWith('.MonacoRuntime.bundle.retired-')
    || entry.startsWith('.MonacoRuntime.bundle.quarantine-')
  ));
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
});

test('openText reuses a URI model and synchronizes text and language', async () => {
  let protocolModule;
  try {
    protocolModule = await import(new URL('../src/protocol.mjs', import.meta.url));
  } catch (error) {
    assert.fail(`testable protocol module is unavailable: ${error?.code ?? error}`);
  }

  const models = new Map();
  let createCount = 0;
  const languageChanges = [];
  const monaco = {
    Uri: {
      parse(value) { return { value }; },
    },
    editor: {
      getModel(uri) { return models.get(uri.value) ?? null; },
      createModel(text, language, uri) {
        createCount += 1;
        const model = {
          text,
          language,
          getValue() { return this.text; },
          setValue(value) { this.text = value; },
          getLanguageId() { return this.language; },
        };
        models.set(uri.value, model);
        return model;
      },
      setModelLanguage(model, language) {
        languageChanges.push({ model, language });
        model.language = language;
      },
    },
  };
  const editor = {
    model: null,
    setModel(model) { this.model = model; },
  };
  const protocol = protocolModule.createEditorProtocol(monaco, editor);

  protocol.openText('file:///same.txt', 'first', 'plaintext');
  const firstModel = editor.model;
  protocol.openText('file:///same.txt', 'second', 'typescript');

  assert.equal(protocol.version, 1);
  assert.equal(createCount, 1);
  assert.strictEqual(editor.model, firstModel);
  assert.equal(firstModel.text, 'second');
  assert.equal(firstModel.language, 'typescript');
  assert.deepEqual(languageChanges, [{ model: firstModel, language: 'typescript' }]);
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
    await detachAndRemoveTestPath(distPath);
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
    await detachAndRemoveTestPath(outputPath);
    await rename(backup, outputPath);
    await rm(externalRoot, { recursive: true, force: true });
  }
});

test('publication never follows a public output swapped to an external link', async () => {
  const hookDirectory = await mkdtemp(join(tmpdir(), 'cockpit-runtime-hook-'));
  const externalRoot = await mkdtemp(join(tmpdir(), 'cockpit-runtime-external-'));
  const backup = join(distPath, `.bundle-test-backup-${randomUUID()}`);
  let detached = false;
  const externalFixtures = new Map(expectedFiles.map((file) => [
    file,
    Buffer.from(`external-${file}\n`),
  ]));
  for (const [file, contents] of externalFixtures) {
    await writeFile(join(externalRoot, file), contents);
  }
  const externalBefore = await snapshotDirectory(externalRoot);
  const execution = spawnBuild(buildTestEnv(hookDirectory));

  try {
    await waitForHook(hookDirectory, execution);
    await rename(outputPath, backup);
    detached = true;
    await symlink(externalRoot, outputPath, 'dir');
    await releaseHook(hookDirectory, execution);
    const result = await execution.completion;
    const externalAfter = await snapshotDirectory(externalRoot);

    assert.deepEqual(externalAfter, externalBefore);
    assert.equal(result.code, 0, result.stderr || result.stdout);
    assert.deepEqual((await snapshotBundle()).files, expectedFiles);
  } finally {
    await releaseHook(hookDirectory, execution);
    await stopBuild(execution);
    if (detached) {
      await detachAndRemoveTestPath(outputPath);
      await rename(backup, outputPath);
    }
    await rm(hookDirectory, { recursive: true, force: true });
    await rm(externalRoot, { recursive: true, force: true });
  }
});

test('two concurrent builds both succeed and publish one complete bundle', async () => {
  const before = await snapshotBundle();
  const hookDirectory = await mkdtemp(join(tmpdir(), 'cockpit-runtime-concurrent-'));
  const first = spawnBuild(buildTestEnv(hookDirectory));
  const second = spawnBuild(buildTestEnv(hookDirectory));

  try {
    await Promise.all([
      waitForHook(hookDirectory, first),
      waitForHook(hookDirectory, second),
    ]);
    await Promise.all([
      releaseHook(hookDirectory, first),
      releaseHook(hookDirectory, second),
    ]);
    const [firstResult, secondResult] = await Promise.all([
      first.completion,
      second.completion,
    ]);

    assert.equal(firstResult.code, 0, firstResult.stderr || firstResult.stdout);
    assert.equal(secondResult.code, 0, secondResult.stderr || secondResult.stdout);
    assert.deepEqual(await snapshotBundle(), before);
  } finally {
    await releaseHook(hookDirectory, first);
    await releaseHook(hookDirectory, second);
    await Promise.all([stopBuild(first), stopBuild(second)]);
    await rm(hookDirectory, { recursive: true, force: true });
  }
});

test('a pre-publication failure preserves the published bundle and removes staging', async () => {
  const before = await snapshotBundle();
  const execution = spawnBuild({
    NODE_ENV: 'test',
    COCKPIT_BUILD_TEST_FAIL: 'before-publish',
  });
  const result = await execution.completion;
  const privateArtifacts = await privateArtifactNames();

  assert.notEqual(result.code, 0, 'the injected build failure must reject');
  assert.match(result.stderr, /injected build failure before publish/i);
  assert.deepEqual(await snapshotBundle(), before);
  assert.deepEqual(privateArtifacts, []);
});

test('a reused live PID with a different start identity does not retain an artifact', async () => {
  const ownerToken = `${process.pid}-${randomUUID()}`;
  const artifactName = `.MonacoRuntime.bundle.staging-${ownerToken}`;
  const artifact = join(distPath, artifactName);
  const ownerManifest = `${artifact}.owner.json`;

  await mkdir(artifact);
  await writeFile(join(artifact, 'index.html'), 'stale-owned-artifact\n');
  const stats = await lstat(artifact);
  await writeFile(ownerManifest, JSON.stringify({
    version: 1,
    kind: 'staging',
    pid: process.pid,
    processStartIdentity: 'definitely-not-the-current-process-start',
    ownerToken,
    artifactName,
    device: String(stats.dev),
    inode: String(stats.ino),
  }));

  try {
    await runBuild();
    await assert.rejects(access(artifact), { code: 'ENOENT' });
    await assert.rejects(access(ownerManifest), { code: 'ENOENT' });
  } finally {
    await detachAndRemoveTestPath(artifact);
    try {
      await unlink(ownerManifest);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
  }
});

test('private cleanup revalidates ownership after an external directory replacement', async () => {
  const hookDirectory = await mkdtemp(join(tmpdir(), 'cockpit-runtime-private-hook-'));
  const externalRoot = await mkdtemp(join(tmpdir(), 'cockpit-runtime-private-external-'));
  const sentinel = join(externalRoot, 'sentinel.txt');
  await writeFile(sentinel, 'private-cleanup-external-sentinel\n');
  const externalBefore = await snapshotDirectory(externalRoot);
  const execution = spawnBuild({
    NODE_ENV: 'test',
    COCKPIT_BUILD_TEST_FAIL: 'before-publish',
    COCKPIT_BUILD_TEST_HOOK_DIR: hookDirectory,
    COCKPIT_BUILD_TEST_PAUSE: 'before-private-delete',
  });
  const privateHookName = `${execution.child.pid}.before-private-delete`;
  const ready = join(hookDirectory, `${privateHookName}.ready`);
  const proceed = join(hookDirectory, `${privateHookName}.continue`);
  let privateArtifact;
  let originalBackup;
  let externalMoved = false;

  try {
    const deadline = Date.now() + 3_000;
    while (Date.now() < deadline) {
      try {
        await access(ready);
        break;
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error;
      }
      if (execution.child.exitCode !== null) {
        const result = await execution.completion;
        assert.fail(`build exited before private cleanup hook: ${result.stderr || result.stdout}`);
      }
      await delay(10);
    }
    await access(ready);
    privateArtifact = join(
      distPath,
      (await readdir(distPath)).find((entry) => (
        entry.startsWith(`.MonacoRuntime.bundle.staging-${execution.child.pid}-`)
        && !entry.endsWith('.owner.json')
      )),
    );
    originalBackup = `${privateArtifact}.test-original`;
    await rename(privateArtifact, originalBackup);
    await rename(externalRoot, privateArtifact);
    externalMoved = true;
    await writeFile(proceed, 'continue\n');
    const result = await execution.completion;

    assert.notEqual(result.code, 0);
    assert.deepEqual(await pathSnapshot(privateArtifact), externalBefore);
  } finally {
    if (execution.child.exitCode === null) {
      await writeFile(proceed, 'continue\n');
      execution.child.kill('SIGTERM');
    }
    await execution.completion;
    if (externalMoved) {
      try {
        await rename(privateArtifact, externalRoot);
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error;
      }
    }
    if (originalBackup) await detachAndRemoveTestPath(originalBackup);
    if (privateArtifact) {
      try {
        await unlink(`${privateArtifact}.owner.json`);
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error;
      }
    }
    await rm(hookDirectory, { recursive: true, force: true });
    await rm(externalRoot, { recursive: true, force: true });
  }
});

test('a real esbuild resolution failure preserves publication and cleans private artifacts', async () => {
  const before = await snapshotBundle();
  const execution = spawnBuild({
    NODE_ENV: 'test',
    COCKPIT_BUILD_TEST_ESBUILD_ENTRY: 'src/does-not-exist.ts',
  });
  const result = await execution.completion;

  assert.notEqual(result.code, 0, 'esbuild must reject the missing entry point');
  assert.match(result.stderr, /Could not resolve.*does-not-exist\.ts/s);
  assert.deepEqual(await snapshotBundle(), before);
  assert.deepEqual(await privateArtifactNames(), []);
});

test('a SIGKILL after public detach is recovered by the next build', async () => {
  const before = await snapshotBundle();
  const hookName = 'after-public-detach';
  const hookDirectory = await mkdtemp(join(tmpdir(), 'cockpit-runtime-sigkill-'));
  const execution = spawnBuild({
    NODE_ENV: 'test',
    COCKPIT_BUILD_TEST_HOOK_DIR: hookDirectory,
    COCKPIT_BUILD_TEST_PAUSE: hookName,
  });

  try {
    await waitForHook(hookDirectory, execution, hookName);
    assert.equal(execution.child.kill('SIGKILL'), true);
    const killed = await execution.completion;
    assert.equal(killed.signal, 'SIGKILL');
    await runBuild();

    assert.deepEqual(await snapshotBundle(), before);
    assert.deepEqual(await privateArtifactNames(), []);
  } finally {
    if (execution.child.exitCode === null) execution.child.kill('SIGKILL');
    await execution.completion;
    try {
      await access(outputPath);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
      await runBuild();
    }
    await rm(hookDirectory, { recursive: true, force: true });
  }
});
