// offline api explorer. no external code, persistent credentials or automatic device commands.
export function resolve(schema, spec) {
  if (!schema?.$ref) return schema || {};
  if (!schema.$ref.startsWith('#/')) return schema;
  return schema.$ref.slice(2).split('/').reduce((v, k) => v?.[k.replace(/~1/g, '/').replace(/~0/g, '~')], spec) || schema;
}
export function exampleFor(schema, spec, depth = 0) {
  if (depth > 8) return null;
  const s = resolve(schema, spec);
  if (s.examples?.length) return s.examples[0];
  if (s.example !== undefined) return s.example;
  if (s.const !== undefined) return s.const;
  if (s.default !== undefined) return s.default;
  if (s.enum?.length) return s.enum[0];
  if (s.oneOf || s.anyOf) return exampleFor((s.oneOf || s.anyOf)[0], spec, depth + 1);
  if (s.allOf) return Object.assign({}, ...s.allOf.map(x => exampleFor(x, spec, depth + 1)));
  const type = Array.isArray(s.type) ? s.type.find(x => x !== 'null') : s.type;
  if (type === 'object' || s.properties) return Object.fromEntries((s.required || []).filter(k => s.properties?.[k]).map(k => [k, exampleFor(s.properties[k], spec, depth + 1)]));
  if (type === 'array') return Array.from({length: Math.min(s.minItems || 0, 24)}, () => exampleFor(s.items, spec, depth + 1));
  if (type === 'boolean') return false;
  if (type === 'integer' || type === 'number') return s.minimum ?? 0;
  if (type === 'string') return 'x'.repeat(s.minLength || 0);
  return null;
}
export function buildRequest(path, method, op, values, body, contentType) {
  let target = path.replace(/\{([^}]+)\}/g, (_, name) => {
    const value = values[name] || '';
    if (!/^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$/.test(value)) throw Error('enter a valid path parameter: ' + name);
    return encodeURIComponent(value);
  });
  if (!target.startsWith('/') || target.split('/').some(part => part === '.' || part === '..') || /[?#\\]/.test(target)) throw Error('invalid api path');
  const query = new URLSearchParams();
  for (const p of op.parameters || []) {
    if (p.in !== 'query') continue;
    const value = values[p.name];
    if (p.required && (value === undefined || value === '')) throw Error('enter query parameter: ' + p.name);
    if (value !== undefined && value !== '') query.set(p.name, value);
  }
  const options = {method: method.toUpperCase(), headers: {}, credentials: 'omit', redirect: 'error', cache: 'no-store'};
  if (op.requestBody) {
    const size = typeof body === 'string' ? new TextEncoder().encode(body).length : body?.byteLength || 0;
    if (size > 8192) throw Error('request bodies are limited to 8192 bytes; upload sounds in chunks');
    if (!size && op.requestBody.required) throw Error('a request body is required');
    options.headers['content-type'] = contentType;
    if (size) {
      if (contentType === 'application/json') JSON.parse(body);
      options.body = body;
    }
  }
  return {url: '/api/v1' + target + (query.size ? '?' + query : ''), options};
}
export async function readBounded(stream, limit = 65536, onChunk = () => {}) {
  if (!stream) return {bytes: new Uint8Array(), truncated: false};
  const reader = stream.getReader();
  const chunks = [];
  let length = 0;
  let truncated = false;
  try {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      const part = value.subarray(0, limit - length);
      chunks.push(part);
      onChunk(part);
      length += part.length;
      if (length >= limit) { truncated = true; break; }
    }
  } finally {
    try { await reader.cancel(); } catch {}
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const part of chunks) { bytes.set(part, offset); offset += part.length; }
  return {bytes, truncated};
}
const el = (tag, text, cls) => {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (cls) node.className = cls;
  return node;
};
function labelled(text, input) {
  const label = el('label'); label.append(el('span', text), input); return label;
}
function schemaView(schema, spec, title = 'schema') {
  const details = el('details', undefined, 'schema');
  details.append(el('summary', title));
  const s = resolve(schema, spec);
  if (s.description) details.append(el('p', s.description));
  if (s.properties) {
    const table = el('table');
    const head = el('tr');
    for (const text of ['field', 'type / constraints', 'description']) head.append(el('th', text));
    table.append(head);
    for (const [name, field] of Object.entries(s.properties)) {
      const raw = resolve(field, spec);
      const f = resolve((raw.anyOf || raw.oneOf)?.find(x => x.type !== 'null') || raw, spec);
      const row = el('tr');
      const constraints = [Array.isArray(f.type) ? f.type.join(' | ') : f.type || (f.oneOf ? 'one of' : 'object')];
      if (f.enum) constraints.push(f.enum.join(' · '));
      for (const key of ['minimum','maximum','minLength','maxLength','minItems','maxItems','pattern']) if (f[key] !== undefined) constraints.push(key + ': ' + f[key]);
      row.append(el('td', name + ((s.required || []).includes(name) ? ' *' : '')), el('td', constraints.join('\n')), el('td', f.description || field.description || ''));
      table.append(row);
    }
    const wrap = el('div', undefined, 'table-wrap'); wrap.append(table); details.append(wrap);
  }
  details.append(el('pre', JSON.stringify(s, null, 2)));
  return details;
}
function operation(path, method, original, pathParams, spec) {
  const op = {...original, parameters: [...pathParams, ...(original.parameters || [])].map(x => resolve(x, spec))};
  const card = el('details', undefined, 'operation ' + method);
  const summary = el('summary');
  summary.append(el('span', method.toUpperCase(), 'method'), el('code', path), el('span', op.summary || '', 'summary-text'));
  card.append(summary);
  const inside = el('div', undefined, 'operation-body');
  inside.append(el('p', op.description || ''));
  inside.append(el('p', 'required scope: ' + (op['x-required-scope'] || 'see authentication'), 'scope'));
  const params = {};
  for (const p of op.parameters) {
    const input = el('input'); input.type = 'text'; input.autocomplete = 'off';
    input.placeholder = p.example !== undefined ? String(p.example) : p.schema?.default !== undefined ? String(p.schema.default) : '';
    params[p.name] = input;
    inside.append(labelled(p.name + ' · ' + p.in + (p.required ? ' · required' : ''), input));
    if (p.description) inside.append(el('p', p.description, 'hint'));
    inside.append(schemaView(p.schema, spec, p.name + ' schema'));
  }
  const bodySpec = resolve(op.requestBody, spec);
  if (op.requestBody) op.requestBody = bodySpec;
  const media = Object.keys(bodySpec.content || {});
  const type = el('select');
  for (const m of media) { const o = el('option', m); o.value = m; type.append(o); }
  const body = el('textarea'); body.rows = 7; body.spellcheck = false; body.setAttribute('aria-label', 'request body');
  const file = el('input'); file.type = 'file'; file.setAttribute('aria-label', 'binary request body');
  const bodySchemas = el('div');
  const setBody = () => {
    const binary = type.value === 'application/octet-stream';
    body.hidden = binary; file.hidden = !binary;
    const m = bodySpec.content?.[type.value] || {};
    const sample = m.example ?? Object.values(m.examples || {})[0]?.value ?? exampleFor(m.schema, spec);
    body.value = type.value === 'application/json' ? JSON.stringify(sample ?? {}, null, 2) : String(sample ?? '');
    bodySchemas.replaceChildren(schemaView(m.schema, spec, 'request schema'));
  };
  if (media.length) { inside.append(labelled('request content type', type), body, file, bodySchemas); setBody(); type.addEventListener('change', setBody); }
  const responses = el('details', undefined, 'schema'); responses.append(el('summary', 'responses'));
  for (const [status, value] of Object.entries(op.responses || {})) {
    const response = resolve(value, spec);
    responses.append(el('p', status + ' · ' + (response.description || '')));
    for (const [mime, content] of Object.entries(response.content || {})) responses.append(schemaView(content.schema, spec, mime));
  }
  inside.append(responses);
  const run = el('button', 'execute', 'primary'); run.type = 'button';
  const stop = el('button', 'stop'); stop.type = 'button'; stop.disabled = true;
  const output = el('pre', '', 'response'); output.setAttribute('aria-live', 'polite');
  const buttons = el('div', undefined, 'buttons'); buttons.append(run, stop);
  inside.append(buttons, output);
  let controller;
  stop.addEventListener('click', () => controller?.abort());
  if (op['x-implemented'] === false) { run.disabled = true; inside.prepend(el('p', 'not implemented in this build', 'unavailable')); }
  run.addEventListener('click', async () => {
    let timeout;
    try {
      const token = document.getElementById('token').value.trim();
      if (!/^[0-9a-fA-F]{64}$/.test(token)) throw Error('enter a 64-character hex bearer token');
      if (file.files[0]?.size > 8192 && type.value === 'application/octet-stream') throw Error('request bodies are limited to 8192 bytes; upload sounds in chunks');
      const data = type.value === 'application/octet-stream' ? (file.files[0] ? await file.files[0].arrayBuffer() : null) : body.value;
      const values = Object.fromEntries(Object.entries(params).map(([k,v]) => [k,v.value]));
      const request = buildRequest(path, method, op, values, data, type.value);
      request.options.headers.authorization = 'Bearer ' + token;
      controller = new AbortController(); request.options.signal = controller.signal;
      timeout = setTimeout(() => controller.abort(), 10000);
      run.disabled = true; stop.disabled = false;
      output.textContent = request.options.method + ' ' + request.url + '\nwaiting for response…';
      const r = await fetch(request.url, request.options);
      const ct = r.headers.get('content-type') || '';
      output.textContent = r.status + ' ' + r.statusText + '\n' + ct + '\n\n';
      const decoder = new TextDecoder();
      const result = await readBounded(r.body, 65536, part => {
        if (!ct.includes('application/octet-stream')) output.textContent += decoder.decode(part, {stream:true});
      });
      let text;
      if (ct.includes('application/octet-stream')) text = result.bytes.length + ' bytes\n' + [...result.bytes].map(x => x.toString(16).padStart(2,'0')).join(' ');
      else {
        text = new TextDecoder().decode(result.bytes);
        if (ct.includes('json')) { try { text = JSON.stringify(JSON.parse(text), null, 2); } catch {} }
      }
      output.textContent = r.status + ' ' + r.statusText + '\n' + ct + '\n\n' + text + (result.truncated ? '\n\npreview stopped at 64 kib' : '');
    } catch (error) {
      if (error.name === 'AbortError') output.textContent += '\nrequest stopped (manual stop or 10-second limit)';
      else output.textContent = 'request failed: ' + error.message;
    } finally {
      clearTimeout(timeout); controller = null; stop.disabled = true; run.disabled = false;
    }
  });
  card.append(inside);
  return card;
}
async function init() {
  const list = document.getElementById('operations');
  document.getElementById('forget').addEventListener('click', () => { document.getElementById('token').value = ''; });
  try {
    const response = await fetch('/api/openapi.json', {credentials:'omit',redirect:'error'});
    if (!response.ok) throw Error('schema returned ' + response.status);
    const spec = await response.json();
    const groups = new Map();
    for (const [path, item] of Object.entries(spec.paths)) {
      for (const method of ['get','post','put','patch','delete']) {
        if (!item[method]) continue;
        const op = item[method]; const tag = op.tags?.[0] || 'api';
        if (!groups.has(tag)) groups.set(tag, []);
        groups.get(tag).push({path,method,op,params:item.parameters || []});
      }
    }
    let count = 0;
    list.replaceChildren();
    for (const [tag, ops] of groups) {
      const section = el('section'); section.id = 'tag-' + tag.replace(/[^a-z0-9-]/gi,'-');
      section.append(el('h2', tag));
      const link = el('a', tag); link.href = '#' + section.id; document.getElementById('tags').append(link);
      for (const entry of ops) { section.append(operation(entry.path, entry.method, entry.op, entry.params, spec)); count++; }
      list.append(section);
    }
    document.getElementById('count').textContent = count + ' operations · openapi ' + spec.openapi;
    const models = el('section'); models.append(el('h2', 'schemas'));
    for (const [name, schema] of Object.entries(spec.components?.schemas || {})) models.append(schemaView(schema, spec, name));
    list.append(models);
    document.getElementById('filter').addEventListener('input', event => {
      const value = event.target.value.toLowerCase().trim();
      for (const card of list.querySelectorAll('.operation')) card.hidden = !card.textContent.toLowerCase().includes(value);
      for (const section of list.querySelectorAll('section')) if (section.querySelector('.operation')) section.hidden = !section.querySelector('.operation:not([hidden])');
    });
  } catch (error) { list.textContent = 'could not load the api schema: ' + error.message; }
}
if (typeof document !== 'undefined') init();
