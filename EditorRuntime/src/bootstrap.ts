import * as monaco from 'monaco-editor/editor/editor.api';
import 'monaco-editor/editor/contrib/find/browser/findController';
import { createEditorProtocol } from './protocol.mjs';

declare global {
  interface Window {
    cockpitWebContentGeneration?: number;
    cockpitEditorProtocol: {
      version: 1;
      openText(uri: string, text: string, language: string): void;
      receiveNativeMessage(message: unknown): { ok: boolean; error?: string };
      ready(): void;
      save(): void;
    };
    cockpitMonacoReceive(message: unknown): { ok: boolean; error?: string };
    webkit: {
      messageHandlers: {
        cockpitMonaco: {
          postMessage(message: unknown): Promise<unknown>;
        };
      };
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

const webContentGeneration = window.cockpitWebContentGeneration ?? 1;
const protocol = createEditorProtocol(monaco, editor, {
  webContentGeneration,
  postMessage(message: unknown) {
    return window.webkit.messageHandlers.cockpitMonaco.postMessage(message);
  },
});
window.cockpitEditorProtocol = protocol;
window.cockpitMonacoReceive = (message: unknown) => (
  protocol.receiveNativeMessage(message)
);
protocol.ready();
