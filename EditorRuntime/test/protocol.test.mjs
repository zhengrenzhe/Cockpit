import test from 'node:test';
import assert from 'node:assert/strict';
import { createEditorProtocol, decodeNativeMessage } from '../src/protocol.mjs';

const generation = 7;
const projectID = '11111111-1111-4111-8111-111111111111';
const conversationID = '22222222-2222-4222-8222-222222222222';
const tabID = 'a3333333-3333-4333-8333-333333333333';
const secondTabID = '44444444-4444-4444-8444-444444444444';
const documentID = '55555555-5555-4555-8555-555555555555';
const leaseID = '66666666-6666-4666-8666-666666666666';
const uri = 'cockpit-file://77777777-7777-4777-8777-777777777777/src/main.ts';

function viewState(line = 1) {
  return {
    cursor: { line, column: 2 },
    selections: [{
      anchor: { line, column: 1 },
      active: { line, column: 3 },
    }],
    firstVisibleLine: line,
    horizontalScrollOffset: 4.5,
  };
}

function documentFields(overrides = {}) {
  return {
    webContentGeneration: generation,
    workspaceContextID: { kind: 'project', projectID },
    tabID,
    documentID,
    uri,
    lastAcceptedClientSequence: 0,
    editLeaseID: leaseID,
    writable: true,
    ...overrides,
  };
}

function renameFields(overrides = {}) {
  const { uri: ignoredURI, ...fields } = documentFields(overrides);
  return fields;
}

function openMessage(overrides = {}) {
  return {
    type: 'open',
    ...documentFields(),
    language: 'typescript',
    text: 'let value = 1;\n',
    documentVersion: 0,
    viewState: viewState(),
    ...overrides,
  };
}

function nativeMessages() {
  return [
    openMessage(),
    {
      type: 'ack', ...documentFields(), clientSequence: 1,
      documentVersion: 1,
    },
    {
      type: 'replace', ...documentFields(), text: 'saved\n',
      documentVersion: 2, viewState: viewState(2),
    },
    { type: 'setWritable', ...documentFields() },
    {
      type: 'renameModel', ...renameFields(), oldURI: uri,
      newURI: `${uri}.renamed`, language: 'typescript', text: 'renamed\n',
      documentVersion: 2, viewState: viewState(3),
    },
    { type: 'disposeModel', ...documentFields() },
    { type: 'selectModel', ...documentFields(), viewState: viewState(4) },
  ];
}

function createHarness() {
  const models = new Map();
  const outbound = [];
  const editor = {
    model: null,
    restored: [],
    setModel(model) { this.model = model; },
    saveViewState() { return { cursorState: [{ position: { lineNumber: 1, column: 1 } }] }; },
    restoreViewState(value) { this.restored.push(value); },
  };
  const monaco = {
    Uri: {
      parse(value) {
        return { value, toString() { return value; } };
      },
    },
    editor: {
      getModel(parsed) { return models.get(parsed.value) ?? null; },
      createModel(text, language, parsed) {
        const listeners = [];
        const model = {
          uri: parsed,
          text,
          language,
          disposed: false,
          undoStops: 0,
          getValue() { return this.text; },
          setValue(value) {
            this.text = value;
            for (const listener of listeners) {
              listener({ changes: [{ rangeOffset: 0, rangeLength: 0, text: value }] });
            }
          },
          getLanguageId() { return this.language; },
          onDidChangeContent(listener) {
            listeners.push(listener);
            return { dispose() {} };
          },
          pushStackElement() { this.undoStops += 1; },
          dispose() { this.disposed = true; models.delete(parsed.value); },
        };
        models.set(parsed.value, model);
        return model;
      },
      setModelLanguage(model, language) { model.language = language; },
    },
  };
  return {
    models,
    outbound,
    editor,
    protocol: createEditorProtocol(monaco, editor, {
      webContentGeneration: generation,
      postMessage(message) { outbound.push(message); },
    }),
  };
}

test('monaco native schema accepts every exact variant and rejects unknown or missing keys', () => {
  for (const message of nativeMessages()) {
    assert.deepEqual(decodeNativeMessage(message), { ok: true, value: message });
    assert.deepEqual(
      decodeNativeMessage({ ...message, unexpected: true }),
      { ok: false, error: 'invalid-schema' },
    );
    const missing = { ...message };
    delete missing.webContentGeneration;
    assert.deepEqual(decodeNativeMessage(missing), { ok: false, error: 'invalid-schema' });
  }
});

test('monaco native schema enforces safe bounds canonical UUIDs contexts and URI round trips', () => {
  assert.equal(decodeNativeMessage(openMessage()).ok, true);
  assert.equal(decodeNativeMessage(openMessage({ webContentGeneration: 0 })).ok, false);
  assert.equal(decodeNativeMessage(openMessage({ documentVersion: Number.MAX_SAFE_INTEGER + 1 })).ok, false);
  assert.equal(decodeNativeMessage(openMessage({ tabID: tabID.toUpperCase() })).ok, false);
  assert.equal(decodeNativeMessage(openMessage({ workspaceContextID: { kind: 'conversation', conversationID } })).ok, true);
  assert.equal(decodeNativeMessage(openMessage({ workspaceContextID: { kind: 'project', projectID, conversationID } })).ok, false);
  assert.equal(decodeNativeMessage(openMessage({ uri: `${uri}%2fchild` })).ok, false);
});

test('monaco native schema enforces writable lease equivalence and validated view state', () => {
  assert.equal(decodeNativeMessage(openMessage({ writable: false, editLeaseID: null })).ok, true);
  assert.equal(decodeNativeMessage(openMessage({ writable: false, editLeaseID: leaseID })).ok, false);
  assert.equal(decodeNativeMessage(openMessage({ writable: true, editLeaseID: null })).ok, false);
  assert.equal(decodeNativeMessage(openMessage({ viewState: viewState(0) })).ok, false);
  assert.equal(decodeNativeMessage(openMessage({ viewState: { ...viewState(), horizontalScrollOffset: Infinity } })).ok, false);
});

test('monaco edit schema uses ordered nonoverlapping UTF16 changes and never accepts clientSequence', () => {
  const valid = {
    type: 'edit', ...documentFields(), baseVersion: 0,
    changes: [
      { offset: 0, length: 2, replacement: '🙂' },
      { offset: 2, length: 0, replacement: '\n' },
    ],
  };
  assert.equal(decodeNativeMessage(valid).ok, true);
  assert.equal(decodeNativeMessage({ ...valid, clientSequence: 1 }).ok, false);
  assert.equal(decodeNativeMessage({ ...valid, changes: [] }).ok, false);
  assert.equal(decodeNativeMessage({ ...valid, changes: [...valid.changes].reverse() }).ok, false);
  assert.equal(decodeNativeMessage({ ...valid, changes: [{ offset: 0, length: 1, replacement: '\r' }] }).ok, false);
  assert.equal(decodeNativeMessage({ ...valid, changes: [{ offset: Number.MAX_SAFE_INTEGER, length: 1, replacement: '' }] }).ok, false);
});

test('monaco open reuses one URI model while retaining independent tab references', () => {
  const harness = createHarness();
  assert.deepEqual(harness.protocol.receiveNativeMessage(openMessage()), { ok: true });
  assert.deepEqual(harness.protocol.receiveNativeMessage(openMessage({ tabID: secondTabID })), { ok: true });
  assert.equal(harness.protocol.modelCount(), 1);
  assert.equal(harness.protocol.referenceCount(uri), 2);
  assert.equal(harness.models.size, 1);
});

test('monaco programmatic open and replace writes are synchronously suppressed from edit callbacks', () => {
  const harness = createHarness();
  assert.deepEqual(harness.protocol.receiveNativeMessage(openMessage()), { ok: true });
  assert.deepEqual(harness.protocol.receiveNativeMessage({
    type: 'replace', ...documentFields(), text: 'authoritative\n',
    documentVersion: 2, viewState: null,
  }), { ok: true });
  assert.deepEqual(harness.outbound, []);
  assert.equal(harness.models.get(uri).text, 'authoritative\n');
});

test('monaco user edits emit UTF16 changes without an authoritative client sequence', () => {
  const harness = createHarness();
  assert.deepEqual(harness.protocol.receiveNativeMessage(openMessage()), { ok: true });
  harness.outbound.length = 0;
  harness.models.get(uri).setValue('user edit');
  assert.equal(harness.outbound.length, 1);
  assert.equal(harness.outbound[0].type, 'edit');
  assert.equal('clientSequence' in harness.outbound[0], false);
  assert.deepEqual(harness.outbound[0].changes, [{ offset: 0, length: 0, replacement: 'user edit' }]);
});

test('monaco rename creates an immutable destination model resets undo and transfers all refs', () => {
  const harness = createHarness();
  const destination = `${uri}.renamed`;
  harness.protocol.receiveNativeMessage(openMessage());
  harness.protocol.receiveNativeMessage(openMessage({ tabID: secondTabID }));
  const old = harness.models.get(uri);
  assert.deepEqual(harness.protocol.receiveNativeMessage({
    type: 'renameModel', ...renameFields(), oldURI: uri, newURI: destination,
    language: 'typescript', text: 'destination\n', documentVersion: 3,
    viewState: viewState(5),
  }), { ok: true });
  assert.deepEqual(harness.protocol.receiveNativeMessage({
    type: 'renameModel', ...renameFields({ tabID: secondTabID }),
    oldURI: uri, newURI: destination, language: 'typescript',
    text: 'destination\n', documentVersion: 3, viewState: viewState(6),
  }), { ok: true });
  assert.notStrictEqual(harness.models.get(destination), old);
  assert.equal(harness.protocol.referenceCount(destination), 2);
  assert.equal(harness.protocol.referenceCount(uri), 0);
  assert.equal(old.disposed, true);
  assert.ok(harness.models.get(destination).undoStops >= 1);
});

test('monaco dispose releases only the addressed tab and disposes at zero references', () => {
  const harness = createHarness();
  harness.protocol.receiveNativeMessage(openMessage());
  harness.protocol.receiveNativeMessage(openMessage({ tabID: secondTabID }));
  const model = harness.models.get(uri);
  harness.protocol.receiveNativeMessage({ type: 'disposeModel', ...documentFields() });
  assert.equal(harness.protocol.referenceCount(uri), 1);
  assert.equal(model.disposed, false);
  harness.protocol.receiveNativeMessage({ type: 'disposeModel', ...documentFields({ tabID: secondTabID }) });
  assert.equal(model.disposed, true);
});

test('monaco select uses the exact TabID reference and restores its isolated view state', () => {
  const harness = createHarness();
  harness.protocol.receiveNativeMessage(openMessage({ viewState: viewState(2) }));
  harness.protocol.receiveNativeMessage(openMessage({ tabID: secondTabID, viewState: viewState(8) }));
  harness.protocol.receiveNativeMessage({
    type: 'selectModel', ...documentFields({ tabID: secondTabID }), viewState: viewState(8),
  });
  assert.strictEqual(harness.editor.model, harness.models.get(uri));
  assert.deepEqual(harness.editor.restored.at(-1), viewState(8));
});

test('monaco stale generation rejects mutation without changing models or selection', () => {
  const harness = createHarness();
  assert.deepEqual(
    harness.protocol.receiveNativeMessage(openMessage({ webContentGeneration: generation - 1 })),
    { ok: false, error: 'stale-generation' },
  );
  assert.equal(harness.protocol.modelCount(), 0);
  assert.equal(harness.editor.model, null);
});
