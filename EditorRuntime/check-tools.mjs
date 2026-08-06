import { evaluateToolchain } from './toolchain-contract.mjs';

const result = evaluateToolchain({
  nodeVersion: process.versions.node,
  userAgent: process.env.npm_config_user_agent,
});
if (!result.ok) throw new Error(`unsupported EditorRuntime toolchain: ${result.reason}`);
