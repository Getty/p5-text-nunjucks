#!/usr/bin/env node
// The oracle: runs cases through the pinned upstream Nunjucks and prints what
// the original does. The Perl port is measured against this output, never
// against a reading of the docs.
//
//   node maint/oracle.js < cases.json > results.json
//   node maint/oracle.js cases.json
//
// Input: one case object or an array of them.
//   { "name": "...",                       // echoed back
//     "mode": "render" | "lex" | "parse",  // default "render"
//     "template": "{{ a }}",               // source string, or
//     "render": "page.njk",                //   a name looked up in "templates"
//     "templates": { "base.njk": "..." },  // in-memory loader contents
//     "context": { ... },                  // JSON only -- no functions
//     "opts": { "autoescape": true, ... }, // Environment / lexer opts
//     "jinjaCompat": false }
//
// Output: an array, one result per case, in order.
//   { "name", "ok": true,  "output": <string | tokens | ast> }
//   { "name", "ok": false, "error": { "name", "message" } }
'use strict';

const fs = require('fs');
const path = require('path');

const nunjucks = require(path.join(__dirname, '..', 'upstream', 'nunjucks', 'nunjucks', 'index.js'));
const {lexer, parser, nodes} = nunjucks;

class MemoryLoader extends nunjucks.Loader {
  constructor(templates) {
    super();
    this.templates = templates || {};
  }
  getSource(name) {
    if (!Object.prototype.hasOwnProperty.call(this.templates, name)) {
      return null;
    }
    return {src: this.templates[name], path: name, noCache: true};
  }
}

function lex(c) {
  const tokens = [];
  const t = lexer.lex(c.template, c.opts);
  let tok;
  while ((tok = t.nextToken())) {
    tokens.push({type: tok.type, value: tok.value, lineno: tok.lineno, colno: tok.colno});
  }
  return tokens;
}

// AST as plain JSON: { type, lineno, colno, <fields in nodes.js order> }.
// NodeList-likes carry "children". Non-node field values pass through as-is;
// a RegExp literal becomes { regex: source, flags }.
function ast(n) {
  if (n instanceof nodes.Node) {
    const out = {type: n.typename, lineno: n.lineno, colno: n.colno};
    n.fields.forEach((f) => { out[f] = ast(n[f]); });
    return out;
  }
  if (Array.isArray(n)) {
    return n.map(ast);
  }
  if (n instanceof RegExp) {
    return {regex: n.source, flags: n.flags};
  }
  return n === undefined ? null : n;
}

// Always the callback form: it is the only one that covers async tags and
// filters, and upstream defers the callback (asap) even for sync templates.
function render(c) {
  const env = new nunjucks.Environment(new MemoryLoader(c.templates), c.opts);
  const ctx = c.context || {};
  return new Promise((resolve, reject) => {
    const cb = (err, res) => (err ? reject(err) : resolve(res));
    if (c.render !== undefined) {
      env.render(c.render, ctx, cb);
    } else {
      env.renderString(c.template, ctx, cb);
    }
  });
}

async function run(c) {
  const uninstall = c.jinjaCompat ? nunjucks.installJinjaCompat() : null;
  try {
    const mode = c.mode || 'render';
    const output = mode === 'lex' ? lex(c)
      : mode === 'parse' ? ast(parser.parse(c.template, [], c.opts))
        : await render(c);
    return {name: c.name, ok: true, output: output};
  } catch (e) {
    return {name: c.name, ok: false, error: {name: e.name, message: e.message}};
  } finally {
    if (uninstall) {
      uninstall();
    }
  }
}

async function main() {
  const input = JSON.parse(fs.readFileSync(process.argv[2] || 0, 'utf8'));
  const cases = Array.isArray(input) ? input : [input];
  const results = [];
  // Sequential on purpose: installJinjaCompat patches global state.
  for (const c of cases) {
    results.push(await run(c));
  }
  process.stdout.write(JSON.stringify(results, null, 2) + '\n');
}

main();
