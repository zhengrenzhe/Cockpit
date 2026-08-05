export function createEditorProtocol(monaco, editor) {
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
  };
}
