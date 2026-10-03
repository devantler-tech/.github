// Point a JavaScript action at the offline API stand-in.
//
// The runner re-exports its own GITHUB_* values after it applies a step's `env:`, so a
// workflow cannot hand an action another API address or event that way. A step loads this
// file through NODE_OPTIONS=--require instead; it runs inside the action's own process,
// before the action reads its environment, and replaces each GITHUB_<NAME> that has an
// OFFLINE_GITHUB_<NAME> counterpart.
//
// It fails closed: without a loopback stand-in address the action never starts, and the
// process cannot resolve any other host. Each refused host is appended to
// OFFLINE_BLOCKED_HOSTS_FILE so the test can assert what the action tried to reach.
'use strict';

const dns = require('node:dns');
const fs = require('node:fs');

const prefix = 'OFFLINE_GITHUB_';
const required = ['API_URL', 'EVENT_NAME', 'EVENT_PATH', 'REPOSITORY'];
const blockedHostsFile = process.env.OFFLINE_BLOCKED_HOSTS_FILE || '';

function refuse(message) {
  process.stderr.write(`::error::offline-github-env: ${message}\n`);
  process.exit(1);
}

for (const name of required) {
  if (!process.env[prefix + name]) refuse(`${prefix}${name} is not set; refusing to start the action against a live API.`);
}
if (!/^http:\/\/127\.0\.0\.1:[0-9]+$/.test(process.env[`${prefix}API_URL`])) {
  refuse(`${prefix}API_URL must be the loopback stand-in (http://127.0.0.1:<port>).`);
}
if (!blockedHostsFile) refuse('OFFLINE_BLOCKED_HOSTS_FILE is not set.');

for (const [name, value] of Object.entries(process.env)) {
  if (name.startsWith(prefix)) process.env[`GITHUB_${name.slice(prefix.length)}`] = value;
}
process.env.GITHUB_GRAPHQL_URL = `${process.env.GITHUB_API_URL}/graphql`;

const lookup = dns.lookup;
dns.lookup = function offlineLookup(hostname, options, callback) {
  if (hostname === 'localhost') return lookup.call(dns, hostname, options, callback);
  const done = typeof options === 'function' ? options : callback;
  fs.appendFileSync(blockedHostsFile, `${hostname}\n`);
  const error = new Error(`offline-github-env: refused to resolve ${hostname}`);
  error.code = 'ENOTFOUND';
  error.syscall = 'getaddrinfo';
  error.hostname = hostname;
  process.nextTick(done, error);
  return {};
};
