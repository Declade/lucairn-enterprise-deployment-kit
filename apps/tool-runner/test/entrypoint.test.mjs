// Unit tests of the tool runner image entrypoint. Run: node --test apps/tool-runner/test/
// Synthetic values only. The "runner" started here is a stub script, so no
// network request is made and no ServiceNow instance is contacted.
import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createHash } from 'node:crypto';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readSettings, configDocument, handoffLine, signingKeyProblem, codeDigest, verifyCodeDigest, launch, EntrypointError } from '../entrypoint.mjs';

const PREFIX = '302e020100300506032b657004220420';
const keyOf = (seedHex) => Buffer.from(PREFIX + seedHex, 'hex').toString('base64');
const realKey = () => generateKeyPairSync('ed25519').privateKey.export({ type: 'pkcs8', format: 'der' }).toString('base64');
const SHA = 'a'.repeat(64);
const ENV = { TOOL_RUNNER_INSTANCE_URL: 'https://example-dev.service-now.com', TOOL_RUNNER_INSTANCE_CLASS: 'dev', TOOL_RUNNER_PRINCIPAL: 'kit-test@example.test', TOOL_RUNNER_POLICY_SHA256: SHA };

function fixture(t, files = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'trk-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const secretsDir = join(dir, 'secrets'); mkdirSync(secretsDir);
  const all = { tool_runner_servicenow_username: 'svc.lucairn.test\n', tool_runner_servicenow_password: 'synthetic-password-not-real\n', tool_runner_signing_key: realKey() + '\n', ...files };
  for (const [name, value] of Object.entries(all)) if (value !== null) writeFileSync(join(secretsDir, name), value);
  const policyFile = join(dir, 'policy.json'); writeFileSync(policyFile, '{}\n');
  return { dir, settings: readSettings({ ...ENV, TOOL_RUNNER_SECRETS_DIR: secretsDir, TOOL_RUNNER_RUN_DIR: join(dir, 'run'), TOOL_RUNNER_DATA_DIR: join(dir, 'data'), TOOL_RUNNER_POLICY_FILE: policyFile }) };
}

test('settings: a ServiceNow or Lucairn-key variable in the environment refuses the start, names only', () => {
  for (const name of ['SN_PASSWORD', 'snow_user', 'SERVICENOW_TOKEN', 'LUCAIRN_TOOL_RUNNER_GATEWAY_KEY']) {
    assert.throws(() => readSettings({ ...ENV, [name]: 'value-that-must-not-be-echoed' }), (e) => e instanceof EntrypointError && e.message.includes(name) && !e.message.includes('value-that-must-not-be-echoed'));
  }
});

test('settings: instance class has no default; instance, principal and digest are required', () => {
  assert.throws(() => readSettings({ ...ENV, TOOL_RUNNER_INSTANCE_CLASS: '' }), /INSTANCE_CLASS/);
  assert.throws(() => readSettings({ ...ENV, TOOL_RUNNER_INSTANCE_CLASS: 'production' }), /INSTANCE_CLASS/);
  assert.throws(() => readSettings({ ...ENV, TOOL_RUNNER_INSTANCE_URL: 'http://example-dev.service-now.com' }), /INSTANCE_URL/);
  assert.throws(() => readSettings({ ...ENV, TOOL_RUNNER_PRINCIPAL: ' ' }), /PRINCIPAL/);
  assert.throws(() => readSettings({ ...ENV, TOOL_RUNNER_POLICY_SHA256: 'abc' }), /POLICY_SHA256/);
});

test('config document holds no secret and adds the gateway only when configured', (t) => {
  const { settings } = fixture(t);
  const doc = configDocument(settings);
  assert.deepEqual(Object.keys(doc).sort(), ['agent_client', 'data_dir', 'instance', 'instance_class', 'policy', 'principal']);
  assert.equal(configDocument({ ...settings, gatewayUrl: 'https://gateway.example.test', scrubBudget: 20 }).gateway.max_new_requests_per_call, 20);
});

test('signing key: development defaults are refused, a generated key is accepted', () => {
  assert.equal(signingKeyProblem(realKey()), null);
  const seq = Array.from({ length: 32 }, (_, i) => i.toString(16).padStart(2, '0')).join('');
  for (const seed of ['00'.repeat(32), '11'.repeat(32), 'ff'.repeat(32), seq, '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60']) {
    assert.match(signingKeyProblem(keyOf(seed)), /development default/);
  }
  assert.match(signingKeyProblem('CHANGE-ME'), /base64/);
  assert.match(signingKeyProblem(Buffer.alloc(48, 7).toString('base64')), /Ed25519/);
});

test('handoff line: one JSON line with exactly the keys the runner accepts', (t) => {
  const { settings } = fixture(t, { tool_runner_gateway_key: '', tool_runner_approver_secret: 'A'.repeat(43) + '\n' });
  const buf = handoffLine(settings);
  const text = buf.toString('utf8');
  assert.equal(text.indexOf('\n'), text.length - 1);
  const doc = JSON.parse(text);
  assert.deepEqual(Object.keys(doc).sort(), ['approver_secret', 'policy_sha256', 'servicenow', 'signing_key']);
  assert.equal(doc.servicenow.username, 'svc.lucairn.test');
  assert.equal(doc.policy_sha256, SHA);
});

test('handoff line: missing, empty or multi-line secrets and a dev-default key are refused without echoing them', (t) => {
  assert.throws(() => handoffLine(fixture(t, { tool_runner_servicenow_password: null }).settings), /tool_runner_servicenow_password is missing/);
  assert.throws(() => handoffLine(fixture(t, { tool_runner_servicenow_password: '\n' }).settings), /is empty/);
  assert.throws(() => handoffLine(fixture(t, { tool_runner_servicenow_password: 'line-one\nline-two\n' }).settings), (e) => /exactly one line/.test(e.message) && !e.message.includes('line-one'));
  assert.throws(() => handoffLine(fixture(t, { tool_runner_signing_key: keyOf('00'.repeat(32)) }).settings), /development default/);
  assert.throws(() => handoffLine(fixture(t, { tool_runner_approver_secret: 'too-short' }).settings), /approver secret/);
});

test('code digest: the kit copy of the algorithm, and a changed file is detected', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'trk-code-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const d of ['bin', 'src/writes', 'presets']) mkdirSync(join(root, d), { recursive: true });
  const files = { 'package.json': '{}', 'package-lock.json': '{}', 'bin/lucairn-tool-runner.mjs': '//bin', 'src/a.mjs': '//a', 'src/writes/b.mjs': '//b', 'presets/p.json': '{}', 'src/ignored.txt': 'x' };
  for (const [f, c] of Object.entries(files)) writeFileSync(join(root, f), c);
  const h = createHash('sha256');
  for (const f of ['bin/lucairn-tool-runner.mjs', 'package-lock.json', 'package.json', 'presets/p.json', 'src/a.mjs', 'src/writes/b.mjs']) h.update(`${f}\0${createHash('sha256').update(files[f]).digest('hex')}\n`);
  const expected = h.digest('hex');
  assert.equal(codeDigest(root), expected);
  const pinned = join(root, 'pinned'); writeFileSync(pinned, expected + '\n');
  assert.equal(verifyCodeDigest(root, pinned), expected);
  writeFileSync(join(root, 'src/writes/b.mjs'), '//changed');
  assert.throws(() => verifyCodeDigest(root, pinned), /do not match the code digest/);
  assert.throws(() => verifyCodeDigest(root, join(root, 'absent')), /no recorded runner code digest/);
});

test('launch: secrets reach the runner on stdin only — not in argv, not in the environment, not in the config file', async (t) => {
  const { dir, settings } = fixture(t);
  const stub = join(dir, 'stub-runner.mjs');
  const report = join(dir, 'report.json');
  writeFileSync(stub, `import { writeFileSync } from 'node:fs';
let buf = '';
process.stdin.on('data', (c) => { buf += c; if (buf.includes('\\n')) { writeFileSync(${JSON.stringify(report)}, JSON.stringify({ argv: process.argv.slice(2), env: process.env, line: buf })); process.exit(0); } });
`);
  const child = launch(settings, { runnerBin: stub });
  const code = await new Promise((r) => child.once('exit', r));
  assert.equal(code, 0);
  const seen = JSON.parse(readFileSync(report, 'utf8'));
  const password = 'synthetic-password-not-real';
  assert.ok(JSON.parse(seen.line).servicenow.password === password);
  assert.ok(!seen.argv.join(' ').includes(password));
  assert.deepEqual(seen.argv.slice(0, 1), ['serve']);
  assert.ok(seen.argv.includes('--secrets-fd') && seen.argv[seen.argv.indexOf('--secrets-fd') + 1] === '0');
  assert.ok(!JSON.stringify(seen.env).includes(password));
  assert.ok(Object.keys(seen.env).every((k) => !/^(SN|SNOW|SERVICENOW|TOOL_RUNNER)_/i.test(k)));
  const config = readFileSync(join(settings.runDir, 'config.json'), 'utf8');
  assert.ok(!config.includes(password) && !config.includes(JSON.parse(seen.line).signing_key));
});

test('launch: no policy file mounted starts nothing', (t) => {
  const { settings } = fixture(t);
  rmSync(settings.policyFile);
  assert.throws(() => launch(settings, { spawnImpl: () => { throw new Error('must not spawn'); } }), /policy file is not mounted/);
  assert.ok(!existsSync(join(settings.runDir, 'config.json')));
});
