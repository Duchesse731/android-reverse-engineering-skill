import test from 'node:test';
import assert from 'node:assert/strict';
import worker from '../dist/server/index.js';
test('Unconfigured gateway disables analysis truthfully',async()=>{
  const response=await worker.fetch(new Request('https://example.com/api/health'),{});
  assert.deepEqual((await response.json()).ready,false);
  const upload=await worker.fetch(new Request('https://example.com/api/jobs',{method:'POST'}),{});
  assert.equal(upload.status,503);
});
test('Interface serves the requested name',async()=>{
  const response=await worker.fetch(new Request('https://example.com/'),{});
  assert.match(await response.text(),/<title>The Break Down<\/title>/);
});
test('Gateway rejects traversal and oversized uploads',async()=>{
  const env={ENGINE_URL:'https://private.example',ENGINE_TOKEN:'secret'};
  assert.equal((await worker.fetch(new Request('https://example.com/api/jobs/not-a-job/download'),env)).status,404);
  assert.equal((await worker.fetch(new Request('https://example.com/api/jobs',{method:'POST',headers:{'x-upload-size':'999999999'}}),env)).status,413);
});
test('Private token is sent only to configured server',async()=>{
  const previous=globalThis.fetch;
  let captured;
  globalThis.fetch=async(url,options)=>{captured={url,options};return Response.json({connected:true,ready:true});};
  try{
    const response=await worker.fetch(new Request('https://example.com/api/health'),{ENGINE_URL:'https://private.example',ENGINE_TOKEN:'never-browser'});
    assert.equal(captured.options.headers.get('Authorization'),'Bearer never-browser');
    assert.equal(captured.url,'https://private.example/api/health');
    assert.equal(response.headers.get('Authorization'),null);
    assert.equal((await response.json()).ready,true);
  }finally{globalThis.fetch=previous;}
});
