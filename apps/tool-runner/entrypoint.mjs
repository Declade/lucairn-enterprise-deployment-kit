#!/usr/bin/env node
// Container entrypoint of the Lucairn tool runner image (Preview).
//
// The runner takes its secrets as ONE line of JSON on an inherited descriptor
// and never from the environment, a command-line argument or a file it reads
// itself. This entrypoint is the "launcher" of that contract inside the
// container:
//
//   1. refuses to start when a ServiceNow or Lucairn-key variable is in the
//      environment (names only are printed, never values);
//   2. recomputes the runner's code digest and compares it with the digest
//      recorded when the image was built;
//   3. reads the mounted secret files (Docker secrets / a Kubernetes Secret
//      volume), builds the handoff line in memory, and writes it to the
//      runner's stdin. Nothing secret is written to disk, exported, or put on
//      a command line;
//   4. writes the runner's config file (it holds NO secret) to a tmpfs
//      directory and starts `serve --secrets-fd 0 --socket <path>`;
//   5. keeps the pipe open. The runner ends when this process ends.
//
// Other modes (no secret is read in any of them):
//   --healthcheck               exit 0 when the runner's socket accepts a connection
//   --validate-policy <file>    validate a policy file with the runner's own validator, print its sha256
//   --print-code-digest         print the code digest of the runner in this image
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, writeFileSync, mkdirSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import net from 'node:net';
import { pathToFileURL } from 'node:url';

export const RUNNER_ROOT = '/opt/lucairn-tool-runner';
export const PINNED_DIGEST_FILE = '/opt/lucairn-kit/runner-code-digest';
export const DEFAULTS = Object.freeze({
  secretsDir: '/run/secrets',
  runDir: '/run/tool-runner',
  dataDir: '/var/lib/lucairn-tool-runner',
  policyFile: '/etc/lucairn-tool-runner/policy.json',
});
/** Names an environment must never carry into the runner (the runner's own rule, checked here first). */
export const FORBIDDEN_ENV_RE = /^(SN|SNOW|SERVICENOW)_/i;
export const GATEWAY_KEY_ENV = 'LUCAIRN_TOOL_RUNNER_GATEWAY_KEY';
const SECRET_FILES = Object.freeze({
  username: 'tool_runner_servicenow_username',
  password: 'tool_runner_servicenow_password',
  signingKey: 'tool_runner_signing_key',
  gatewayKey: 'tool_runner_gateway_key',
  approverSecret: 'tool_runner_approver_secret',
});
const MAX_SECRET_BYTES = 8 * 1024;

export class EntrypointError extends Error {}

/** The runner's code digest, computed with this file's OWN copy of the algorithm (never by asking the runner). */
export function codeDigest(root) {
  const list = (dir, ext) => readdirSync(join(root, dir)).filter((f) => f.endsWith(ext)).map((f) => `${dir}/${f}`);
  const deep = (dir) => readdirSync(join(root, dir), { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? deep(`${dir}/${e.name}`) : e.isFile() && e.name.endsWith('.mjs') ? [`${dir}/${e.name}`] : []));
  const files = ['package.json', 'package-lock.json', 'bin/lucairn-tool-runner.mjs', ...deep('src'), ...list('presets', '.json')].sort();
  const h = createHash('sha256');
  for (const f of files) h.update(`${f}\0${createHash('sha256').update(readFileSync(join(root, f))).digest('hex')}\n`);
  return h.digest('hex');
}

// An Ed25519 private key in PKCS8 DER is this 16-byte header followed by the 32-byte seed.
const PKCS8_ED25519_PREFIX = '302e020100300506032b657004220420';
// Seeds that are published somewhere (RFC 8032 test vector 1) or trivially guessable.
const KNOWN_SEEDS = new Set(['9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60']);

/**
 * Why a signing key must not be used, or null when it is acceptable.
 * @param {string} b64 base64 PKCS8 DER
 * @returns {string|null}
 */
export function signingKeyProblem(b64) {
  if (typeof b64 !== 'string' || !/^[A-Za-z0-9+/]{40,400}={0,2}$/.test(b64)) return 'not base64';
  const hex = Buffer.from(b64, 'base64').toString('hex');
  if (hex.length !== 96 || !hex.startsWith(PKCS8_ED25519_PREFIX)) return 'not an Ed25519 private key in PKCS8 DER form';
  const seed = hex.slice(32);
  const bytes = seed.match(/../g);
  const sameByte = bytes.every((b) => b === bytes[0]);
  const step = (d) => bytes.every((b, i) => i === 0 || parseInt(b, 16) === ((parseInt(bytes[i - 1], 16) + d) & 0xff));
  if (sameByte || step(1) || step(-1) || KNOWN_SEEDS.has(seed)) return 'a development default (a repeated-byte, counting or published test seed)';
  return null;
}

function readSecretFile(dir, name, { optional = false } = {}) {
  const p = join(dir, name);
  let st;
  try { st = statSync(p); } catch { if (optional) return null; throw new EntrypointError(`secret file ${name} is missing (mount it as a Docker secret or from the Kubernetes Secret)`); }
  if (!st.isFile()) throw new EntrypointError(`secret file ${name} is not a regular file`);
  if (st.size > MAX_SECRET_BYTES) throw new EntrypointError(`secret file ${name} is larger than ${MAX_SECRET_BYTES} bytes`);
  let text;
  try { text = readFileSync(p, 'utf8'); } catch { throw new EntrypointError(`secret file ${name} is not readable by the runner user (check its owner and mode)`); }
  const value = text.replace(/\r?\n$/, '');
  if (/[\r\n\0]/.test(value)) throw new EntrypointError(`secret file ${name} must hold exactly one line`);
  if (value === '') { if (optional) return null; throw new EntrypointError(`secret file ${name} is empty`); }
  return value;
}

/**
 * Read the non-secret settings from the container environment.
 * @param {Record<string,string|undefined>} env
 */
export function readSettings(env) {
  const found = Object.keys(env).filter((k) => FORBIDDEN_ENV_RE.test(k) || k.toUpperCase() === GATEWAY_KEY_ENV);
  if (found.length) throw new EntrypointError(`refusing to start: ${found.sort().join(', ')} found in the environment. The ServiceNow credential and the Lucairn key are mounted as secret files and must not be passed through the environment.`);
  const get = (k) => (typeof env[k] === 'string' ? env[k].trim() : '');
  const instance = get('TOOL_RUNNER_INSTANCE_URL').replace(/\/$/, '');
  if (!/^https:\/\/[a-z0-9-]+\.service-now\.com$/.test(instance)) throw new EntrypointError('TOOL_RUNNER_INSTANCE_URL must be an https://<name>.service-now.com URL');
  const instanceClass = get('TOOL_RUNNER_INSTANCE_CLASS');
  if (!['dev', 'test', 'prod'].includes(instanceClass)) throw new EntrypointError('TOOL_RUNNER_INSTANCE_CLASS must be set to dev, test or prod (there is no default)');
  const principal = get('TOOL_RUNNER_PRINCIPAL');
  if (principal === '' || principal.length > 200) throw new EntrypointError('TOOL_RUNNER_PRINCIPAL is required (the identity the receipts name, at most 200 characters)');
  const policySha256 = get('TOOL_RUNNER_POLICY_SHA256').toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(policySha256)) throw new EntrypointError('TOOL_RUNNER_POLICY_SHA256 must be the sha256 of the policy file (64 hex characters; `lucairn tool-policy digest <file>` prints it)');
  const gatewayUrl = get('TOOL_RUNNER_GATEWAY_URL').replace(/\/$/, '');
  const budgetRaw = get('TOOL_RUNNER_SCRUB_BUDGET');
  if (budgetRaw !== '' && !/^\d{1,3}$/.test(budgetRaw)) throw new EntrypointError('TOOL_RUNNER_SCRUB_BUDGET must be a whole number');
  return {
    instance, instanceClass, principal, policySha256, gatewayUrl,
    scrubBudget: budgetRaw === '' ? null : Number(budgetRaw),
    secretsDir: get('TOOL_RUNNER_SECRETS_DIR') || DEFAULTS.secretsDir,
    runDir: get('TOOL_RUNNER_RUN_DIR') || DEFAULTS.runDir,
    dataDir: get('TOOL_RUNNER_DATA_DIR') || DEFAULTS.dataDir,
    policyFile: get('TOOL_RUNNER_POLICY_FILE') || DEFAULTS.policyFile,
  };
}

/** The runner's config document. It holds no secret and names no secret. */
export function configDocument(s) {
  const doc = { instance: s.instance, instance_class: s.instanceClass, principal: s.principal, policy: s.policyFile, data_dir: s.dataDir, agent_client: 'kit-mcp-client' };
  if (s.gatewayUrl) doc.gateway = { base_url: s.gatewayUrl, ...(s.scrubBudget === null ? {} : { max_new_requests_per_call: s.scrubBudget }) };
  return doc;
}

/**
 * Build the handoff line from the mounted secret files. The caller overwrites
 * the returned buffer after writing it.
 * @returns {Buffer}
 */
export function handoffLine(s) {
  const signingKey = readSecretFile(s.secretsDir, SECRET_FILES.signingKey);
  const problem = signingKeyProblem(signingKey);
  if (problem) throw new EntrypointError(`refusing to start: the receipt signing key is ${problem}. Generate one: openssl genpkey -algorithm ed25519 -outform DER | base64 | tr -d '\\n'`);
  const doc = {
    servicenow: { username: readSecretFile(s.secretsDir, SECRET_FILES.username), password: readSecretFile(s.secretsDir, SECRET_FILES.password) },
    signing_key: signingKey,
    policy_sha256: s.policySha256,
  };
  const gatewayKey = readSecretFile(s.secretsDir, SECRET_FILES.gatewayKey, { optional: true });
  if (gatewayKey !== null) doc.gateway_key = gatewayKey;
  const approver = readSecretFile(s.secretsDir, SECRET_FILES.approverSecret, { optional: true });
  if (approver !== null) {
    if (!/^[A-Za-z0-9_-]{43,128}$/.test(approver)) throw new EntrypointError('the approver secret must be base64url, at least 43 characters (openssl rand -base64 32 | tr "+/" "-_" | tr -d "=\\n")');
    doc.approver_secret = approver;
  }
  return Buffer.from(JSON.stringify(doc) + '\n', 'utf8');
}

export function verifyCodeDigest(root = RUNNER_ROOT, pinnedFile = PINNED_DIGEST_FILE) {
  let pinned;
  try { pinned = readFileSync(pinnedFile, 'utf8').trim(); } catch { throw new EntrypointError('refusing to start: the image carries no recorded runner code digest'); }
  if (!/^[0-9a-f]{64}$/.test(pinned) || codeDigest(root) !== pinned) throw new EntrypointError('refusing to start: the runner files do not match the code digest recorded when this image was built');
  return pinned;
}

/**
 * Start the runner and hand the secrets over on its stdin.
 * @param {object} s settings from readSettings
 * @param {{node?: string, runnerBin?: string, spawnImpl?: typeof spawn, pathEnv?: string}} [deps]
 * @returns {import('node:child_process').ChildProcess}
 */
export function launch(s, { node = process.execPath, runnerBin = join(RUNNER_ROOT, 'bin/lucairn-tool-runner.mjs'), spawnImpl = spawn, pathEnv = process.env.PATH || '/usr/local/bin:/usr/bin:/bin' } = {}) {
  if (!existsSync(s.policyFile) || !statSync(s.policyFile).isFile()) throw new EntrypointError(`the policy file is not mounted at ${s.policyFile}`);
  mkdirSync(s.runDir, { recursive: true, mode: 0o700 });
  const configPath = join(s.runDir, 'config.json');
  writeFileSync(configPath, JSON.stringify(configDocument(s), null, 2) + '\n', { mode: 0o600 });
  const line = handoffLine(s);
  // The child gets a minimal environment: nothing of this process's environment travels on.
  const child = spawnImpl(node, [runnerBin, 'serve', '--config', configPath, '--secrets-fd', '0', '--socket', join(s.runDir, 'mcp.sock')], { stdio: ['pipe', 'inherit', 'inherit'], env: { PATH: pathEnv } });
  child.stdin.on('error', () => {});
  // The pipe stays open on purpose: its closing is how the runner learns that its launcher is gone.
  child.stdin.write(line, () => line.fill(0));
  return child;
}

function healthcheck(socketPath) {
  return new Promise((resolve) => {
    const conn = net.connect(socketPath);
    const done = (code) => { conn.destroy(); resolve(code); };
    conn.setTimeout(3000, () => done(1));
    conn.once('error', () => done(1));
    conn.once('connect', () => done(0));
  });
}

async function validatePolicy(file) {
  const { loadPolicyFile } = await import(pathToFileURL(join(RUNNER_ROOT, 'src/policy.mjs')).href);
  const policy = loadPolicyFile(file);
  console.log(`policy: valid (${Object.keys(policy.enabled).length} preset(s))`);
  console.log(`sha256: ${createHash('sha256').update(readFileSync(file)).digest('hex')}`);
}

async function main(argv) {
  if (argv[0] === '--print-code-digest') { console.log(codeDigest(argv[1] || RUNNER_ROOT)); return 0; }
  if (argv[0] === '--healthcheck') return healthcheck(join(process.env.TOOL_RUNNER_RUN_DIR || DEFAULTS.runDir, 'mcp.sock'));
  if (argv[0] === '--validate-policy') {
    if (!argv[1]) throw new EntrypointError('usage: --validate-policy <file>');
    try { await validatePolicy(argv[1]); } catch (e) { throw new EntrypointError(`policy: invalid (${e?.message || 'error'})`); }
    return 0;
  }
  if (argv.length) throw new EntrypointError('usage: entrypoint.mjs [--healthcheck | --validate-policy <file> | --print-code-digest]');
  const settings = readSettings(process.env);
  verifyCodeDigest();
  const child = launch(settings);
  for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { try { child.kill(sig); } catch { /* gone */ } });
  return new Promise((resolve) => {
    child.once('error', () => { console.error('lucairn-tool-runner: the runner process could not be started'); resolve(1); });
    child.once('exit', (code, signal) => resolve(signal ? 1 : (code ?? 1)));
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then((code) => process.exit(code), (e) => {
    // Messages are built here and never echo a secret value.
    console.error(`lucairn-tool-runner: ${e instanceof EntrypointError ? e.message : 'entrypoint error'}`);
    process.exit(2);
  });
}
