// Chrome/CDP acceptance test against the local, mocked Flutter fixture only.
// Build: flutter build web --no-web-resources-cdn --target=test/support/manual_delivery_confirmation_browser.dart --output=/tmp/jm-manual-notification-preview
// Serve that directory on 127.0.0.1:8767; launch a separate Chrome profile with
// --remote-debugging-port=9227, then run this file with Node 22+.
import fs from 'node:fs';
import assert from 'node:assert/strict';
const target=(await (await fetch('http://127.0.0.1:9227/json/list')).json()).find(x=>x.type==='page');
const ws=new WebSocket(target.webSocketDebuggerUrl);await new Promise(r=>ws.onopen=r);
let id=0;const pending=new Map(),exceptions=[],requests=[];
ws.onmessage=({data})=>{const m=JSON.parse(data);if(m.id){const p=pending.get(m.id);pending.delete(m.id);if(m.error)p.reject(m.error);else p.resolve(m.result);}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params);else if(m.method==='Network.requestWillBeSent')requests.push(m.params.request.url);};
function call(method,params={}){return new Promise((resolve,reject)=>{const key=++id;pending.set(key,{resolve,reject});ws.send(JSON.stringify({id:key,method,params}));})}
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const evaluate=async(expression)=>(await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true})).result.value;
const body=()=>evaluate("document.body.innerText + '\\n' + [...document.querySelectorAll('textarea,input')].map(e=>e.value+' '+(e.getAttribute('aria-label')||'')).join('\\n')");
await call('Page.enable');await call('Runtime.enable');await call('Network.enable');
await call('Network.setBlockedURLs',{urls:['*cloudfunctions.net*','*firestore.googleapis.com*','*identitytoolkit.googleapis.com*','*run.app*']});
async function click(text){
 return clickSelector(`[...document.querySelectorAll('[role="button"]')].find(e=>(e.innerText||e.getAttribute('aria-label')||'').trim()===${JSON.stringify(text)})`);
}
async function clickSelector(find){
 assert(await evaluate(`!!(${find})`),'control missing: '+find);
 await evaluate(`(${find}).scrollIntoView({block:'center'})`);await pause(250);
 const r=await evaluate(`(()=>{const r=(${find}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2};})()`);
 await call('Input.dispatchMouseEvent',{type:'mousePressed',...r,button:'left',clickCount:1});await call('Input.dispatchMouseEvent',{type:'mouseReleased',...r,button:'left',clickCount:1});await pause(400);
}

async function navigate(mode='pending') {
 await call('Page.navigate',{url:'http://127.0.0.1:8767/?mode='+mode});
 for(let i=0;i<60 && !(await body()).includes('事務局へ送信結果を通知');i++)await pause(200);
 await pause(600);await click('事務局へ送信結果を通知');await pause(500);
}
for(const width of [1280,390]) {
 await call('Emulation.setDeviceMetricsOverride',{width,height:1000,deviceScaleFactor:1,mobile:false,screenWidth:width,screenHeight:1000});
 await navigate();let text=await body();
 for(let i=0;i<5;i++){await call('Input.dispatchMouseEvent',{type:'mouseWheel',x:width/2,y:350,deltaY:250,deltaX:0});await pause(200);text+=' '+await body();}
 for(const email of ['inoue-y6@asahi.com','sippo-support@info-event-jimukyoku.jp','ijuinjun@gmail.com','jm.okubo@gmail.com','hakamatajm@gmail.com'])assert(text.includes(email));
 assert(text.includes('対象 10件 / 成功 8件'));assert(text.includes('件名：事務局用の送信結果'));assert(text.includes('送信結果の本文'));
 const shot=await call('Page.captureScreenshot',{format:'png'});fs.writeFileSync(`/tmp/jm-manual-${width}-preview.png`,Buffer.from(shot.data,'base64'));
 await click('送信する');let done=await body();for(let i=0;i<5;i++){await call('Input.dispatchMouseEvent',{type:'mouseWheel',x:width/2,y:350,deltaY:-250,deltaX:0});await pause(200);done+=' '+await body();}assert(done.includes('通知済み / 試行'));
 await navigate('mixed');assert((await body()).includes('結果不明（再送禁止）'));
 await click('この宛先へ再送する');assert(!(await body()).includes('この宛先へ再送する'));
 await navigate('denied');assert((await body()).includes('この操作を行う権限がありません'));
 await navigate('lost');await click('送信する');assert((await body()).includes('時間をおいて'));
 console.log('PASS browser',width,'preview 5 recipients, subject/body/counts, send result, retry, unknown/permission/lost-response protection');
}
assert.deepEqual(exceptions,[]);assert.deepEqual(requests.filter(u=>/cloudfunctions|firestore|run\.app/.test(u)),[]);
console.log('PASS no production network requests or browser exceptions');ws.close();
