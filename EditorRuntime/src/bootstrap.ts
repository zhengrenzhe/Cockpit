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
    const existingModel = monaco.editor.getModel(modelURI);
    const model = existingModel
      ?? monaco.editor.createModel(text, language, modelURI);
    if (model.getValue() !== text) model.setValue(text);
    if (model.getLanguageId() !== language) {
      monaco.editor.setModelLanguage(model, language);
    }
    editor.setModel(model);
  },
};
