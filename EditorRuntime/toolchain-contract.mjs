export function parseVersion(value) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(value ?? '');
  if (!match) return null;
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]) };
}

export function parsePnpmUserAgent(userAgent) {
  const match = /^pnpm\/(\d+\.\d+\.\d+)\s/.exec(userAgent ?? '');
  return match ? parseVersion(match[1]) : null;
}

function isVersion(version, major, minor, patch) {
  return version.major === major
    && version.minor === minor
    && version.patch === patch;
}

export function evaluateToolchain({ nodeVersion, userAgent }) {
  const node = parseVersion(nodeVersion);
  const pnpm = parsePnpmUserAgent(userAgent);
  if (!node || !pnpm) return { ok: false, reason: 'a complete Node version and pnpm user agent are required' };
  if (isVersion(node, 26, 7, 0) && isVersion(pnpm, 11, 20, 0)) {
    return { ok: true };
  }
  return { ok: false, reason: 'Node 26.7.0 and pnpm 11.20.0 are required' };
}

export function profileName(input) {
  const node = parseVersion(input.nodeVersion);
  const pnpm = parsePnpmUserAgent(input.userAgent);
  if (!node || !pnpm) return null;
  if (isVersion(node, 26, 7, 0) && isVersion(pnpm, 11, 20, 0)) return 'current';
  return null;
}
