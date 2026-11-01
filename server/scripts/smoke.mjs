import assert from 'node:assert/strict';
import { buildApp } from '../dist/app.js';
import { readConfig } from '../dist/config.js';

// This is an intentionally public test fixture, never a deployment credential.
const token = 'smoke-fixture-not-for-deployment-01234567890123456789';
const config = readConfig({APP_ACCESS_TOKEN:token,PROVIDER_MODE:'demo',UPSTREAM_TIMEOUT_MS:'1000'});
const app = await buildApp(config);
let address;
try {
  address = await app.listen({host:'127.0.0.1',port:0});
  assert.equal((await fetch(`${address}/health`)).status,200);
  assert.equal((await fetch(`${address}/v1/realtime/token`,{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).status,401);
  const sourceRef = {articleID:'smoke-article',snapshotID:'smoke-snapshot',blockID:'smoke-block',sentenceID:'smoke-sentence',rangeUTF16:{location:0,length:21}};
  const request = {requestID:'smoke-request',runID:'smoke-run',stateRevision:0,task:'explain',learnerTurn:'意味を説明して。',context:{
    title:'Original smoke sample',focus:sourceRef,passages:[{sourceRef,blockText:'A review can be useful.',text:'A review can be useful.'}],
    explanationSeen:false,hintSeen:false,inputModality:'text',presentation:'reading',
  }};
  request.context.passages[0].sourceRef.rangeUTF16.length = request.context.passages[0].text.length;
  const response = await fetch(`${address}/v1/tutor/turn`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${token}`},body:JSON.stringify(request)});
  assert.equal(response.status,200);
  const reply = await response.json();
  assert.match(reply.feedbackJa,/Demo/);
  assert.equal(reply.assessment,null);
  assert.equal(reply.stateRevision,0);
  console.info('HTTP smoke passed: health 200, unauthorized token 401, authenticated Demo tutor 200.');
} finally {await app.close();}

let sawAbort = false;
let began;
const started = new Promise(resolve => {began=resolve;});
const cancellable = await buildApp({...config,PROVIDER_MODE:'live'}, {provider:{
  token:async () => {throw new Error('Not used');},
  practice:async () => {throw new Error('Not used');},
  tutor:(_request,signal) => new Promise((_resolve,reject) => {
    began(); signal.addEventListener('abort',() => {sawAbort=true;reject(new Error('Cancelled'));},{once:true});
  }),
}});
try {
  address = await cancellable.listen({host:'127.0.0.1',port:0});
  const ref = {articleID:'a',snapshotID:'s',blockID:'b'};
  const controller = new AbortController();
  const pending = fetch(`${address}/v1/tutor/turn`,{method:'POST',signal:controller.signal,
    headers:{'Content-Type':'application/json',Authorization:`Bearer ${token}`},
    body:JSON.stringify({requestID:'cancel-request',runID:'run',stateRevision:0,task:'explain',learnerTurn:'Explain.',context:{
      title:'Fixture',focus:ref,passages:[{sourceRef:ref,blockText:'Test.',text:'Test.'}],
      explanationSeen:false,hintSeen:false,inputModality:'text',presentation:'reading',
    }}),
  }).catch(() => {});
  await started; controller.abort(); await pending;
  const until = Date.now()+500;
  while (!sawAbort && Date.now()<until) await new Promise(resolve => setTimeout(resolve,10));
  assert.equal(sawAbort,true,'Client cancellation must abort the upstream request.');
  console.info('HTTP cancellation smoke passed: device disconnect aborted upstream work.');
} finally {await cancellable.close();}
