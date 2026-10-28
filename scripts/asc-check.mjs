#!/usr/bin/env node
// App Store Connect pre-flight.
//
// Validates an API key and reports what the account can actually see, before
// a 10-minute archive/upload run is spent on it:
//   - does the key authenticate (right key id / issuer / role)?
//   - does the app record for the harness exist?
//   - is the bundle id registered?
//
// Usage:
//   ASC_KEY_ID=ABC123DEFG \
//   ASC_ISSUER_ID=69a6de7c-... \
//   node scripts/asc-check.mjs [--bundle com.sheigl.CraftRoomAI] [--key <path>]
//
// Key path defaults to ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8.
// No dependencies: ES256 signing uses node:crypto with ieee-p1363 encoding,
// which is exactly the raw r||s form JOSE requires.

import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

const keyId = process.env.ASC_KEY_ID;
const issuerId = process.env.ASC_ISSUER_ID;
const bundleId = arg('bundle', 'com.sheigl.CraftRoomAI');
const keyPath = arg('key', keyId ? join(homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${keyId}.p8`) : null);

if (!keyId || !issuerId || !keyPath) {
  console.error('need ASC_KEY_ID, ASC_ISSUER_ID (env) and a readable .p8 (--key <path>)');
  process.exit(2);
}

const base64url = (value) => Buffer.from(value).toString('base64url');

function makeToken() {
  const header = { alg: 'ES256', kid: keyId, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: issuerId, iat: now, exp: now + 300, aud: 'appstoreconnect-v1' };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signature = createSign('SHA256')
    .update(signingInput)
    .sign({ key: readFileSync(keyPath, 'utf8'), dsaEncoding: 'ieee-p1363' });
  return `${signingInput}.${signature.toString('base64url')}`;
}

async function api(path, token) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    headers: { Authorization: `Bearer ${token}` }
  });
  const body = await res.text();
  let json;
  try { json = JSON.parse(body); } catch { json = null; }
  return { status: res.status, json, body };
}

const token = makeToken();

const apps = await api('/v1/apps?limit=200', token);
if (apps.status !== 200) {
  console.error(`key rejected (HTTP ${apps.status})`);
  console.error(apps.body.slice(0, 600));
  console.error('\nCommon causes: wrong Issuer ID, key role below App Manager, or a revoked key.');
  process.exit(1);
}

const records = apps.json.data.map((a) => ({
  name: a.attributes.name,
  bundle: a.attributes.bundleId,
  sku: a.attributes.sku,
  id: a.id
}));

console.log(`key OK — ${records.length} app record(s) visible\n`);
for (const r of records) console.log(`  ${r.bundle.padEnd(34)} ${r.name}  (sku ${r.sku})`);

const match = records.find((r) => r.bundle === bundleId);
console.log(match
  ? `\n✓ app record for ${bundleId} exists (id ${match.id}) — TestFlight upload can target it`
  : `\n✗ no app record for ${bundleId} yet — create it in App Store Connect (API cannot: POST /v1/apps is refused)`);

const ids = await api(`/v1/bundleIds?filter[identifier]=${encodeURIComponent(bundleId)}&limit=5`, token);
if (ids.status === 200) {
  const found = ids.json.data.length > 0;
  console.log(found
    ? `✓ bundle id ${bundleId} is registered`
    : `· bundle id ${bundleId} not registered yet — automatic signing will create it on the first archive`);
}
