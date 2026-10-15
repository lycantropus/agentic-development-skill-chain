#!/usr/bin/env node
// Operational receipts stay outside tracked files and survive a killed lane.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import os from 'node:os';
const [action, dir, run, ...args] = process.argv.slice(2);
fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
function identity(pid) {
  try {
    if (process.platform === 'linux') {
      const stat = fs.readFileSync(`/proc/${pid}/stat`, 'utf8');
      if (['Z', 'X'].includes(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[0])) return 'exited';
      return `${fs.readFileSync('/proc/sys/kernel/random/boot_id', 'utf8').trim()}:${stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19]}`;
    }
    return execFileSync('ps', ['-p', String(pid), '-o', 'lstart='], { encoding: 'utf8', env: { ...process.env, LC_ALL: 'C', TZ: 'UTC' } }).trim() || null;
  } catch { return null; }
}
function save(file, value) {
  const temp = `${file}.${process.pid}.tmp`;
  const fd = fs.openSync(temp, 'w', 0o600);
  try { fs.writeFileSync(fd, `${JSON.stringify(value)}\n`); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  fs.renameSync(temp, file);
}
const receipts = () => fs.readdirSync(dir).filter(n => n.endsWith('.json')).map(n => [path.join(dir, n), JSON.parse(fs.readFileSync(path.join(dir, n), 'utf8'))]);
if (action === 'start') {
  const [owner, phase, provider, role, output] = args;
  const ownerIdentity = identity(owner);
  if (!ownerIdentity) throw new Error('Cannot establish supervisor identity; refusing lane launch');
  const id = randomUUID();
  save(path.join(dir, `${id}.json`), { id, run, host: os.hostname(), owner: Number(owner), owner_identity: ownerIdentity, phase, provider, role, output, started_at: new Date().toISOString(), status: 'started', settled: false });
  console.log(id);
} else if (action === 'attach') {
  const [id, child] = args;
  if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id || '') || !/^\d+$/.test(child || '')) throw new Error('Invalid attach arguments');
  const file = path.join(dir, `${id}.json`), r = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (r.run !== run || r.settled || r.host !== os.hostname() || identity(r.owner) !== r.owner_identity) throw new Error('Supervisor no longer owns this lane; refusing provider launch');
  const childIdentity = identity(child);
  if (!childIdentity) throw new Error('Cannot identify lane process; refusing provider launch');
  Object.assign(r, { child_pid: Number(child), child_identity: childIdentity });
  save(file, r);
} else if (action === 'finish') {
  const [id, exit, timedOut] = args;
  if (!/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id || '') || !/^\d+$/.test(exit || '') || !['0', '1'].includes(timedOut)) throw new Error('Invalid finish receipt arguments');
  const file = path.join(dir, `${id}.json`), r = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (r.run !== run) throw new Error('Receipt belongs to another run');
  const code = Number(exit);
  // Shell exit conventions do not prove a signal: record the convention, not OOM.
  Object.assign(r, { status: code === 0 ? 'completed' : code > 128 && code < 193 ? 'interrupted' : 'failed', ended_at: new Date().toISOString(), exit_code: code, signal: code > 128 && code < 193 ? (os.constants.signals && Object.keys(os.constants.signals).find(k => os.constants.signals[k] === code - 128)) || null : null, signal_evidence: code > 128 ? 'shell exit status convention; explicit exit may match' : null, timed_out: timedOut === '1' });
  save(file, r);
} else if (action === 'settle') {
  for (const [file, r] of receipts()) if (r.run === run && !r.settled) { r.settled = true; r.phase_outcome = args[0]; save(file, r); }
} else if (action === 'reconcile') {
  const pending = receipts().filter(([, r]) => !r.settled);
  // Check all ownership before writing: a concurrent runner may still be alive.
  for (const [, r] of pending) {
    if (r.host !== os.hostname()) { console.error('Receipt owner host differs; verify the prior supervisor before restarting'); process.exit(3); }
    const current = identity(r.owner);
    if (current === r.owner_identity) { console.error(`live supervisor ${r.owner} owns pending lane ${r.id}; stop that runner before restarting`); process.exit(3); }
    try {
      process.kill(r.owner, 0);
      if (!current) { console.error('Cannot verify supervisor identity; inspect the pending receipt before restarting'); process.exit(3); }
    } catch (e) {
      if (e.code !== 'ESRCH') { console.error('Cannot verify supervisor liveness; inspect the pending receipt before restarting'); process.exit(3); }
    }
  }
  for (const [file, r] of pending) {
    if (!r.child_pid) continue;
    const current = identity(r.child_pid);
    let active = current === r.child_identity;
    if (!current) {
      try { process.kill(r.child_pid, 0); active = true; }
      catch (e) { if (e.code !== 'ESRCH') active = true; }
    }
    if (active) {
      Object.assign(r, { status: 'interrupted', reason: current ? 'supervisor missing; attached lane is still running' : 'supervisor missing; attached lane identity cannot be verified' });
      save(file, r);
      console.error(current ? `Prior lane ${r.child_pid} is still running without its supervisor; inspect and stop that lane before restarting` : `Cannot verify prior lane ${r.child_pid} identity; inspect that lane before restarting`);
      process.exit(3);
    }
  }
  for (const [file, r] of pending) {
    Object.assign(r, { status: 'interrupted', settled: true, phase_outcome: 'unverified', reconciled_at: new Date().toISOString(), reason: 'supervisor ended without completing phase verification' });
    // Keep any observed child exit, but never invent the supervisor's signal.
    if (!('signal' in r)) r.signal = null;
    save(file, r);
    console.error(`Unverified ${r.phase} lane ${r.id}: supervisor ended without completing phase verification`);
  }
  if (pending.length) process.exit(2);
} else throw new Error(`Unknown journal action: ${action}`);
