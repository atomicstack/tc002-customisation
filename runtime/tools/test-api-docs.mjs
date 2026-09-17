import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
const source = await readFile(new URL('../src/net/docs/app.js', import.meta.url), 'utf8');
const { buildRequest, exampleFor, readBounded } = await import('data:text/javascript;base64,' + Buffer.from(source + '\n//# sourceURL=api-docs-app.js').toString('base64'));

test('request paths and queries are encoded and remain on the current api', () => {
  const op = {parameters: [{in:'path',name:'name',required:true},{in:'query',name:'after'}]};
  const r = buildRequest('/berry/scripts/{name}', 'get', op, {name:'morning',after:'a&b'}, '', '');
  assert.equal(r.url, '/api/v1/berry/scripts/morning?after=a%26b');
  assert.equal(r.options.method, 'GET');
  assert.equal(r.options.redirect, 'error');
  assert.equal(r.options.credentials, 'omit');
  for (const name of ['', '..', 'x/y', 'x\\y', '%2f']) {
    assert.throws(() => buildRequest('/berry/scripts/{name}', 'get', op, {name}, '', ''));
  }
});
test('json requests validate syntax and byte size before sending', () => {
  const op = {requestBody:{required:true,content:{'application/json':{schema:{type:'object'}}}}};
  const r = buildRequest('/notify','post',op,{},'{"text":"hello"}','application/json');
  assert.equal(r.options.body,'{"text":"hello"}');
  assert.equal(r.options.headers['content-type'],'application/json');
  assert.throws(() => buildRequest('/notify','post',op,{},'oops','application/json'));
  assert.throws(() => buildRequest('/notify','post',op,{},'','application/json'));
  assert.throws(() => buildRequest('/notify','post',op,{},JSON.stringify({text:'é'.repeat(5000)}),'application/json'));
});
test('request samples resolve references and do not invent optional fields', () => {
  const spec={components:{schemas:{N:{type:'object',required:['text'],properties:{text:{type:'string',examples:['hello']},optional:{type:'integer'}}}}}};
  assert.deepEqual(exampleFor({$ref:'#/components/schemas/N'},spec),{text:'hello'});
  assert.equal(exampleFor({type:'integer',minimum:1},spec),1);
});
test('response previews stay bounded even for a never-ending stream', async () => {
  let cancelled=false;
  const stream=new ReadableStream({pull(c){c.enqueue(new Uint8Array([1,2,3,4]));},cancel(){cancelled=true;}});
  const r=await readBounded(stream,7);
  assert.deepEqual([...r.bytes],[1,2,3,4,1,2,3]);
  assert.equal(r.truncated,true);
  assert.equal(cancelled,true);
});
test('live responses deliver partial text before the stream ends', async () => {
  const chunks=[];
  const s=new ReadableStream({start(c){c.enqueue(new TextEncoder().encode('data: hi\n\n'));c.close();}});
  await readBounded(s,64,part => chunks.push(new TextDecoder().decode(part)));
  assert.deepEqual(chunks,['data: hi\n\n']);
});
test('optional empty json bodies still carry the selected content type', () => {
  const op={requestBody:{required:false,content:{'application/json':{}}}};
  const request=buildRequest('/config/save','post',op,{},'','application/json');
  assert.equal(request.options.headers['content-type'],'application/json');
  assert.equal(request.options.body,undefined);
});
test('resource names allow internal consecutive dots but never traversal segments', () => {
  const request=buildRequest('/berry/scripts/{name}','get',{}, {name:'rules..door'},'', '');
  assert.equal(request.url,'/api/v1/berry/scripts/rules..door');
  assert.throws(()=>buildRequest('/../config','get',{}, {},'', ''));
});
