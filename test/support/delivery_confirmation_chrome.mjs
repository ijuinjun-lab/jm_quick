// Chrome/CDP acceptance test against the local, mocked Flutter fixture only.
// Build: flutter build web --no-web-resources-cdn --target=test/support/delivery_confirmation_browser.dart --output=/tmp/jm-phase3-preview
// Serve that directory on 127.0.0.1:8765; launch a separate Chrome profile with
// --remote-debugging-port=9223, then run this file with Node 22+.
import fs from 'node:fs';
import assert from 'node:assert/strict';
const target=(await (await fetch('http://127.0.0.1:9223/json/list')).json()).find(x=>x.type==='page');
const ws=new WebSocket(target.webSocketDebuggerUrl);await new Promise(r=>ws.onopen=r);
let id=0;const pending=new Map(),exceptions=[],requests=[];
ws.onmessage=({data})=>{const m=JSON.parse(data);if(m.id){const p=pending.get(m.id);pending.delete(m.id);if(m.error)p.reject(m.error);else p.resolve(m.result);}else if(m.method==='Runtime.exceptionThrown')exceptions.push(m.params);else if(m.method==='Network.requestWillBeSent')requests.push(m.params.request.url);};
function call(method,params={}){return new Promise((resolve,reject)=>{const key=++id;pending.set(key,{resolve,reject});ws.send(JSON.stringify({id:key,method,params}));})}
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const evaluate=async(expression)=>(await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true})).result.value;
const body=()=>evaluate('document.body.innerText');
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
async function fillEmail(value){
 await clickSelector(`[...document.querySelectorAll('input[aria-label="確認先メールアドレス"]')].at(-1)`);
 await call('Input.dispatchKeyEvent',{type:'keyDown',key:'a',code:'KeyA',modifiers:4,commands:['selectAll']});
 await call('Input.dispatchKeyEvent',{type:'keyUp',key:'a',code:'KeyA',modifiers:4});
 await call('Input.insertText',{text:value});await pause(200);
}
async function save(){await click('確認先設定を保存');await click('確認して実行');}
async function navigate(query=''){
 await call('Page.navigate',{url:'http://127.0.0.1:8765/'+query});
 for(let i=0;i<50 && !(await body()).includes('確認履歴 45');i++)await pause(200);
 await pause(1200);
}
async function shot(path){const r=await call('Page.captureScreenshot',{format:'png'});fs.writeFileSync(path,Buffer.from(r.data,'base64'));}
for(const width of [1280,390]){
 await call('Emulation.setDeviceMetricsOverride',{width,height:900,deviceScaleFactor:1,mobile:false,screenWidth:width,screenHeight:900});
 await call('Page.navigate',{url:'http://127.0.0.1:8765/'});
 for(let i=0;i<50 && !(await body()).includes('確認履歴 45');i++)await pause(200);
 await pause(1500);assert.equal(await evaluate('innerWidth'),width);
 await shot(`/tmp/jm-phase3-${width}-initial.png`);
 await click('確認先を削除');assert((await body()).includes('過去の送信履歴は保持'));await shot(`/tmp/jm-phase3-${width}-dialog.png`);
 await click('戻る');assert.equal(((await body()).match(/確認先を削除/g)||[]).length,2);
 await click('確認先を削除');await click('確認して実行');assert.equal(((await body()).match(/確認先を削除/g)||[]).length,1);
 await click('確認先設定を保存');await click('確認して実行');assert.equal(((await body()).match(/確認先を削除/g)||[]).length,1);assert((await body()).includes('確認履歴 45'));
 await click('履歴をさらに表示');assert((await body()).includes('確認履歴 6'));
 await click('履歴をさらに表示');const text=await body();assert(text.includes('確認履歴 1'));assert(!text.includes('履歴をさらに表示'));
 const history=[...text.matchAll(/確認履歴 (\d+)/g)].map(m=>Number(m[1]));assert.deepEqual(history,Array.from({length:45},(_,i)=>45-i));
 await click('確認先を追加（最大10件）');
 await fillEmail('invalid');await save();assert((await body()).includes('メールアドレスの形式が正しくありません'));
 await fillEmail('organizer@example.invalid');await save();assert((await body()).includes('同じメールアドレスが重複しています'));
 await shot(`/tmp/jm-phase3-${width}-duplicate.png`);
 await fillEmail('office@example.invalid');
 for(const label of ['通常当選','繰り上げ当選','一斉メール'])await clickSelector(`[...document.querySelectorAll('[role="checkbox"][aria-label="${label}"]')].at(-1)`);
 await save();assert((await body()).includes('対象メール種別を1つ以上'));
 await clickSelector(`[...document.querySelectorAll('[role="checkbox"][aria-label="通常当選"]')].at(-1)`);
 await save();assert.equal(((await body()).match(/確認先を削除/g)||[]).length,2);
 await clickSelector(`[...document.querySelectorAll('[role="button"]')].find(e=>(e.innerText||'').includes('確認履歴 45'))`);
 assert((await body()).includes('office / office@example.invalid 送信済み'));
 await navigate('?error=permission');await save();assert((await body()).includes('この操作を行う権限がありません'));
 await shot(`/tmp/jm-phase3-${width}-permission.png`);
 await navigate('?error=internal');await save();assert((await body()).includes('時間をおいて'));assert(!(await body()).includes('sensitive'));
 await navigate('?role=manager');assert(!(await body()).includes('確認先を削除'));assert(!(await body()).includes('確認先設定を保存'));
 await shot(`/tmp/jm-phase3-${width}-manager.png`);
 console.log('PASS',width,'delete cancel/save/reregister; 45 descending reports; all four errors + internal-error masking; manager deletion hidden');
}
assert.deepEqual(exceptions,[]);assert.deepEqual(requests.filter(u=>/cloudfunctions|firestore|run\.app/.test(u)),[]);console.log('PASS no browser exceptions or production API requests');ws.close();
