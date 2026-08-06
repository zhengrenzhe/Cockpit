function compareVersions(left, right) {
  for (const key of ['major', 'minor', 'patch']) {
    if (left[key] !== right[key]) return left[key] < right[key] ? -1 : 1;
  }
  return 0;
}

export function parseVersion(value) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(value ?? '');
  if (!match) return null;
  return { major: Number(match[1]), minor: Number(match[2]), patch: Number(match[3]) };
}

export function parsePnpmUserAgent(userAgent) {
  const match = /^pnpm\/(\d+\.\d+\.\d+)\s/.exec(userAgent ?? '');
  return match ? parseVersion(match[1]) : null;
}

function isInRange(version, minimum, exclusiveMaximum) {
  return compareVersions(version, minimum) >= 0 && compareVersions(version, exclusiveMaximum) < 0;
}

export function evaluateToolchain({ nodeVersion, userAgent }) {
  const node = parseVersion(nodeVersion);
  const pnpm = parsePnpmUserAgent(userAgent);
  if (!node || !pnpm) return { ok: false, reason: 'a complete Node version and pnpm user agent are required' };
  const profileA = compareVersions(node, { major: 25, minor: 9, patch: 0 }) === 0 && compareVersions(pnpm, { major: 9, minor: 15, patch: 9 }) === 0;
  const profileB = compareVersions(node, { major: 26, minor: 7, patch: 0 }) === 0 && compareVersions(pnpm, { major: 11, minor: 20, patch: 0 }) === 0;
  if (profileA || profileB) return { ok: true };
  return { ok: false, reason: 'Node and pnpm must use supported paired Profile A or Profile B versions' };
}

export function profileName(input) {
  const node = parseVersion(input.nodeVersion);
  const pnpm = parsePnpmUserAgent(input.userAgent);
  if (!node || !pnpm) return null;
  if (compareVersions(node, { major: 25, minor: 9, patch: 0 }) === 0 && compareVersions(pnpm, { major: 9, minor: 15, patch: 9 }) === 0) return 'A';
  if (compareVersions(node, { major: 26, minor: 7, patch: 0 }) === 0 && compareVersions(pnpm, { major: 11, minor: 20, patch: 0 }) === 0) return 'B';
  return null;
}
