const MAX_SAFE_INTEGER = Number.MAX_SAFE_INTEGER;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const URI_PATTERN = /^cockpit-file:\/\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([^/]+(?:\/[^/]+)*)$/;
const ENCODED_COMPONENT_PATTERN = /^(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+$/;

const documentKeys = [
  'webContentGeneration',
  'workspaceContextID',
  'tabID',
  'documentID',
  'uri',
  'lastAcceptedClientSequence',
  'editLeaseID',
  'writable',
];
const renameDocumentKeys = documentKeys.filter((key) => key !== 'uri');

const messageKeys = {
  open: [
    'type', ...documentKeys, 'language', 'text', 'documentVersion', 'viewState',
  ],
  ack: [
    'type', ...documentKeys, 'clientSequence', 'documentVersion',
  ],
  replace: [
    'type', ...documentKeys, 'text', 'documentVersion', 'viewState',
  ],
  setWritable: ['type', ...documentKeys],
  renameModel: [
    'type', ...renameDocumentKeys, 'oldURI', 'newURI', 'language', 'text',
    'documentVersion', 'viewState',
  ],
  disposeModel: ['type', ...documentKeys],
  selectModel: ['type', ...documentKeys, 'viewState'],
  ready: ['type', 'webContentGeneration'],
  edit: ['type', ...documentKeys, 'baseVersion', 'changes'],
  save: ['type', ...documentKeys],
  viewState: ['type', ...documentKeys, 'value'],
};

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function hasExactKeys(value, expected) {
  if (!isRecord(value)) return false;
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  return actual.length === wanted.length
    && actual.every((key, index) => key === wanted[index]);
}

function isSafeIntegerInRange(value, minimum) {
  return Number.isSafeInteger(value) && value >= minimum && value <= MAX_SAFE_INTEGER;
}

function isUUID(value) {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

function isWorkspaceContext(value) {
  if (!isRecord(value)) return false;
  if (value.kind === 'project') {
    return hasExactKeys(value, ['kind', 'projectID']) && isUUID(value.projectID);
  }
  if (value.kind === 'conversation') {
    return hasExactKeys(value, ['kind', 'conversationID'])
      && isUUID(value.conversationID);
  }
  return false;
}

function isURI(value) {
  if (typeof value !== 'string') return false;
  const match = URI_PATTERN.exec(value);
  if (!match || !isUUID(match[1])) return false;
  return match[2].split('/').every(isCanonicalEncodedComponent);
}

function isCanonicalEncodedComponent(component) {
  if (
    component === '.'
    || component === '..'
    || !ENCODED_COMPONENT_PATTERN.test(component)
  ) return false;
  const bytes = [];
  for (let index = 0; index < component.length;) {
    if (component[index] !== '%') {
      bytes.push(component.charCodeAt(index));
      index += 1;
      continue;
    }
    const byte = Number.parseInt(component.slice(index + 1, index + 3), 16);
    if (
      byte === 0x2f
      || (byte >= 0x41 && byte <= 0x5a)
      || (byte >= 0x61 && byte <= 0x7a)
      || (byte >= 0x30 && byte <= 0x39)
      || byte === 0x2d
      || byte === 0x2e
      || byte === 0x5f
      || byte === 0x7e
    ) return false;
    bytes.push(byte);
    index += 3;
  }
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(Uint8Array.from(bytes));
    return true;
  } catch {
    return false;
  }
}

function isPosition(value) {
  return hasExactKeys(value, ['line', 'column'])
    && isSafeIntegerInRange(value.line, 1)
    && isSafeIntegerInRange(value.column, 1);
}

function isRange(value) {
  return hasExactKeys(value, ['anchor', 'active'])
    && isPosition(value.anchor)
    && isPosition(value.active);
}

function isViewState(value) {
  return hasExactKeys(value, [
    'cursor', 'selections', 'firstVisibleLine', 'horizontalScrollOffset',
  ])
    && isPosition(value.cursor)
    && Array.isArray(value.selections)
    && value.selections.every(isRange)
    && isSafeIntegerInRange(value.firstVisibleLine, 1)
    && typeof value.horizontalScrollOffset === 'number'
    && Number.isFinite(value.horizontalScrollOffset)
    && value.horizontalScrollOffset >= 0;
}

function isNullableViewState(value) {
  return value === null || isViewState(value);
}

function hasValidDocumentFields(value, requireURI = true) {
  return isSafeIntegerInRange(value.webContentGeneration, 1)
    && isWorkspaceContext(value.workspaceContextID)
    && isUUID(value.tabID)
    && isUUID(value.documentID)
    && (!requireURI || isURI(value.uri))
    && isSafeIntegerInRange(value.lastAcceptedClientSequence, 0)
    && (value.editLeaseID === null || isUUID(value.editLeaseID))
    && typeof value.writable === 'boolean'
    && value.writable === (value.editLeaseID !== null);
}

function isTextChange(value) {
  return hasExactKeys(value, ['offset', 'length', 'replacement'])
    && isSafeIntegerInRange(value.offset, 0)
    && isSafeIntegerInRange(value.length, 0)
    && isSafeIntegerInRange(value.offset + value.length, 0)
    && typeof value.replacement === 'string'
    && !value.replacement.includes('\r')
    && !value.replacement.includes('\0');
}

function areOrderedChanges(value) {
  if (!Array.isArray(value) || value.length === 0 || !value.every(isTextChange)) {
    return false;
  }
  let previousOffset;
  let previousEnd;
  for (const change of value) {
    if (previousOffset !== undefined && change.offset <= previousOffset) return false;
    if (previousEnd !== undefined && change.offset < previousEnd) return false;
    previousOffset = change.offset;
    previousEnd = change.offset + change.length;
  }
  return true;
}

function isMessage(value) {
  if (!isRecord(value) || typeof value.type !== 'string') return false;
  const expectedKeys = messageKeys[value.type];
  if (!expectedKeys || !hasExactKeys(value, expectedKeys)) return false;
  if (value.type === 'ready') {
    return isSafeIntegerInRange(value.webContentGeneration, 1);
  }
  if (!hasValidDocumentFields(value, value.type !== 'renameModel')) return false;
  switch (value.type) {
  case 'open':
    return typeof value.language === 'string'
      && typeof value.text === 'string'
      && isSafeIntegerInRange(value.documentVersion, 0)
      && isNullableViewState(value.viewState);
  case 'ack':
    return isSafeIntegerInRange(value.clientSequence, 1)
      && isSafeIntegerInRange(value.documentVersion, 0);
  case 'replace':
    return typeof value.text === 'string'
      && isSafeIntegerInRange(value.documentVersion, 0)
      && isNullableViewState(value.viewState);
  case 'setWritable':
  case 'disposeModel':
  case 'save':
    return true;
  case 'renameModel':
    return isURI(value.oldURI)
      && isURI(value.newURI)
      && typeof value.language === 'string'
      && typeof value.text === 'string'
      && isSafeIntegerInRange(value.documentVersion, 0)
      && isNullableViewState(value.viewState);
  case 'selectModel':
    return isNullableViewState(value.viewState);
  case 'edit':
    return value.writable
      && value.editLeaseID !== null
      && isSafeIntegerInRange(value.baseVersion, 0)
      && areOrderedChanges(value.changes);
  case 'viewState':
    return isViewState(value.value);
  default:
    return false;
  }
}

export function createEditorProtocol(monaco, editor, options = {}) {
  const webContentGeneration = options.webContentGeneration ?? 1;
  const postMessage = options.postMessage ?? (() => undefined);
  if (!isSafeIntegerInRange(webContentGeneration, 1)) {
    throw new TypeError('webContentGeneration must be a positive safe integer');
  }

  const models = new Map();
  const references = new Map();
  let selectedReferenceKey;
  let viewStateSuppressionDepth = 0;

  function contextKey(context) {
    return context.kind === 'project'
      ? `project:${context.projectID}`
      : `conversation:${context.conversationID}`;
  }

  function referenceKey(message) {
    return `${contextKey(message.workspaceContextID)}:${message.tabID}:${message.documentID}`;
  }

  function uriRoundTrips(value) {
    try {
      return monaco.Uri.parse(value).toString() === value;
    } catch {
      return false;
    }
  }

  function applyProgrammaticValue(entry, text) {
    if (entry.model.getValue() === text) return;
    entry.suppressionDepth += 1;
    try {
      entry.model.setValue(text);
    } finally {
      entry.suppressionDepth -= 1;
    }
  }

  function applyLanguage(entry, language) {
    if (entry.model.getLanguageId() !== language) {
      monaco.editor.setModelLanguage(entry.model, language);
    }
  }

  function currentReferenceForEntry(entry) {
    if (selectedReferenceKey && entry.referenceKeys.has(selectedReferenceKey)) {
      return references.get(selectedReferenceKey);
    }
    const first = entry.referenceKeys.values().next().value;
    return first === undefined ? undefined : references.get(first);
  }

  function postOutbound(message) {
    const decoded = decodeNativeMessage(message);
    if (!decoded.ok) return;
    let result;
    try {
      result = postMessage(message);
    } catch {
      return;
    }
    if (result && typeof result.then === 'function') {
      result.then((reply) => {
        if (
          hasExactKeys(reply, ['ok', 'message'])
          && reply.ok === true
          && (reply.message === null || isMessage(reply.message))
          && reply.message !== null
        ) receiveNativeMessage(reply.message);
      }).catch(() => {});
    }
  }

  function postEdit(entry, event) {
    if (entry.suppressionDepth !== 0) return;
    const reference = currentReferenceForEntry(entry);
    if (!reference?.writable || reference.editLeaseID === null) return;
    const changes = [...(event?.changes ?? [])]
      .map((change) => ({
        offset: change.rangeOffset,
        length: change.rangeLength,
        replacement: change.text,
      }))
      .sort((left, right) => left.offset - right.offset);
    const message = {
      type: 'edit',
      webContentGeneration,
      workspaceContextID: reference.workspaceContextID,
      tabID: reference.tabID,
      documentID: reference.documentID,
      uri: reference.uri,
      editLeaseID: reference.editLeaseID,
      writable: reference.writable,
      baseVersion: reference.documentVersion,
      lastAcceptedClientSequence: reference.lastAcceptedClientSequence,
      changes,
    };
    postOutbound(message);
  }

  function createManagedModel(uri, text, language) {
    const parsed = monaco.Uri.parse(uri);
    const model = monaco.editor.getModel(parsed)
      ?? monaco.editor.createModel(text, language, parsed);
    const entry = {
      model,
      referenceKeys: new Set(),
      suppressionDepth: 0,
      changeSubscription: undefined,
    };
    entry.changeSubscription = model.onDidChangeContent?.((event) => postEdit(entry, event));
    models.set(uri, entry);
    applyProgrammaticValue(entry, text);
    applyLanguage(entry, language);
    return entry;
  }

  function managedModel(uri, text, language) {
    const existing = models.get(uri);
    if (existing) {
      applyProgrammaticValue(existing, text);
      applyLanguage(existing, language);
      return existing;
    }
    return createManagedModel(uri, text, language);
  }

  function disposeEntryIfUnreferenced(uri, entry) {
    if (entry.referenceKeys.size !== 0) return;
    entry.changeSubscription?.dispose();
    entry.model.dispose();
    models.delete(uri);
  }

  function releaseReference(key) {
    const reference = references.get(key);
    if (!reference) return false;
    references.delete(key);
    const entry = models.get(reference.uri);
    entry?.referenceKeys.delete(key);
    if (selectedReferenceKey === key) {
      selectedReferenceKey = undefined;
      if (editor.model === entry?.model) editor.setModel(null);
    }
    if (entry) disposeEntryIfUnreferenced(reference.uri, entry);
    return true;
  }

  function accessFields(message, uri = message.uri) {
    return {
      workspaceContextID: message.workspaceContextID,
      tabID: message.tabID,
      documentID: message.documentID,
      uri,
      lastAcceptedClientSequence: message.lastAcceptedClientSequence,
      editLeaseID: message.editLeaseID,
      writable: message.writable,
    };
  }

  function selectReference(key, viewState) {
    const reference = references.get(key);
    const entry = reference && models.get(reference.uri);
    if (!reference || !entry) return false;
    if (selectedReferenceKey && selectedReferenceKey !== key) {
      const previous = references.get(selectedReferenceKey);
      if (previous && typeof editor.saveViewState === 'function') {
        previous.viewState = editor.saveViewState();
      }
    }
    if (viewState !== undefined) reference.viewState = viewState;
    selectedReferenceKey = key;
    viewStateSuppressionDepth += 1;
    try {
      editor.setModel(entry.model);
      if (reference.viewState !== null && reference.viewState !== undefined) {
        editor.restoreViewState?.(reference.viewState);
      }
      editor.updateOptions?.({ readOnly: !reference.writable });
    } finally {
      viewStateSuppressionDepth -= 1;
    }
    return true;
  }

  function wirePosition(position) {
    if (!position) return undefined;
    const line = position.lineNumber ?? position.line;
    const column = position.column;
    const value = { line, column };
    return isPosition(value) ? value : undefined;
  }

  function wireRange(selection) {
    if (!selection) return undefined;
    const anchor = wirePosition({
      lineNumber: selection.selectionStartLineNumber
        ?? selection.anchor?.lineNumber
        ?? selection.anchor?.line,
      column: selection.selectionStartColumn ?? selection.anchor?.column,
    });
    const active = wirePosition({
      lineNumber: selection.positionLineNumber
        ?? selection.active?.lineNumber
        ?? selection.active?.line,
      column: selection.positionColumn ?? selection.active?.column,
    });
    return anchor && active ? { anchor, active } : undefined;
  }

  function captureViewState() {
    const cursor = wirePosition(editor.getPosition?.());
    if (!cursor) return undefined;
    const selections = (editor.getSelections?.() ?? [])
      .map(wireRange)
      .filter((selection) => selection !== undefined);
    const firstVisibleLine = editor.getVisibleRanges?.()[0]?.startLineNumber
      ?? cursor.line;
    const horizontalScrollOffset = editor.getScrollLeft?.() ?? 0;
    const value = { cursor, selections, firstVisibleLine, horizontalScrollOffset };
    return isViewState(value) ? value : undefined;
  }

  function postViewState() {
    if (viewStateSuppressionDepth !== 0 || !selectedReferenceKey) return;
    const reference = references.get(selectedReferenceKey);
    const value = captureViewState();
    if (!reference || !value) return;
    reference.viewState = value;
    postOutbound({
      type: 'viewState',
      webContentGeneration,
      ...accessFields(reference),
      value,
    });
  }

  function postSave() {
    if (!selectedReferenceKey) return;
    const reference = references.get(selectedReferenceKey);
    if (!reference) return;
    postOutbound({
      type: 'save',
      webContentGeneration,
      ...accessFields(reference),
    });
  }

  function handleOpen(message) {
    if (!uriRoundTrips(message.uri)) return { ok: false, error: 'invalid-schema' };
    const key = referenceKey(message);
    const previous = references.get(key);
    if (previous && previous.uri !== message.uri) releaseReference(key);
    const existing = models.get(message.uri);
    const isSameDocumentAttach = existing !== undefined
      && [...existing.referenceKeys].some(
        (referenceKeyValue) => references.get(referenceKeyValue)?.documentID === message.documentID,
      );
    const entry = isSameDocumentAttach
      ? existing
      : managedModel(message.uri, message.text, message.language);
    entry.referenceKeys.add(key);
    references.set(key, {
      ...accessFields(message),
      documentVersion: message.documentVersion,
      viewState: message.viewState,
    });
    if (!isSameDocumentAttach || selectedReferenceKey === undefined) {
      selectReference(key, message.viewState);
    }
    return { ok: true };
  }

  function exactReference(message) {
    const key = referenceKey(message);
    const reference = references.get(key);
    if (!reference || reference.uri !== message.uri) return undefined;
    return { key, reference };
  }

  function updateReferenceAccess(reference, message) {
    reference.lastAcceptedClientSequence = message.lastAcceptedClientSequence;
    reference.editLeaseID = message.editLeaseID;
    reference.writable = message.writable;
  }

  function handleAck(message) {
    const exact = exactReference(message);
    if (!exact) return { ok: false, error: 'unknown-document' };
    updateReferenceAccess(exact.reference, message);
    exact.reference.documentVersion = message.documentVersion;
    if (selectedReferenceKey === exact.key) {
      editor.updateOptions?.({ readOnly: !message.writable });
    }
    return { ok: true };
  }

  function handleReplace(message) {
    const exact = exactReference(message);
    if (!exact) return { ok: false, error: 'unknown-document' };
    const entry = models.get(message.uri);
    if (!entry) return { ok: false, error: 'unknown-document' };
    applyProgrammaticValue(entry, message.text);
    updateReferenceAccess(exact.reference, message);
    exact.reference.documentVersion = message.documentVersion;
    if (message.viewState !== null) exact.reference.viewState = message.viewState;
    if (selectedReferenceKey === exact.key) selectReference(exact.key);
    return { ok: true };
  }

  function handleSetWritable(message) {
    const exact = exactReference(message);
    if (!exact) return { ok: false, error: 'unknown-document' };
    updateReferenceAccess(exact.reference, message);
    if (selectedReferenceKey === exact.key) {
      editor.updateOptions?.({ readOnly: !message.writable });
    }
    return { ok: true };
  }

  function handleRename(message) {
    if (!uriRoundTrips(message.oldURI) || !uriRoundTrips(message.newURI)) {
      return { ok: false, error: 'invalid-schema' };
    }
    const addressedKey = referenceKey(message);
    const addressedReference = references.get(addressedKey);
    if (!addressedReference) {
      return { ok: false, error: 'unknown-document' };
    }
    if (addressedReference.uri === message.newURI) {
      const destination = models.get(message.newURI);
      if (!destination) return { ok: false, error: 'unknown-document' };
      applyProgrammaticValue(destination, message.text);
      applyLanguage(destination, message.language);
      addressedReference.documentVersion = message.documentVersion;
      updateReferenceAccess(addressedReference, message);
      if (message.viewState !== null) addressedReference.viewState = message.viewState;
      if (selectedReferenceKey === addressedKey) selectReference(addressedKey);
      return { ok: true };
    }
    if (addressedReference.uri !== message.oldURI) {
      return { ok: false, error: 'unknown-document' };
    }
    if (models.has(message.newURI) || monaco.editor.getModel(monaco.Uri.parse(message.newURI))) {
      return { ok: false, error: 'stale-document-state' };
    }
    const oldEntry = models.get(message.oldURI);
    if (!oldEntry) return { ok: false, error: 'unknown-document' };
    const destination = createManagedModel(message.newURI, message.text, message.language);
    destination.model.pushStackElement?.();
    const transferredKeys = [...oldEntry.referenceKeys].filter((key) => {
      const reference = references.get(key);
      return reference?.documentID === message.documentID;
    });
    for (const key of transferredKeys) {
      const reference = references.get(key);
      oldEntry.referenceKeys.delete(key);
      destination.referenceKeys.add(key);
      reference.uri = message.newURI;
      reference.documentVersion = message.documentVersion;
      updateReferenceAccess(reference, message);
      if (key === addressedKey && message.viewState !== null) {
        reference.viewState = message.viewState;
      }
    }
    if (selectedReferenceKey && transferredKeys.includes(selectedReferenceKey)) {
      selectReference(selectedReferenceKey);
    }
    disposeEntryIfUnreferenced(message.oldURI, oldEntry);
    return { ok: true };
  }

  function handleDispose(message) {
    const exact = exactReference(message);
    if (!exact) return { ok: false, error: 'unknown-document' };
    releaseReference(exact.key);
    return { ok: true };
  }

  function handleSelect(message) {
    const exact = exactReference(message);
    if (!exact) return { ok: false, error: 'unknown-document' };
    updateReferenceAccess(exact.reference, message);
    if (!selectReference(exact.key, message.viewState)) {
      return { ok: false, error: 'unknown-document' };
    }
    return { ok: true };
  }

  function receiveNativeMessage(message) {
    const decoded = decodeNativeMessage(message);
    if (!decoded.ok) return decoded;
    if (message.webContentGeneration !== webContentGeneration) {
      return { ok: false, error: 'stale-generation' };
    }
    switch (message.type) {
    case 'open': return handleOpen(message);
    case 'ack': return handleAck(message);
    case 'replace': return handleReplace(message);
    case 'setWritable': return handleSetWritable(message);
    case 'renameModel': return handleRename(message);
    case 'disposeModel': return handleDispose(message);
    case 'selectModel': return handleSelect(message);
    default: return { ok: false, error: 'invalid-schema' };
    }
  }

  editor.onDidChangeCursorPosition?.(postViewState);
  editor.onDidChangeCursorSelection?.(postViewState);
  editor.onDidScrollChange?.(postViewState);
  if (
    typeof editor.addCommand === 'function'
    && Number.isSafeInteger(monaco.KeyMod?.CtrlCmd)
    && Number.isSafeInteger(monaco.KeyCode?.KeyS)
  ) editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, postSave);

  return {
    version: 1,
    openText(uri, text, language) {
      const modelURI = monaco.Uri.parse(uri);
      const existingModel = monaco.editor.getModel(modelURI);
      const model = existingModel
        ?? monaco.editor.createModel(text, language, modelURI);
      if (model.getValue() !== text) model.setValue(text);
      if (model.getLanguageId() !== language) {
        monaco.editor.setModelLanguage(model, language);
      }
      editor.setModel(model);
    },
    receiveNativeMessage,
    ready() {
      postOutbound({ type: 'ready', webContentGeneration });
    },
    save: postSave,
    modelCount() {
      return models.size;
    },
    referenceCount(uri) {
      return models.get(uri)?.referenceKeys.size ?? 0;
    },
  };
}

export function decodeNativeMessage(value) {
  if (!isMessage(value)) return { ok: false, error: 'invalid-schema' };
  return { ok: true, value };
}
