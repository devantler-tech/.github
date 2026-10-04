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
// OFFLINE_BLOCKED_HOSTS_FILE so the test can assert what the action tried to reach, and
// everything the action prints is copied to OFFLINE_ACTION_LOG_FILE so the test can assert
// the errors and warnings it raised.
//
// This routes the action and detects a regression; it is not a sandbox. What keeps a test
// from changing anything live is the job's read-only token and the fixture token the
// action is given.
'use strict';

const dns = require('node:dns');
const fs = require('node:fs');

const prefix = 'OFFLINE_GITHUB_';
const required = ['API_URL', 'EVENT_NAME', 'EVENT_PATH', 'REPOSITORY'];
const blockedHostsFile = process.env.OFFLINE_BLOCKED_HOSTS_FILE || '';
const actionLogFile = process.env.OFFLINE_ACTION_LOG_FILE || '';

/**
 * Stop the process before the action's own code runs.
 * @param {string} message why the action must not start
 */
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
if (!actionLogFile) refuse('OFFLINE_ACTION_LOG_FILE is not set.');

for (const stream of [process.stdout, process.stderr]) {
  const write = stream.write;
  /**
   * Copy a chunk the action prints to the action log, then print it as usual.
   * @param {string|Uint8Array} chunk the text or bytes being printed
   * @param {...*} rest the encoding and callback of the original call
   * @returns {boolean} what the stream's own write returned
   */
  stream.write = function offlineTee(chunk, ...rest) {
    fs.appendFileSync(actionLogFile, chunk);
    return write.call(this, chunk, ...rest);
  };
}

for (const [name, value] of Object.entries(process.env)) {
  if (name.startsWith(prefix)) process.env[`GITHUB_${name.slice(prefix.length)}`] = value;
}
process.env.GITHUB_GRAPHQL_URL = `${process.env.GITHUB_API_URL}/graphql`;

const lookup = dns.lookup;
/**
 * Replace dns.lookup: resolve localhost as usual, and record and refuse every other host.
 * The stand-in's own address is an IP literal, which Node connects to without a lookup.
 * @param {string} hostname the host a connection asked for
 * @param {object|Function} options lookup options, or the callback when none were given
 * @param {Function} [callback] receives the refusal as an ENOTFOUND error
 * @returns {object} an empty request handle, as dns.lookup returns
 */
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
