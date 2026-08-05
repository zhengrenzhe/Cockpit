### Task 9: Pin and build the isolated Monaco runtime

**Files:**
- Create: `EditorRuntime/package.json`
- Create: `EditorRuntime/build.mjs`
- Create: `EditorRuntime/src/index.html`
- Create: `EditorRuntime/src/bootstrap.ts`
- Create: `EditorRuntime/test/build.test.mjs`

**Interfaces:**
- Consumes: Node 26.7.0 and pnpm 11.20.0.
- Produces: `EditorRuntime/dist/MonacoRuntime.bundle/index.html` and `editor.js`; no application networking or web UI modules.

- [ ] **Step 1: Write the package manifest and failing build test**

Create `EditorRuntime/package.json`:

```json
{
  "name": "cockpit-editor-runtime",
  "private": true,
  "version": "0.0.1",
  "packageManager": "pnpm@11.20.0",
  "type": "module",
  "scripts": {
    "build": "node build.mjs",
    "test": "node --test test/*.test.mjs"
  },
  "dependencies": {
    "monaco-editor": "0.56.0"
  },
  "devDependencies": {
    "esbuild": "0.28.1"
  }
}
```

Create `EditorRuntime/test/build.test.mjs`:

```javascript
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('build emits a self-contained local editor bundle', async () => {
  const html = await readFile(new URL('../dist/MonacoRuntime.bundle/index.html', import.meta.url), 'utf8');
  const js = await readFile(new URL('../dist/MonacoRuntime.bundle/editor.js', import.meta.url), 'utf8');
  const css = await readFile(new URL('../dist/MonacoRuntime.bundle/editor.css', import.meta.url), 'utf8');
  const source = await readFile(new URL('../src/bootstrap.ts', import.meta.url), 'utf8');
  assert.match(html, /editor\.js/);
  assert.match(html, /editor\.css/);
  assert.match(js, /cockpitEditorProtocol/);
  assert.ok(css.length > 0);
  assert.doesNotMatch(html, /(?:src|href)=["']https?:/);
  assert.doesNotMatch(source, /\bfetch\s*\(|\bWebSocket\s*\(/);
});
```

- [ ] **Step 2: Install dependencies and verify test failure**

Run:

```bash
test "$(pnpm --version)" = "11.20.0"
pnpm --dir EditorRuntime install --frozen-lockfile=false
pnpm --dir EditorRuntime test
```

Expected: test fails with ENOENT for `dist/MonacoRuntime.bundle/index.html`.

- [ ] **Step 3: Implement the minimal Monaco bootstrap**

Create `EditorRuntime/src/index.html`:

```html
<!doctype html>
<html><head><meta charset="utf-8"><meta name="color-scheme" content="dark light"><link rel="stylesheet" href="./editor.css"></head>
<body><div id="editor"></div><script type="module" src="./editor.js"></script></body></html>
```

Create `EditorRuntime/src/bootstrap.ts`:

```typescript
import * as monaco from 'monaco-editor/editor/editor.api';
import 'monaco-editor/editor/contrib/find/browser/findController';

declare global {
  interface Window {
    cockpitEditorProtocol: {
      version: 1;
      openText(uri: string, text: string, language: string): void;
    };
  }
}

const root = document.getElementById('editor');
if (!(root instanceof HTMLElement)) throw new Error('missing editor root');
Object.assign(document.body.style, { margin: '0', overflow: 'hidden' });
Object.assign(root.style, { position: 'fixed', inset: '0' });

const editor = monaco.editor.create(root, {
  value: '',
  language: 'plaintext',
  automaticLayout: true,
  minimap: { enabled: false },
});

window.cockpitEditorProtocol = {
  version: 1,
  openText(uri, text, language) {
    const modelURI = monaco.Uri.parse(uri);
    const model = monaco.editor.getModel(modelURI) ?? monaco.editor.createModel(text, language, modelURI);
    if (model.getValue() !== text) model.setValue(text);
    editor.setModel(model);
  },
};
```

- [ ] **Step 4: Implement deterministic bundling**

Create `EditorRuntime/build.mjs`:

```javascript
import { build } from 'esbuild';
import { cp, mkdir, rm } from 'node:fs/promises';

const output = new URL('./dist/MonacoRuntime.bundle/', import.meta.url);
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
await cp(new URL('./src/index.html', import.meta.url), new URL('./index.html', output));
await build({
  entryPoints: [new URL('./src/bootstrap.ts', import.meta.url).pathname],
  outfile: new URL('./editor.js', output).pathname,
  bundle: true,
  format: 'esm',
  platform: 'browser',
  target: 'safari18',
  minify: true,
  sourcemap: true,
  logLevel: 'info',
});
```

- [ ] **Step 5: Build and test the editor runtime**

Run:

```bash
pnpm --dir EditorRuntime build
pnpm --dir EditorRuntime test
```

Expected: esbuild emits `editor.js`; the Node test passes; no output contains an HTTP URL.

- [ ] **Step 6: Commit Monaco source and lockfile**

```bash
git add EditorRuntime/package.json EditorRuntime/pnpm-lock.yaml EditorRuntime/build.mjs EditorRuntime/src EditorRuntime/test
git commit -m "build: pin isolated monaco runtime"
```

---
