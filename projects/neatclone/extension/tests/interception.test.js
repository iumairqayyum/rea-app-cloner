import test from 'node:test';
import assert from 'node:assert/strict';
import {cleanSettings, DEFAULT_SETTINGS, dispositionFilename, eligibleDownload} from '../interception.js';
import {createController} from '../background.js';

const config = cleanSettings({...DEFAULT_SETTINGS, interceptionSites: ['https://page.test/*']});
const item = {id: 9, state: 'in_progress', paused: false, url: 'https://page.test/archive.ZiP', finalUrl: 'https://page.test/archive.ZiP', filename: 'archive.ZiP', mime: 'application/zip', totalBytes: 2 * 1024 * 1024, referrer: 'https://page.test/downloads'};
test('filter settings normalize case, clamp size and reject wildcard consent', () => {
  assert.deepEqual(cleanSettings({extensions: ['.zip','ZIP','mP4','../bad'], minimumMB: -2, interceptionSites: ['https://page.test/*','https://*.test/*','*://*/*'] }), {extensions: ['ZIP','MP4'], minimumMB: 0, interceptionSites: ['https://page.test/*']});
  assert.equal(cleanSettings().minimumMB, 1);
});
test('known size and corroborated MIME/attachment required; HTML cannot masquerade as ZIP', () => {
  assert.equal(eligibleDownload(item, undefined, config).filename, 'archive.ZiP');
  for (const changed of [{totalBytes: -1}, {totalBytes: 500}, {mime: 'text/html'}, {referrer: ''}, {finalUrl:'file:///tmp/private'}, {filename: 'part.ts'}]) assert.equal(eligibleDownload({...item,...changed}, undefined, config), null);
  assert.equal(eligibleDownload({...item,mime:'application/octet-stream'}, undefined, config), null);
  assert.equal(eligibleDownload(item, {size: item.totalBytes,type:'application/octet-stream',disposition:'attachment; filename="download.zip"'}, config).filename, 'download.zip');
  assert.equal(eligibleDownload(item, {size:item.totalBytes,type:'video/mp4',disposition:'attachment; filename="download.mp4"'}, config), null);
});
test('Content-Disposition RFC5987 is bounded and cannot introduce paths/control characters', () => {
  assert.equal(dispositionFilename("attachment; filename*=UTF-8''demo%20file.zip"), 'demo file.zip');
  assert.equal(dispositionFilename("attachment; filename*=UTF-8'en'demo%20file.zip"), 'demo file.zip');
  for (const raw of ['inline; filename="a.zip"', 'attachment; filename="../a.zip"', "attachment; filename*=UTF-8''a%0d%0a.zip", "attachment; filename*=UTF-8''bad%zz"]) assert.throws(() => dispositionFilename(raw));
});
function mock({ack=true, pauseFails=false, state='in_progress'}={}) {
  const events=[], saved={settings: config};
  const api={
    permissions:{contains: async ({origins}) => origins.every(x => x==='https://page.test/*')},
    storage:{local:{get:async()=>saved,set:async x=>Object.assign(saved,x)}},
    downloads:{pause:async id=>{events.push('pause');if(pauseFails)throw Error('finished');},search:async()=>[{...item,state,paused:true}],cancel:async()=>events.push('cancel'),resume:async()=>events.push('resume')},
    runtime:{id:'own',getURL:p=>'chrome-extension://own/'+p,sendNativeMessage:async(host,message)=>{events.push('native');assert.equal(host,'com.neatclone.bridge');assert.equal(message.version,1);return ack?{ok:true,id:'receipt'}:{ok:false};}},
    tabs:{get:async()=>({id:7,url:'https://page.test/watch'})},
    scripting:{executeScript:async()=>[{result:[{url:'https://page.test/v.mp4',group:'element:0',quality:'720'}]}]},
  };
  return {controller:createController(api),events,api,saved};
}
test('interception pauses first and cancels only after durable native acknowledgement', async()=>{
  const m=mock();assert.equal(await m.controller.intercept(item),true);assert.deepEqual(m.events,['pause','native','cancel']);
});
test('failed or raced interception never cancels browser transfer; paused download resumes',async()=>{
  const failed=mock({ack:false});assert.equal(await failed.controller.intercept(item),false);assert.deepEqual(failed.events,['pause','native','resume']);
  const raced=mock({state:'complete'});assert.equal(await raced.controller.intercept(item),false);assert.deepEqual(raced.events,['pause','resume']);
  const pause=mock({pauseFails:true});assert.equal(await pause.controller.intercept(item),false);assert.deepEqual(pause.events,['pause']);
});
test('interception is disabled without explicit approved source site and target permission',async()=>{
  const m=mock();m.saved.settings={...config,interceptionSites:[]};assert.equal(await m.controller.intercept(item),false);assert.deepEqual(m.events,[]);
  m.saved.settings=config;assert.equal(await m.controller.intercept({...item,finalUrl:'https://other.test/archive.zip'}),false);assert.deepEqual(m.events,[]);
});
test('context-menu handoff permits explicit authorized link but never TS or credential transfer',async()=>{
  const m=mock();assert.equal(await m.controller.contextDownload({linkUrl:'https://page.test/archive.zip',pageUrl:'https://page.test/downloads'},{}),true);assert.deepEqual(m.events,['native']);
  assert.equal(await m.controller.contextDownload({linkUrl:'https://page.test/segment.ts',pageUrl:'https://page.test/downloads'},{}),false);
});
test('floating requests must be own main-frame approved content script and cached candidate',async()=>{
  const m=mock(), popup={id:'own',url:'chrome-extension://own/popup.html'};
  const scan=await m.controller.handle({action:'scan',tabID:7},popup);
  const msg={action:'floatingSend',candidateID:scan.candidates[0].id};
  assert.equal((await m.controller.handle(msg,{id:'own',frameId:0,tab:{id:7},url:'https://page.test/watch'})).ok,true);
  assert.equal((await m.controller.handle(msg,{id:'own',frameId:1,tab:{id:7},url:'https://page.test/watch'})).ok,false);
  assert.equal((await m.controller.handle({...msg,candidateID:'forged'},{id:'own',frameId:0,tab:{id:7},url:'https://page.test/watch'})).ok,false);
});

test('settings mutations stay popup-only and cannot smuggle new interception origins',async()=>{
  const m=mock();
  const denied=await m.controller.handle({action:'saveSettings',extensions:['ISO'],minimumMB:0},{id:'other',url:'chrome-extension://own/popup.html'});
  assert.equal(denied.ok,false);
  const result=await m.controller.handle({action:'saveSettings',extensions:['iSo'],minimumMB:2,interceptionSites:['https://other.test/*']},{id:'own',url:'chrome-extension://own/popup.html'});
  assert.equal(result.ok,true);assert.deepEqual(result.settings.extensions,['ISO']);assert.deepEqual(result.settings.interceptionSites,config.interceptionSites);
});
test('unknown length and mismatched response size never trigger interception',async()=>{
  assert.equal(eligibleDownload({...item,totalBytes:-1},{size:2e6,type:'application/zip'},config),null);
  assert.equal(eligibleDownload(item,{size:item.totalBytes+1,type:'application/zip'},config),null);
});
