// The actual ArkTS queue/input owner with only its N-API boundary substituted.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.argv[2]);
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/model/terminal/NativeTerminalController.ets'), 'utf8');
const keyMapExports = {};
const scrollExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/model/terminal/TerminalScrollPolicy.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, { exports: scrollExports });
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/common/constants/KeyCodeMap.ets'), 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, { exports: keyMapExports });
function clipboardFixture() {
  const state = { grant: 0, checks: 0, requests: 0, settingsRequests: 0, reads: 0, writes: 0, text: 'public-text',
    request: async () => ({ authResults: [0] }), settingsRequest: async () => [0] };
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,
    '../entry/src/main/ets/model/clipboard/ClipboardManager.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => name === '@kit.AbilityKit' ? {
    abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0, PERMISSION_DENIED: -1 }, createAtManager: () => ({
      checkAccessTokenSync(token, permission) {
        assert.equal(token, 42); assert.equal(permission, 'ohos.permission.READ_PASTEBOARD');
        state.checks++; return state.grant;
      },
      requestPermissionsFromUser(context, permissions) {
        assert.equal(context.applicationInfo.accessTokenId, 42);
        assert.deepEqual(Array.from(permissions), ['ohos.permission.READ_PASTEBOARD']);
        state.requests++; return state.request();
      },
      requestPermissionOnSetting(context, permissions) {
        assert.equal(context.applicationInfo.accessTokenId, 42);
        assert.deepEqual(Array.from(permissions), ['ohos.permission.READ_PASTEBOARD']);
        state.settingsRequests++; return state.settingsRequest();
      }
    }) }
  } : name === '@kit.BasicServicesKit' ? { pasteboard: {
    getSystemPasteboard: () => ({ getData: async () => { state.reads++; if (state.readError) throw Error('read');
      return { getPrimaryText: () => state.text }; }, setData: async () => { state.writes++; } }),
    createData: () => ({ getProperty: () => ({}), setProperty() {} }), ShareOption: { LOCALDEVICE: 0 }
  } } : { Logger: class { warn() {} error() {} } } });
  return { clipboard: exports.ClipboardManager, state };
}
function fixture(acceptanceEnabled = true, clipboardState = clipboardFixture()) {
  let callback, next = 1, capacity = 1024 * 1024, occupied = 0;
  const accepted = [], attachments = [], timers = new Map(), logs = [];
  const { clipboard, state } = clipboardState;
  const api = {
    create(_a, _b, cb) { callback = cb; return {}; },
    write(_h, bytes, owner) {
      if (occupied + bytes.byteLength > capacity) return 0;
      const seq = next++;
      occupied += bytes.byteLength;
      accepted.push({ seq, kind: 'write', bytes: new Uint8Array(bytes).slice(), owner });
      return seq;
    },
    barrier() { const seq = next++; accepted.push({ seq, kind: 'barrier' }); return seq; },
    positionSessionOutput() { const seq = next++; accepted.push({ seq, kind: 'position' }); return seq; },
    page(_h, begin) { const seq = next++; accepted.push({ seq, kind: begin ? 'begin' : 'end' }); return seq; },
    attach(_h,id,width,height,font,generation,inset,stroke) { const seq=next++; attachments.push({seq,id,width,height,font,generation,inset,stroke}); return seq; }, detach() { return next++; },
    key(_h,code,mods,owner,text,unshiftedCodepoint) { const seq=next++; accepted.push({seq,kind:'key',code,mods,owner,text,unshiftedCodepoint}); return seq; },
    blur() {}, ime() {}, async close() {},
    copy(_h,action,owner,revision) { const seq = next++; accepted.push({ seq, kind: 'copy', action, owner, revision }); return seq; },
    paste(_h,text,owner) { const seq = next++; accepted.push({ seq, kind: 'paste', text, owner }); return seq; },
    pointer(_h,action,button,x,y,mods,owner) { const seq = next++; accepted.push({ seq, kind: 'pointer', action, owner }); return seq; },
    scroll() { return next++; },
    search(_h,text,direction,owner) {
      if (occupied + new TextEncoder().encode(text).byteLength > capacity) return 0;
      const seq=next++; accepted.push({seq,kind:'search',text,direction,owner}); return seq;
    }, cursor() {},
    hover(_h,mods,owner) { const seq=next++; accepted.push({seq,kind:'hover',mods,owner}); return seq; },
    focus() { return next++; },
    visibility(_h,visible,generation) { const seq=next++; accepted.push({seq,kind:'visibility',visible,generation}); return seq; },
  };
  const exports = {};
  const result = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: 'NativeTerminalController.ts'
  });
  vm.runInNewContext(result.outputText, { exports, require: name => name.includes('ClipboardManager') ? { ClipboardManager: clipboard } :
    name.includes('KeyCodeMap') ? keyMapExports :
    name.includes('TerminalScrollPolicy') ? scrollExports :
    name.includes('/Logger') ? { Logger: class { info(text) { logs.push(text); } } } :
    name.includes('LocalCommandOutput') ? { LocalCommandOutput: { prompt: () => '\x1b[32mltty>\x1b[0m ' } } :
    name === 'BuildProfile' ? { ACCEPTANCE_TESTS: acceptanceEnabled } :
    name === '@ohos.util' ? { default: { TextEncoder: class { encodeInto(text) { return text.length === 0 ? undefined : new TextEncoder().encode(text); } },
      TextDecoder: { create() { const decoder=new TextDecoder(); return {decodeToString:(data,options)=>decoder.decode(data,options)}; } } } } : { default: api }, Uint8Array, ArrayBuffer, Date,
    AxisAction: { NONE:0, BEGIN:1, UPDATE:2, END:3, CANCEL:4 },
    setInterval: fn => { const id = next++; timers.set(id, fn); return id; }, clearInterval: id => timers.delete(id) });
  const control = new exports.NativeTerminalController(new ArrayBuffer(1), new ArrayBuffer(1));
  const events = [];
  control.onPressure = x => events.push(['pressure', x]);
  control.onInput = x => events.push(['input', x]);
  control.onReply = (x, owner) => events.push(['reply', x, owner]);
  control.onReady = x => events.push(['ready', x]);
  control.onFailure = () => events.push(['failure']);
  const emit = (kind, seq = 0, owner = 0, text = '') => callback(kind, seq, owner, text);
  function consume(item) { occupied -= item.bytes?.byteLength || 0; emit('consumed', item.seq); }
  return { control, accepted, attachments, events, emit, consume, timers, clipboard, state, logs, api };
}
let count = 0;
function test(name, fn) { fn(); console.log('PASS ' + name); count++; }
test('touchpad gain is bounded, slow precision and wheel steps remain stable', () => {
  const Policy = scrollExports.TerminalScrollPolicy;
  const run = (delta,gap,touchpad) => { const p=new Policy(); let total=0;
    for(let i=0;i<20;i++) total+=p.consume(delta,i*gap,touchpad); return total; };
  assert.equal(run(4,20,true),2,'slow movement accumulates fractional rows without gain');
  assert.ok(run(40,16,true)>run(40,100,true),'equal distance scrolls further at higher speed');
  assert.equal(run(120,16,false),60); assert.equal(run(120,100,false),60,'mouse has no velocity gain');
  const p=new Policy();
  p.consume(30,0,false); assert.equal(p.consume(-40,16,false),-1,'reverse does not repay old remainder');
  p.reset(); p.consume(30,0,false); assert.equal(p.consume(10,200,false),0,'pause discards old remainder');
  p.reset(); p.consume(30,0,false); assert.equal(p.consume(10,16,true),0,'source change starts fresh');
  assert.equal(p.consume(1e6,32,true),256,'single event is bounded without delayed catch-up');
  assert.equal(p.consume(0,48,true),0);
  assert.equal(p.consume(NaN,64,true),0); assert.equal(p.consume(40,80,false),1);
});
test('axis lifecycle and input-owner changes discard pending gesture state', () => {
  const f=fixture(), c=f.control; c.presented=true;
  const scrolls=[]; c.scroll=lines=>scrolls.push(lines);
  for(const action of [3,4]) {
    c.scrollAxis(30,0,false,1); c.scrollAxis(0,16,false,action);
    c.scrollAxis(10,32,false,2); assert.equal(scrolls.length,0);
  }
  c.scrollAxis(30,40,false,1); c.invalidateInput();
  c.scrollAxis(10,56,false,2); assert.equal(scrolls.length,0);
  c.scrollAxis(40,72,false,2); assert.deepEqual(scrolls,[1]);
  c.searching=true; c.scrollAxis(120,88,true,2); assert.deepEqual(scrolls,[1]);
});
test('native keys preserve shifted text and pass the existing unshifted mapping', () => {
  const f=fixture(), c=f.control;
  c.focused=true; c.presented=true;
  c.key(2018,3,'B'); c.key(2001,3,'!'); c.key(2012,0,'');
  assert.deepEqual(f.accepted.filter(x=>x.kind==='key').map(x=>[x.text,x.unshiftedCodepoint]),
    [['B',98],['!',49],['',0]]);
});
test('session anchor waits behind backpressured reset and completes before local output', () => {
  const f=fixture(), c=f.control, completed=[];
  c.write(new Uint8Array(1024*1024),7);
  c.write(new TextEncoder().encode('reset'),0);
  c.positionSessionOutput(() => {
    completed.push('position'); c.write(new TextEncoder().encode('local'),0);
    c.barrier(() => completed.push('done'));
  });
  assert.equal(f.accepted.some(x=>x.kind==='position'),false);
  f.consume(f.accepted[0]);
  const reset=f.accepted[4], anchor=f.accepted[5];
  assert.equal(new TextDecoder().decode(reset.bytes),'reset');
  assert.equal(anchor.kind,'position'); assert.deepEqual(completed,[]);
  f.consume(anchor);
  assert.equal(new TextDecoder().decode(f.accepted[6].bytes),'local');
  assert.deepEqual(completed,['position']);
  f.consume(f.accepted[7]); assert.deepEqual(completed,['position','done']);
});
test('hover preview rejects queued leave, old input owners and search focus', () => {
  const f=fixture(), c=f.control, seen=[];
  c.attach('1',900,600,{vp2px:x=>2*x}); c.focus(); f.emit('presented',0,c.displayGeneration);
  c.onLinkHover=url=>seen.push(url);
  c.hover(2); const active=f.accepted.at(-1);
  f.emit('link-hover',active.seq,c.inputOwner,'https://example.com');
  assert.equal(seen.at(-1),'https://example.com');
  c.hover(-1); f.emit('link-hover',active.seq,c.inputOwner,'stale'); assert.equal(seen.at(-1),'');
  const old=c.inputOwner;
  c.blur(); f.emit('link-hover',999,old,'stale-owner'); assert.equal(seen.at(-1),'');
  c.focus(); c.openSearch(); f.emit('link-hover',999,c.inputOwner,'search'); assert.equal(seen.at(-1),'');
});
test('native attachment scales the shared eight-vp inset with actual screen density', () => {
  const f=fixture(); f.control.attach('1',900,600,{vp2px:x=>1.625*x});
  const attached=f.attachments[0];
  assert.equal(attached.inset,13); assert.equal(attached.font,23);
  assert.equal(attached.stroke,2,'one-vp cursor stroke uses display density');
});
test('maximum user font sizes retain physical scaling above two pixels per vp', () => {
  for (const density of [1, 1.9, 2.2125, 3, 4]) {
    const f = fixture();
    f.control.attach('1', 2800, 1800, {vp2px:x=>x*density});
    let previous = 0;
    for (let size = 44; size <= 48; ++size) {
      f.control.setFontSize(size);
      const font = f.attachments.at(-1).font;
      assert.equal(font, Math.round(size*density));
      assert.ok(font > previous, 'each user step changes actual font size');
      previous = font;
    }
  }
});
test('measured cells reject stale font, density, Surface and unavailable owners', () => {
  const f=fixture(), c=f.control, context={vp2px:x=>1.625*x};
  c.attach('1',900,600,context);
  const emit=(text,owner=c.displayGeneration)=>f.emit('metrics',0,owner,text);
  assert.equal(c.getCellMetrics(23,13),null);
  emit('23,13,14,27');
  assert.equal(c.getCellMetrics(23,13).cellWidth,14);
  assert.equal(c.getCellMetrics(28,16),null,'window density must match');
  c.attach('1',1000,700,context);
  assert.equal(c.getCellMetrics(23,13).cellHeight,27,'resize can use same font metrics while worker catches up');
  c.setFontSize(15); assert.equal(c.getCellMetrics(23,13),null);
  emit('23,13,14,27'); assert.equal(c.getCellMetrics(24,13),null);
  emit('24,13,15,28'); assert.equal(c.getCellMetrics(24,13).cellWidth,15);
  c.attach('2',1000,700,context); assert.equal(c.getCellMetrics(24,13),null);
  emit('24,13,15,28',c.displayGeneration-1); assert.equal(c.getCellMetrics(24,13),null);
  for(const invalid of ['24,13,0,28','24,13,NaN,28','24,13,15.5,28','24,13,15']) {
    emit(invalid); assert.equal(c.getCellMetrics(24,13),null);
  }
  emit('24,13,15,28'); c.setVisible(false); assert.equal(c.getCellMetrics(24,13),null);
  c.setVisible(true); f.emit('surface-unavailable',0,c.displayGeneration);
  assert.equal(c.getCellMetrics(24,13),null);
  c.detach(); emit('24,13,15,28'); assert.equal(c.getCellMetrics(24,13),null);
});
test('window snap uses measured pixel lattice and keeps the opposite dragged edges fixed', () => {
  const exports={};
  const policySource=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/model/ui/WindowGridSnapPolicy.ets'),'utf8');
  vm.runInNewContext(ts.transpileModule(policySource,{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,{exports});
  const policy=exports.WindowGridSnapPolicy;
  for(const inset of [8,13,16]) for(const cell of [9,14,17,28,33]) for(let extent=300;extent<500;extent++) {
    const result=policy.snapNativeExtent(extent,2*inset,cell,2);
    assert.equal((result-2*inset)%cell,0);
    assert.ok(Math.abs(result-extent)<=cell/2);
  }
  const ability=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/entryability/EntryAbility.ets'),'utf8');
  const method=ability.slice(ability.indexOf('  private snapWindowAfterDrag('),ability.indexOf('  private publishBackgroundBellReturnRequest('));
  const owner={}, calls=[]; let metrics={cellWidth:14,cellHeight:27,insetPixels:13}, requested=[];
  vm.runInNewContext(ts.transpileModule('export class Ability {'+method+'}',{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}
  }).outputText,{exports:owner,WindowGridSnapPolicy:policy,BuildProfile:{NATIVE_TERMINAL:true},
    InteractionPolicy:{clampFontSize:x=>x,DEFAULT_FONT_SIZE:14},AppStorage:{get:()=>14},logger:{info(){},warn(){}},
    ApplicationWorkspace:{getInstance:()=>({getViewModel:()=>({getActivePaneRuntime:()=>({surface:{
      getNativeCellMetrics:(font,inset)=>{requested=[font,inset];return metrics;}
    }})})})}});
  const a=new owner.Ability(), done={then(fn){fn();return {catch(){}};}};
  a.mainWindow={getUIContext:()=>({vp2px:x=>1.625*x}),getWindowLimits:()=>({minWidth:200,maxWidth:2000,minHeight:200,maxHeight:1500}),
    resize:(w,h)=>{calls.push(['resize',w,h]);return done;},moveWindowTo:(x,y)=>{calls.push(['move',x,y]);return done;}};
  const start={left:100,top:100,width:1000,height:700};
  a.snapWindowAfterDrag(start,{left:137,top:123,width:963,height:677});
  assert.deepEqual(requested,[23,13]);
  assert.deepEqual(calls,[['resize',964,685],['move',136,115]]);
  calls.length=0;
  a.snapWindowAfterDrag(start,{left:100,top:100,width:963,height:700});
  assert.deepEqual(calls,[['resize',964,700]],'width-only drag cannot change height or position');
  calls.length=0; metrics=null;
  a.snapWindowAfterDrag(start,{left:100,top:100,width:963,height:677});
  assert.equal(calls.length,0,'pending native metrics must not use old Web estimates');
});
test('window visibility reaches retained Pane owners without a UI render pass', () => {
  const index = fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/pages/Index.ets'),'utf8');
  const names = ['onMainWindowVisibilityChanged','syncWorkspace','syncNativeVisibility'];
  const methods = names.map(name => index.match(new RegExp('  private '+name+'\\(.*?[\\s\\S]*?(?=\\n  private |\\n  @Builder)'))?.[0] || '').join('\n');
  const exports = {}, calls=[];
  vm.runInNewContext(ts.transpileModule('export class Index {'+methods+'}',{
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}
  }).outputText,{exports,AppStorage:{setOrCreate(){}},logger:{info(){}},BackgroundBellNotification:{resetForVisibleWindow(){}}});
  const owner=new exports.Index();
  const tabs=[{panes:[{id:'left'},{id:'right'}]},{panes:[{id:'background'}]}];
  const runtimes=new Map(['left','right','background'].map(id=>[id,{id,surface:{setNativeVisible:v=>calls.push([id,v])},viewModel:{requestBlur(){}}}]));
  Object.assign(owner,{mainWindowVisible:false,tabs,activeTabIndex:0,warmTabId:'',
    appVm:{getTabs:()=>tabs,getActiveTabIndex:()=>0},findPaneRuntime:id=>runtimes.get(id),
    mountedPaneRuntimes:()=>Array.from(runtimes.values()),workspaceHasActiveSession:()=>true,activeRemotePaneIds:()=>'',
    restoreApplicationWorkspaceBinding:()=>false,recoverReclaimedRuntimeSessions:()=>false,
    captureMountedTerminalSnapshots(){},clearWarmTabEvictionTimer(){},restoreActivePaneFocus(){}});
  owner.onMainWindowVisibilityChanged();
  assert.deepEqual(calls,[['left',false],['right',false],['background',false]]);
  calls.length=0; owner.mainWindowVisible=true; owner.onMainWindowVisibilityChanged();
  assert.deepEqual(calls,[['left',true],['right',true],['background',false]],'visible split Pane does not require focus');
  calls.length=0; owner.mainWindowVisible=false; owner.syncWorkspace();
  assert.deepEqual(calls,[['left',false],['right',false],['background',false]],'workspace events cannot reveal a hidden window');
});
test('native Pane delivers only unconsumed post-IME keys and preserves layout text', () => {
  const pane = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/view/components/NativeTerminalPane.ets'), 'utf8');
  const start = pane.indexOf('  private handleNativeKey('), end = pane.indexOf('  private handleSearchKey(');
  assert.ok(start >= 0 && end > start);
  const keyMapSource = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/common/constants/KeyCodeMap.ets'), 'utf8');
  const keyMap = {};
  vm.runInNewContext(ts.transpileModule(keyMapSource, {compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText, {exports:keyMap});
  const owner = {};
  vm.runInNewContext(ts.transpileModule('export class Pane { ' + pane.slice(start,end) + ' }', {
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}
  }).outputText, {exports:owner,KeyCodeMap:keyMap.KeyCodeMap,KeyType:{Down:0}});
  const p = new owner.Pane(), sent = [];
  p.onKey = () => false;
  const hovers=[];
  p.native = {hover:mods=>hovers.push(mods),key:(code,mods,text)=>{sent.push({code,mods,text});return true;}};
  const event = (code,unicode=0,mods=[]) => ({type:0,keyCode:code,unicode,getModifierKeyState:keys=>{
    assert.ok(keys.every(k=>['Ctrl','Alt','Shift'].includes(k)),'SDK rejects unsupported modifier names');
    return keys.every(k=>mods.includes(k));
  }});
  assert.equal(p.handleNativeKey(event(2001,49)),false,'pre-IME digit remains available to IME');
  assert.equal(sent.length,0);
  assert.equal(p.handleNativeKey(event(2070)),false,'Escape must reach IME before terminal dispatch');
  assert.equal(sent.length,0,'candidate cancellation must not also send terminal ESC');
  assert.equal(p.handleNativeKey(event(2070),true),true,'IME-unconsumed Escape still reaches terminal');
  assert.equal(sent.at(-1).code,2070);
  assert.equal(p.handleNativeKey(event(2001,49),true),true,'unconsumed digit must reach terminal');
  assert.equal(sent.at(-1).text,'1');
  p.handleNativeKey(event(2007,38,['Shift']),true); assert.equal(sent.at(-1).text,'&');
  p.handleNativeKey(event(2017,0x00e4),true); assert.equal(sent.at(-1).text,'ä','platform keyboard layout text');
  p.handleNativeKey(event(2054),true); assert.equal(sent.at(-1).code,2054);
  const before = sent.length;
  assert.equal(p.handleNativeKey({...event(2001,49),type:1},true),false);
  assert.equal(p.handleNativeKey(event(2072),true),false);
  p.handleNativeKey(event(2072,0,['Ctrl']));
  p.handleNativeKey({...event(2072),type:1});
  assert.deepEqual(hovers,[2,0],'pre-IME modifier down and up both refresh stationary hover');
  p.onKey = () => true; p.handleNativeKey(event(2001,49),true);
  assert.equal(sent.length,before,'release, modifier and app-owned shortcuts cannot duplicate input');
});
test('display retry keyboard activates once before IME while retaining Tab focus and workspace shortcuts', () => {
  const pane = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/view/components/NativeTerminalPane.ets'), 'utf8');
  const start = pane.indexOf('  private handleDisplayRetryKey('), end = pane.indexOf('  private handleNativeKey(');
  assert.ok(start >= 0 && end > start);
  const owner = {};
  vm.runInNewContext(ts.transpileModule('export class Pane {'+pane.slice(start,end)+'}', {
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}
  }).outputText,{exports:owner,KeyType:{Down:0,Up:1}});
  const p = new owner.Pane(); let retries=0, shortcuts=0;
  p.native={retryDisplay(){retries++;}};
  p.onKey=()=>{shortcuts++;return false;};
  const event=(code,type=0,mods=[])=>({keyCode:code,type,getModifierKeyState:keys=>keys.every(k=>mods.includes(k))});
  for(const code of [2054,2050]) {
    assert.equal(p.handleDisplayRetryKey(event(code)),true);
    assert.equal(p.handleDisplayRetryKey(event(code,1)),true);
  }
  assert.equal(retries,2,'one activation per keypress, no post-IME default duplicate');
  assert.equal(shortcuts,0);
  assert.equal(p.handleDisplayRetryKey(event(2049)),false);
  assert.equal(p.handleDisplayRetryKey(event(2049,0,['Shift'])),false);
  assert.equal(shortcuts,0,'Tab and Shift+Tab remain native focus navigation');
  p.handleDisplayRetryKey(event(2049,0,['Ctrl']));
  p.handleDisplayRetryKey(event(2054,0,['Ctrl']));
  assert.equal(shortcuts,2); assert.equal(retries,2);
});
test('search keyboard keeps the focus ring, reverse navigation and IME ownership inside the panel', () => {
  const pane=fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/view/components/NativeTerminalPane.ets'),'utf8');
  const start=pane.indexOf('  private handleSearchKey('), end=pane.indexOf('  @Builder',start);
  assert.ok(start>=0 && end>start);
  const owner={};
  vm.runInNewContext(ts.transpileModule('export class Pane {'+pane.slice(start,end)+'}', {
    compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}
  }).outputText,{exports:owner,KeyType:{Down:0}});
  const p=new owner.Pane(), focus=[], searches=[]; let closed=0, forwarded=0;
  Object.assign(p,{paneId:'test',query:'alpha',resultCount:2,composingSearch:false,
    getUIContext:()=>({getFocusController:()=>({requestFocus:id=>focus.push(id)})}),
    native:{search:(text,direction)=>searches.push([text,direction])},
    surface:{closeSearch:()=>closed++},onKey:()=>{forwarded++;return false;}});
  const event=(keyCode,mods=[],type=0)=>({keyCode,type,getModifierKeyState:keys=>keys.every(k=>mods.includes(k))});
  for(let i=0;i<4;i++) assert.equal(p.handleSearchKey(event(2049),i),true);
  assert.deepEqual(focus,['native-search-prev-test','native-search-next-test','native-search-close-test','native-search-test']);
  p.handleSearchKey(event(2049,['Shift']),0); assert.equal(focus.at(-1),'native-search-close-test');
  p.resultCount=0; p.handleSearchKey(event(2049),0); assert.equal(focus.at(-1),'native-search-close-test');
  p.handleSearchKey(event(2049,['Shift']),3); assert.equal(focus.at(-1),'native-search-test');
  p.handleSearchKey(event(2054),0); p.handleSearchKey(event(2054,['Shift']),0);
  assert.deepEqual(searches,[['alpha',1],['alpha',-1]]);
  assert.equal(p.handleSearchKey(event(2019,['Ctrl']),0),false);
  assert.equal(p.handleSearchKey(event(2038,['Ctrl']),0),false);
  p.composingSearch=true;
  for(const key of [2049,2054,2070]) assert.equal(p.handleSearchKey(event(key),0),false);
  assert.equal(closed,0); assert.equal(forwarded,0);
  p.composingSearch=false; p.handleSearchKey(event(2070),0); assert.equal(closed,1);
  assert.equal(p.handleSearchKey(event(2054,[],1),0),false,'key up cannot navigate twice');
  p.resultCount=2;
  for(const code of [2054,2050]) {
    assert.equal(p.handleSearchKey(event(code),2),true,'focused navigation activates before IME');
    assert.equal(p.handleSearchKey(event(code,[],1),2),true,'release cannot cause a second default activation');
  }
  assert.deepEqual(searches.slice(-2),[['alpha',1],['alpha',1]]);
  assert.equal(p.handleSearchKey(event(2054),3),true); assert.equal(closed,2);
});
test('empty search owns a fresh worker generation; reopening retains the query and rejects stale close', () => {
  const f=fixture(), c=f.control;
  c.openSearch();
  const initial=f.accepted.filter(x=>x.kind==='search');
  assert.equal(initial.length,1,'opening without typing must register the current search generation');
  assert.equal(initial[0].text,'');
  c.search('alpha'); const generation=c.searchGeneration;
  c.openSearch(); assert.equal(c.searchGeneration,generation,'reopening only selects existing text');
  f.emit('search-close',0,initial[0].owner); assert.equal(c.isSearching(),true);
  f.emit('search-close',0,generation); assert.equal(c.isSearching(),false);
  c.openSearch(); f.emit('search-close',0,generation); assert.equal(c.isSearching(),true);
  f.emit('search-close',0,c.searchGeneration); assert.equal(c.isSearching(),false);
});
test('UTF-8 search limit reports a local error, clears old results and recovers without failing terminal', () => {
  const f=fixture(), c=f.control, errors=[];
  c.onSearchError=error=>errors.push(error);
  c.openSearch();
  for(const text of ['a'.repeat(1024*1024),'😀'.repeat(256*1024)]) {
    c.search(text); assert.equal(errors.at(-1),'');
    assert.equal(f.accepted.filter(x=>x.kind==='search').at(-1).text,text);
    c.search(text+'a'); assert.equal(errors.at(-1),'search_query_too_large');
    assert.equal(f.accepted.filter(x=>x.kind==='search').at(-1).text,'','old highlights are cleared');
    assert.equal(c.failed,false); assert.equal(c.isSearching(),true);
  }
  c.search('中'.repeat(300)); assert.equal(errors.at(-1),'');
  c.write(new Uint8Array([65]),0); assert.equal(f.accepted.at(-1).kind,'write');
});
test('search byte-budget rejection clears stale matches and allows retry after output consumption', () => {
  const f=fixture(), c=f.control, errors=[];
  c.onSearchError=error=>errors.push(error);
  c.openSearch(); c.search('previous');
  c.write(new Uint8Array([65]),0);
  const query='a'.repeat(1024*1024);
  c.search(query); assert.equal(errors.at(-1),'search_busy');
  assert.equal(f.accepted.filter(x=>x.kind==='search').at(-1).text,'');
  assert.equal(c.failed,false); assert.equal(c.isSearching(),true);
  f.consume(f.accepted.find(x=>x.kind==='write'));
  c.search(query); assert.equal(errors.at(-1),'');
  assert.equal(f.accepted.filter(x=>x.kind==='search').at(-1).text,query);
});
test('search terminal click closes before forwarding; external blur can close without stealing focus', () => {
  const f = fixture(); let requests = 0;
  f.control.attach('1',900,600,{vp2px:x=>2*x}); f.emit('presented',0,f.control.displayGeneration);
  f.control.onRequestFocus = () => { requests++; return true; };
  f.control.openSearch(); f.control.pointer(0,1,10,10,0);
  assert.equal(f.control.isSearching(),false);
  assert.equal(f.accepted.filter(x=>x.kind==='pointer').length,1);
  f.control.openSearch(); requests = 0;
  f.control.closeSearch(false); f.control.blur();
  assert.equal(requests,0); assert.equal(f.control.isSearching(),false);
  f.control.openSearch(); f.control.search('query');
  f.emit('search-close',0,f.control.searchGeneration-1);
  assert.equal(f.control.isSearching(),true);
  f.emit('search-close',0,f.control.searchGeneration);
  assert.equal(f.control.isSearching(),false);
  f.control.openSearch(); f.control.changeInputOwner();
  assert.equal(f.control.isSearching(),false);
  f.control.openSearch(); f.control.page(true);
  assert.equal(f.control.isSearching(),false);
});
test('bounded output retains rejected tail, copies caller bytes and commits barrier after consumption', () => {
  const f = fixture(), bytes = new Uint8Array(1536 * 1024).fill(65);
  f.control.write(bytes, 7); bytes.fill(66);
  let done = false; f.control.barrier(() => { done = true; });
  assert.equal(f.accepted.length, 4);
  assert.equal(f.control.outstandingBytes, 1536 * 1024);
  assert.equal(f.accepted[0].bytes[0], 65);
  f.emit('presented'); assert.equal(done, false);
  for (let i = 0; i < 6; i++) f.consume(f.accepted[i]);
  assert.equal(done, false);
  f.consume(f.accepted[6]); assert.equal(done, true);
  assert.equal(f.control.outstandingBytes, 0);
  assert.deepEqual(f.events.filter(x => x[0] === 'pressure'), [['pressure', true], ['pressure', false]]);
  assert.equal(f.timers.size, 0);
});
test('detached VT continues consuming and rejects late input and stale surface presentation', () => {
  const f = fixture();
  const context = { vp2px: x => x * 2 };
  f.control.attach('123', 900, 600, context); f.control.focus();
  f.emit('presented', 0, f.control.displayGeneration);
  const oldInput = f.control.inputOwner, oldDisplay = f.control.displayGeneration;
  f.emit('input', 0, oldInput, 'first');
  f.control.changeInputOwner(); f.emit('input', 0, oldInput, 'stale-auth-round');
  f.control.detach(); f.control.write(new Uint8Array([65]), 9);
  f.consume(f.accepted.find(x=>x.kind==='write')); assert.equal(f.control.outstandingBytes, 0);
  f.control.attach('456', 900, 600, context);
  f.emit('presented', 0, oldDisplay); assert.equal(f.control.presented, false);
  f.emit('presented', 0, f.control.displayGeneration); assert.equal(f.control.presented, true);
  f.emit('input', 0, oldInput, 'stale-pane');
  assert.deepEqual(f.events.filter(x => x[0] === 'input'), [['input', 'first']]);
  assert.deepEqual(f.events.filter(x => x[0] === 'ready'), [['ready', false], ['ready', true]]);
});
test('hidden native terminal consumes output but only its new visible generation can restore input', () => {
  const f=fixture(), context={vp2px:x=>2*x};
  f.control.attach('1',900,600,context); f.control.focus(); f.emit('presented',0,f.control.displayGeneration);
  const oldDisplay=f.control.displayGeneration, oldInput=f.control.inputOwner;
  f.control.setVisible(false); f.control.setVisible(false);
  assert.equal(f.accepted.filter(x=>x.kind==='visibility').length,1);
  f.emit('presented',0,oldDisplay); f.emit('input',0,oldInput,'hidden');
  assert.equal(f.control.presented,false);
  f.control.write(new Uint8Array([65,66]),17);
  f.consume(f.accepted.find(x=>x.kind==='write'));
  assert.equal(f.control.outstandingBytes,0);
  f.control.setVisible(true); f.control.focus();
  f.emit('presented',0,oldDisplay); assert.equal(f.control.presented,false);
  f.emit('presented',0,f.control.displayGeneration);
  f.emit('input',0,f.control.inputOwner,'returned');
  assert.deepEqual(f.events.filter(x=>x[0]==='input'),[['input','returned']]);
  f.control.setVisible(false); let rebuilt=0;
  f.control.onRebuildDisplay=()=>rebuilt++;
  f.emit('surface-unavailable',0,f.control.displayGeneration);
  assert.equal(rebuilt,0,'hidden failure cannot mount a hidden UI or steal focus');
  f.control.setVisible(true); assert.equal(rebuilt,1,'hidden attachment failure is recovered when shown');
  f.control.dispose(); const admitted=f.accepted.length;
  f.control.setVisible(false); assert.equal(f.accepted.length,admitted);
});
test('terminal replies retain their original output owner and never become local input', () => {
  const f = fixture();
  f.emit('reply', 1, 17, '\x1b[1;1R'); f.emit('reply', 2, 0, 'local-query');
  assert.deepEqual(f.events, [['reply', '\x1b[1;1R', 17]]);
});
test('display recovery requests one Pane rebuild, preserves output and rejects stale destruction', () => {
  const f = fixture(), context = {vp2px:x=>2*x}; let rebuilds = 0;
  f.control.onRebuildDisplay = () => { rebuilds++; };
  f.control.attach('old',900,600,context); f.control.focus();
  f.emit('presented',0,f.control.displayGeneration);
  const oldOwner = f.control.inputOwner, oldDisplay = f.control.displayGeneration;
  f.emit('surface-unavailable',0,oldDisplay);
  assert.equal(rebuilds,1); assert.equal(f.control.presented,false);
  f.emit('input',0,oldOwner,'late'); assert.equal(f.events.filter(x=>x[0]==='input').length,0);
  f.control.write(new Uint8Array([65]),17); f.consume(f.accepted[0]);
  assert.equal(f.control.outstandingBytes,0); assert.equal(f.control.failed,false);
  f.control.detach('old'); f.control.attach('new',900,600,context);
  f.control.detach('old'); assert.equal(f.control.isAttached(),true);
  f.emit('surface-unavailable',0,oldDisplay); assert.equal(rebuilds,1);
  f.emit('presented',0,f.control.displayGeneration); assert.equal(f.control.presented,true);
  f.emit('surface-unavailable',0,f.control.displayGeneration);
  assert.equal(rebuilds,1,'no unbounded remount loop');
  assert.equal(f.control.failed,false,'GPU failure does not destroy the VT or Session');
});
test('explicit display retry retains output, rejects duplicates and cannot revive a failed or closed VT', () => {
  const f = fixture(), context = {vp2px:x=>2*x}; let rebuilds = 0;
  f.control.onRebuildDisplay = () => { rebuilds++; };
  f.control.attach('old',900,600,context); f.control.focus();
  f.control.retryDisplay(); assert.equal(rebuilds,0,'initial presentation is not a display failure');
  f.emit('presented',0,f.control.displayGeneration);
  f.emit('surface-unavailable',0,f.control.displayGeneration);
  f.control.detach('old'); f.control.attach('replacement',900,600,context);
  f.emit('surface-unavailable',0,f.control.displayGeneration);
  assert.equal(rebuilds,1,'automatic recovery remains bounded');
  assert.equal(f.control.canRetryDisplay(),true);
  const blockedOwner = f.control.inputOwner;
  f.emit('input',0,blockedOwner,'blocked');
  f.control.write(new Uint8Array([65,66]),17); f.consume(f.accepted[0]);
  assert.equal(f.control.outstandingBytes,0);
  f.control.blur(); f.control.retryDisplay(); f.control.retryDisplay();
  assert.equal(rebuilds,2,'one explicit attempt; duplicate clicks during mounting are ignored');
  f.control.detach('replacement'); f.control.attach('retry',900,600,context);
  f.emit('surface-unavailable',0,f.control.displayGeneration);
  assert.equal(rebuilds,2,'manual attempt cannot recursively restart automatic recovery');
  f.control.retryDisplay(); assert.equal(rebuilds,3);
  f.control.detach('retry'); f.control.attach('ready',900,600,context);
  f.emit('presented',0,f.control.displayGeneration);
  f.emit('input',0,blockedOwner,'stale');
  f.emit('input',0,f.control.inputOwner,'resumed');
  assert.deepEqual(f.events.filter(x=>x[0]==='input'),[['input','resumed']]);
  assert.equal(f.control.canRetryDisplay(),false);
  f.control.retryDisplay(); assert.equal(rebuilds,3);
  f.emit('surface-unavailable',0,f.control.displayGeneration); f.emit('failure');
  assert.equal(f.control.canRetryDisplay(),false); f.control.retryDisplay(); assert.equal(rebuilds,3);
  const closed = fixture(); closed.control.attach('1',900,600,context);
  closed.emit('surface-unavailable',0,closed.control.displayGeneration); closed.control.dispose();
  assert.equal(closed.control.canRetryDisplay(),false);
});
test('focus intent before mount cannot call the platform; invisible focus rejection cannot attach IME', () => {
  const f = fixture(); let requests = 0;
  f.control.onRequestFocus = () => { requests++; return false; };
  f.control.focus(); assert.equal(requests, 0);
  f.control.attach('1',900,600,{ vp2px: x => 2*x });
  f.emit('presented',0,f.control.displayGeneration);
  assert.equal(requests,1); assert.equal(f.control.imeAttached,false);
  f.control.onRequestFocus = () => true;
  f.control.focus(); assert.equal(f.control.imeAttached,true);
  const owner = f.control.inputOwner;
  f.control.setInputMasked(true); f.control.changeInputOwner();
  f.emit('input',0,owner,'stale-secret');
  assert.equal(f.events.filter(x => x[0] === 'input').length,0);
});
test('hard admission bound and callback starvation freeze instead of fabricating a barrier', () => {
  for (const overflow of [false, true]) {
    const f = fixture(); let complete = false;
    f.control.write(new Uint8Array(1), 1); f.control.barrier(() => { complete = true; });
    if (overflow) f.control.write(new Uint8Array(2 * 1024 * 1024), 1);
    else { f.control.lastProgress = Date.now() - 11000; [...f.timers.values()][0](); }
    assert.equal(complete, false); assert.equal(f.control.failed, true);
    assert.equal(f.events.filter(x => x[0] === 'failure').length, 1);
    assert.equal(f.timers.size, 0);
    f.emit('consumed', f.accepted[1].seq); assert.equal(complete, false);
  }
});
test('search and remote effects reject stale ownership; attention requires acknowledgement to rearm', () => {
  const f = fixture(); let bells = 0, results = 0;
  f.control.onBell = () => bells++;
  f.control.acceptsRemoteEffect = owner => owner === 17;
  f.emit('bell',0,16); f.emit('bell',0,17); f.emit('bell',0,17);
  assert.equal(bells,1);
  f.control.onSearchResult = () => results++;
  f.control.openSearch(); f.control.search('query');
  f.emit('search',0,f.control.searchGeneration-1,'1,8');
  f.emit('search',0,f.control.searchGeneration,'1,8');
  f.control.closeSearch(); f.emit('search',0,f.control.searchGeneration,'1,8');
  assert.equal(results,1);
});
test('focus transitions rearm BEL delivery without acknowledging a background Pane', () => {
  const f=fixture(), c=f.control; let bells=0, acknowledgements=0;
  c.focused=true; c.presented=true; c.acceptsRemoteEffect=owner=>owner===17;
  c.onBell=()=>bells++; c.onAttentionAcknowledged=()=>acknowledgements++;
  f.emit('bell',0,17);
  c.blur();
  assert.equal(acknowledgements,0,'leaving a Pane must preserve its attention');
  f.emit('bell',0,17); f.emit('bell',0,17);
  assert.equal(bells,2,'a foreground BEL must not suppress a new background BEL');
  c.blur(); f.emit('bell',0,17);
  assert.equal(bells,2,'duplicate blur must not rearm an unchanged background episode');
  c.focusedBySurface();
  assert.equal(acknowledgements,1,'returning focus acknowledges the delivered episode');
  c.blur(); f.emit('bell',0,16); f.emit('bell',0,17); f.emit('bell',0,17);
  assert.equal(bells,3,'the next focus interval delivers one current-owner BEL');
});
if (['cold','warm'].includes(process.argv[3])) {
  const mode = process.argv[3], marker = mode === 'cold' ? 'STARTUP_PERF' : 'STARTUP_WARM';
  test('startup probe rejects blank frames, stale generations, hidden frames and unconsumed output', () => {
    const f = fixture(), c = f.control;
    c.focus(); c.attach('123',900,600,{vp2px:x=>x});
    const painted = phase => f.logs.filter(s=>s.includes(marker+' phase='+phase)).length;
    f.emit('presented',0,c.displayGeneration);
    assert.equal(painted('T4'),0,'initial blank frame is not readiness');
    c.write(new TextEncoder().encode('unrelated a'),0);
    let item=f.accepted.at(-1); f.consume(item); f.emit('presented',item.seq,c.displayGeneration);
    assert.equal(painted('T4'),0,'unrelated local output is not the prompt');
    if(mode==='warm') { c.setVisible(false); c.setVisible(true); c.focus(); }
    c.write(new TextEncoder().encode('\x1b[32mltty>\x1b[0m '),0); item=f.accepted.at(-1);
    if(mode==='cold') { f.emit('presented',item.seq,c.displayGeneration); assert.equal(painted('T4'),0); }
    f.consume(item); f.emit('presented',item.seq,c.displayGeneration-1); assert.equal(painted('T4'),0);
    c.focused=false; f.emit('presented',item.seq,c.displayGeneration); assert.equal(painted('T4'),0);
    c.focus(); f.emit('presented',item.seq,c.displayGeneration); assert.equal(painted('T4'),1);
    c.onInput=text=>c.write(new TextEncoder().encode(text),0);
    f.emit('input',0,c.inputOwner-1,'a'); assert.equal(c.startupAwaitingEcho,false);
    c.write(new Uint8Array([97]),0); item=f.accepted.at(-1); f.consume(item);
    f.emit('presented',item.seq,c.displayGeneration); assert.equal(painted('T5'),0,'unsolicited echo cannot pass');
    f.emit('input',0,c.inputOwner,'b'); item=f.accepted.at(-1); f.consume(item);
    f.emit('presented',item.seq,c.displayGeneration); assert.equal(painted('T5'),0);
    f.emit('input',0,c.inputOwner,'a'); item=f.accepted.at(-1);
    f.emit('presented',item.seq,c.displayGeneration); assert.equal(painted('T5'),0,'must consume');
    f.consume(item); f.emit('presented',item.seq-1,c.displayGeneration); assert.equal(painted('T5'),0,'must paint matching sequence');
    f.emit('presented',item.seq,c.displayGeneration-1); assert.equal(painted('T5'),0);
    f.emit('presented',item.seq,c.displayGeneration); assert.equal(painted('T5'),1);
    f.emit('presented',item.seq,c.displayGeneration); assert.equal(painted('T5'),1,'one marker per round');
    c.setVisible(false); f.emit('presented',item.seq,c.displayGeneration); assert.equal(painted('T4'),1);
    if(mode==='warm') {
      c.setVisible(true); c.focus(); f.emit('presented',item.seq,c.displayGeneration);
      assert.equal(painted('T4'),2,'next foreground round rearms'); assert.equal(painted('T5'),1,'previous echo cannot pass next round');
    }
  });
}
if (process.argv[3] === 'page') {
  test('busy search cleanup never acknowledges the rejected original query',()=>{
    const f=fixture(),c=f.control; c.acceptancePaneId='pane-1-1'; c.openSearch();
    c.write(new Uint8Array(1024*1024),17);
    const before=f.logs.length;
    c.search('NOT-ADMITTED');
    assert.equal(f.accepted.at(-1).kind,'search');
    assert.equal(f.accepted.at(-1).text,'','only clearing the old search was admitted');
    f.emit('search',0,c.searchGeneration,'0,0');
    assert.equal(f.logs.slice(before).some(s=>s.includes('ACCEPTANCE_NATIVE_SEARCH_QUERY')),false,
      'a completed empty cleanup cannot prove a negative result for the rejected query');
    assert.equal(f.events.some(e=>e[0]==='failure'),false,'busy search remains a local query error');
  });
  test('Mosh observation follows real consumed commands and current search generation without logging content',()=>{
    const f=fixture(),c=f.control; c.acceptancePaneId='pane-1-1';
    c.page(true); f.consume(f.accepted.at(-1));
    c.write(new TextEncoder().encode('PRIVATE-CONTENT'),17);
    const item=f.accepted.at(-1);
    assert.equal(f.logs.length,0,'admission cannot acknowledge consumption');
    f.consume(item);
    assert.match(f.logs[0],/ACCEPTANCE_NATIVE_WRITE_CONSUMED pane=pane-1-1 sequence=\d+ owner=17 bytes=15/);
    f.emit('consumed',item.seq,17); assert.equal(f.logs.length,1,'duplicate event is not a new acknowledgement');
    c.page(false); f.consume(f.accepted.at(-1));
    c.write(new TextEncoder().encode('LOCAL'),0); f.consume(f.accepted.at(-1)); assert.equal(f.logs.length,1);
    c.openSearch(); c.search('PRIVATE-QUERY');
    const generation=c.searchGeneration;
    assert.match(f.logs.at(-1),new RegExp('generation='+generation+' length=13'));
    const before=f.logs.length; f.emit('search',0,generation-1,'0,0'); assert.equal(f.logs.length,before);
    f.emit('search',0,generation,'1,2'); assert.match(f.logs.at(-1),/ACCEPTANCE_NATIVE_SEARCH_RESULT.*result=1,2/);
    assert.equal(f.logs.some(s=>s.includes('PRIVATE')),false);
  });
}
if (process.argv[3] === 'output') {
  test('output oracle validates every ordered byte, then waits for consumption and the current successful frame',()=>{
    const frame=(id,n=3)=>'\x1b]0;LTTY_PERF_BEGIN__:'+id+':'+n+':80\x07'+
      Array.from({length:n},(_,i)=>('LTTY_PERF_'+id+'_'+String(i).padStart(5,'0')+' ').padEnd(80,'X')+'\r\n').join('')+
      '\x1b]0;LTTY_PERF_END__:'+id+'\x07\r\nfixture> ';
    function sample(text,step,owner=17,enabled=true) {
      const f=fixture(enabled),c=f.control;
      c.focus();c.attach('123',900,600,{vp2px:x=>x});f.emit('presented',0,c.displayGeneration);
      const data=new TextEncoder().encode(text);
      for(let i=0;i<data.length;i+=step)c.write(data.slice(i,i+step),owner);
      const writes=f.accepted.filter(x=>x.kind==='write');
      f.emit('presented',writes.at(-1).seq,c.displayGeneration);
      assert.equal(f.logs.length,0,'admission alone cannot pass');
      for(const item of writes)f.consume(item);
      f.emit('presented',writes.at(-1).seq,c.displayGeneration-1);assert.equal(f.logs.length,0);
      f.emit('presented',0,c.displayGeneration);assert.equal(f.logs.length,0,'old frame cannot pass');
      f.emit('presented',writes.at(-1).seq,c.displayGeneration);
      return f;
    }
    for(const step of [1,7,81,4096]) {
      const f=sample(frame('ordered'),step);assert.equal(f.logs.length,1);assert.match(f.logs[0],/actualBytes=246 .*actualLines=3 mismatches=0 contentOrdered=true/);
    }
    for(const bad of [frame('wrong').replace('00001','00002'),frame('drop').replace(/X/,'Y'),frame('missing',3).replace(/LTTY_PERF_missing_00001[^\n]*\n/,''),frame('extra').replace('00001','00000')]) {
      const f=sample(bad,97);assert.equal(f.logs.length,1);assert.match(f.logs[0],/contentOrdered=false/);
    }
    assert.equal(sample(frame('local'),128,0).logs.length,0,'local output must not arm');
    assert.equal(sample(frame('disabled'),128,17,false).logs.length,0,'compile-time gate must be silent');
    assert.equal(sample(frame('incomplete').replace('LTTY_PERF_END__','LTTY_NO_END____'),128).logs.length,0,'incomplete frame cannot pass');
    const full=sample(frame('full',12000),16384);assert.match(full.logs[0],/actualBytes=984000 .*actualLines=12000 mismatches=0 contentOrdered=true/);
    const c=full.control; c.write(new TextEncoder().encode(frame('next')),17);
    const next=full.accepted.at(-1); full.consume(next);full.emit('presented',next.seq,c.displayGeneration);
    assert.equal(full.logs.length,2,'next public frame is independent');
  });
  test('physical input observer requires one accepted input, its consumed echo and a current visible frame',()=>{
    const begin='\x1b]0;LTTY_PERF_BEGIN__:input1:1:80\x07';
    const end='\x1b]0;LTTY_PERF_END__:input1\x07';
    function ready(enabled=true) {
      const f=fixture(enabled),c=f.control;
      c.focus();c.attach('123',900,600,{vp2px:x=>x});f.emit('presented',0,c.displayGeneration);
      c.write(new TextEncoder().encode(begin),17);f.consume(f.accepted.at(-1));
      return f;
    }
    function echo(f,text='?') {
      f.control.write(new TextEncoder().encode(text),17);return f.accepted.at(-1);
    }
    function paint(f,write){f.consume(write);f.emit('presented',write.seq,f.control.displayGeneration);}
    const f=ready(),c=f.control,delivered=[];c.onInput=x=>delivered.push(x);
    f.emit('input',0,c.inputOwner-1,'?');const wrongOwner=echo(f);paint(f,wrongOwner);
    assert.equal(f.logs.length,0,'stale input cannot start a sample');
    f.emit('input',0,c.inputOwner,'?');const first=echo(f);
    f.emit('presented',first.seq,c.displayGeneration);assert.equal(f.logs.length,0,'echo admission cannot pass');
    f.consume(first);f.emit('presented',first.seq,c.displayGeneration-1);assert.equal(f.logs.length,0);
    f.emit('presented',first.seq-1,c.displayGeneration);assert.equal(f.logs.length,0,'pre-echo frame cannot pass');
    f.emit('presented',first.seq,c.displayGeneration);
    assert.match(f.logs[0],/NATIVE_INPUT_PROBE case=input1 sample=1 inputToFrameMs=\d+ duringLoad=true valid=true/);
    assert.deepEqual(delivered,['?'],'probe never generates input');
    f.emit('input',0,c.inputOwner,'?');paint(f,echo(f));assert.equal(f.logs.length,2);
    const interrupted=ready();interrupted.emit('input',0,interrupted.control.inputOwner,'?');
    const late=echo(interrupted);interrupted.control.invalidateInput();paint(interrupted,late);
    assert.equal(interrupted.logs.length,0,'owner/focus invalidation cannot pass pending input');
    const duplicate=ready();duplicate.emit('input',0,duplicate.control.inputOwner,'?');paint(duplicate,echo(duplicate,'??'));
    const body='LTTY_PERF_input1_00000 '.padEnd(80,'X')+'\r\n';paint(duplicate,echo(duplicate,body+end));
    assert.match(duplicate.logs.at(-1),/mismatches=1 contentOrdered=false/,'duplicate echo is not silently stripped');
    const overlap=ready();overlap.emit('input',0,overlap.control.inputOwner,'?');overlap.emit('input',0,overlap.control.inputOwner,'?');
    paint(overlap,echo(overlap));assert.match(overlap.logs[0],/valid=false/,'overlapping input cannot give valid latency');
    const disabled=ready(false);disabled.emit('input',0,disabled.control.inputOwner,'?');paint(disabled,echo(disabled));
    assert.equal(disabled.logs.length,0,'compile-time disabled input probe stays silent');
  });
}
(async () => {
  const f = fixture();
  const context = { vp2px: x => 2*x, getHostContext: () => ({ applicationInfo: { accessTokenId: 42 } }) };
  const flush = () => new Promise(setImmediate);
  function ready(shared) {
    const f = fixture(true, shared);
    f.control.attach('123',900,600,context); f.control.focus(); f.emit('presented',0,f.control.displayGeneration);
    f.errors = []; f.control.onClipboardError = name => f.errors.push(name);
    return f;
  }
  f.control.attach('123',900,600,context); f.control.focus(); f.emit('presented',0,f.control.displayGeneration);
  let finishRead;
  f.clipboard.readText = () => new Promise(resolve => { finishRead = resolve; });
  let pending = f.control.paste(); await flush(); f.control.changeInputOwner(); finishRead('previous-secret-round'); await pending;
  assert.equal(f.accepted.filter(x => x.kind === 'paste').length,0);
  pending = f.control.paste(); await flush(); finishRead('public-text'); await pending;
  assert.equal(f.accepted.filter(x => x.kind === 'paste')[0].text,'public-text');
  let finishWrite;
  f.clipboard.writeText = () => new Promise(resolve => { finishWrite = resolve; });
  f.emit('copy',19,f.control.inputOwner,'selected'); finishWrite(true); await new Promise(setImmediate);
  assert.equal(f.accepted.find(x => x.kind === 'copy').revision,19);
  console.log('PASS asynchronous paste ownership and exact successful-copy revision'); count++;
  const paneSource = fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/view/components/NativeTerminalPane.ets'),'utf8');
  const paneExports = {};
  vm.runInNewContext(ts.transpileModule('export class Pane {' + paneSource.slice(
    paneSource.indexOf('  private handleNativeKey('), paneSource.indexOf('  private handleSearchKey(')) + '}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports: paneExports, KeyCodeMap: keyMapExports.KeyCodeMap, KeyType: { Down: 0 } });
  function shortcut(f) {
    const p = new paneExports.Pane(); p.native = f.control; p.onKey = () => false;
    assert.equal(p.handleNativeKey({ type: 0, keyCode: 2038, getModifierKeyState: keys => keys.every(k => k === 'Ctrl') }), true);
  }
  // The unchanged C++ Right/selection contract is tested by runtime-test.cpp.
  // Here only the native boundary is modeled; production controller and platform wrapper run intact.
  function right(f, selection = false) {
    f.api.pointer = (_h, action, button, _x, _y, _mods, owner) => {
      assert.equal(button, 2);
      if (action === 1) f.emit(selection ? 'copy' : 'paste-request', 19, owner, selection ? 'selected' : '');
      return 20;
    };
    f.control.pointer(0,2,10,10,0); f.control.pointer(1,2,10,10,0);
  }
  for (const intent of [shortcut, right, f => f.control.paste()]) {
    const f = ready(); f.state.grant = -1;
    intent(f); await flush();
    assert.equal(f.state.requests,1); assert.equal(f.state.reads,1);
    assert.equal(f.accepted.filter(x => x.kind === 'paste').length,1);
    intent(f); await flush(); assert.equal(f.state.requests,2,'no cached grant');
    f.state.grant = 0; intent(f); await flush(); assert.equal(f.state.requests,2,'already granted needs no request');
  }
  console.log('PASS local Right, Ctrl+V and direct paste check/request/read through production owners'); count++;
  for (const result of [{ authResults: [-1] }, { authResults: [] }, { authResults: [0,-1] }, null]) {
    const f = ready(); f.state.grant = -1;
    f.state.request = async () => { if (result === null) throw Error('request'); return result; };
    right(f); await flush();
    assert.equal(f.state.reads,0); assert.equal(f.accepted.filter(x => x.kind === 'paste').length,0);
    assert.equal(f.errors[0],result === null ? 'paste_failed' : 'paste_permission_denied');
    f.state.request = async () => ({ authResults: [0] });
    shortcut(f); await flush(); assert.equal(f.state.reads,1,'failure releases in-flight guard for fresh intent');
  }
  console.log('PASS denied, malformed and failed authorization never reads and fresh intent can recover'); count++;
  {
    const f = ready(); f.state.grant = -1;
    f.state.request = async () => ({ authResults: [-1], dialogShownResults: [false] });
    right(f); await flush();
    assert.equal(f.state.settingsRequests,1,'explicit no-dialog denial offers the supported system settings dialog');
    assert.equal(f.state.reads,1); assert.equal(f.accepted.filter(x => x.kind === 'paste').length,1);
    assert.equal(f.errors.length,0);
  }
  console.log('PASS fixed denial without an ordinary dialog can grant through the system settings dialog'); count++;
  for (const result of [
    { authResults: [-1], dialogShownResults: [true] }, { authResults: [-1] },
    { authResults: [-1], dialogShownResults: [] }, { authResults: [-1], dialogShownResults: [undefined] },
    { authResults: [-1], dialogShownResults: [false,false] }, { authResults: [], dialogShownResults: [false] },
    { authResults: [-1,-1], dialogShownResults: [false] }, { authResults: [1], dialogShownResults: [false] },
    { authResults: [0], dialogShownResults: [false] }
  ]) {
    const f = ready(); f.state.grant = -1; f.state.request = async () => result;
    await f.control.paste();
    assert.equal(f.state.settingsRequests,0,'shown, unknown or non-denied ordinary result cannot request settings');
    assert.equal(f.state.reads,result.authResults[0] === 0 ? 1 : 0);
  }
  console.log('PASS shown or unknown ordinary dialog and malformed denial never trigger a second dialog'); count++;
  for (const result of [[-1],[],[0,-1],null]) {
    const f = ready(); f.state.grant = -1;
    f.state.request = async () => ({ authResults: [-1], dialogShownResults: [false] });
    f.state.settingsRequest = async () => { if (result === null) throw Error('settings'); return result; };
    await f.control.paste();
    assert.equal(f.state.requests,1); assert.equal(f.state.settingsRequests,1); assert.equal(f.state.reads,0);
    assert.equal(f.errors[0],result === null ? 'paste_failed' : 'paste_permission_denied');
    f.state.settingsRequest = async () => [0];
    await f.control.paste();
    assert.equal(f.state.settingsRequests,2,'only a fresh user intent retries after denial/error');
    assert.equal(f.state.reads,1,'both guards released after settings completion');
  }
  console.log('PASS settings denial and errors do not read or loop and release guards for a fresh paste'); count++;
  for (const invalidate of [c => { c.blur(); c.focus(); }, c => c.changeInputOwner(), c => c.openSearch(),
    c => c.setVisible(false), c => c.detach(), c => c.dispose(), c => c.fail()]) {
    for (const stage of ['ordinary','settings']) {
      const shared = clipboardFixture(), f = ready(shared), other = ready(shared); let finish;
      f.state.grant = -1;
      f.state.request = stage === 'ordinary' ? () => new Promise(resolve => { finish = resolve; }) :
        async () => ({ authResults: [-1], dialogShownResults: [false] });
      if (stage === 'settings') f.state.settingsRequest = () => new Promise(resolve => { finish = resolve; });
      const pending = f.control.paste(); await flush();
      right(f); shortcut(f); await other.control.paste();
      assert.equal(f.state.requests,1,'no queued or cross-Pane ordinary request while either dialog waits');
      invalidate(f.control);
      finish(stage === 'ordinary' ? { authResults: [-1], dialogShownResults: [false] } : [0]);
      await pending;
      assert.equal(f.state.settingsRequests,stage === 'ordinary' ? 0 : 1,'old intent cannot open a later settings dialog');
      assert.equal(f.state.reads,0); assert.equal(f.accepted.filter(x => x.kind === 'paste').length,0);
      if (!f.control.closing && !f.control.failed) assert.equal(f.errors[0],'paste_cancelled');
    }
  }
  console.log('PASS both authorization waits reject stale owners and keep duplicate requests out'); count++;
  for (const invalidate of [c => c.blur(), c => c.changeInputOwner(), c => c.openSearch(),
    c => c.setVisible(false), c => c.detach(), c => c.dispose(), c => c.fail()]) {
    for (const stage of ['permission','read']) {
      const f = ready(); let finish;
      if (stage === 'permission') {
        f.state.grant = -1; f.state.request = () => new Promise(resolve => { finish = resolve; });
      } else { f.clipboard.readText = () => { f.state.reads++; return new Promise(resolve => { finish = resolve; }); }; }
      const pending = f.control.paste(); await flush(); invalidate(f.control);
      finish(stage === 'permission' ? { authResults: [0] } : 'public-text'); await pending;
      assert.equal(f.state.reads,stage === 'permission' ? 0 : 1);
      assert.equal(f.accepted.filter(x => x.kind === 'paste').length,0);
      if (stage === 'permission' && !f.control.closing && !f.control.failed) assert.equal(f.errors[0],'paste_cancelled');
    }
  }
  console.log('PASS permission and read completions discard stale focus, session, search, display and closed owners'); count++;
  {
    const shared = clipboardFixture(), a = ready(shared), b = ready(shared); let finish;
    shared.state.grant = -1; shared.state.request = () => new Promise(resolve => { finish = resolve; });
    const pending = a.control.paste(); right(a); shortcut(a); await b.control.paste();
    assert.equal(shared.state.requests,1); assert.equal(shared.state.reads,0);
    finish({ authResults: [0] }); await pending;
    assert.equal(shared.state.reads,1); assert.equal(b.accepted.filter(x => x.kind === 'paste').length,0);
    let finishRead; a.clipboard.readText = () => new Promise(resolve => { finishRead = resolve; });
    shared.state.grant = 0;
    const reading = a.control.paste(); await flush(); right(a); shortcut(a); finishRead('public-text'); await reading;
    assert.equal(a.accepted.filter(x => x.kind === 'paste').length,2,'repeated intents do not queue extra pastes');
  }
  console.log('PASS concurrent permission intents across Panes and repeated reads do not queue'); count++;
  {
    const f = ready(); f.state.grant = -1; right(f,true); await flush();
    f.control.acceptsRemoteEffect = owner => owner === 7;
    f.emit('clipboard',0,7,'remote-write'); f.emit('reply',0,7,'remote-output'); await flush();
    assert.equal(f.state.writes,2); assert.equal(f.state.requests,0); assert.equal(f.state.reads,0);
    f.emit('paste-request',0,f.control.inputOwner-1); await flush(); assert.equal(f.state.checks,0);
    f.control.openSearch(); shortcut(f); await flush(); assert.equal(f.state.checks,0);
  }
  console.log('PASS selection, OSC52 writes, remote output and stale/search input cannot request read permission'); count++;
  for (const text of ['',null,'x'.repeat(1024*1024+1),'small']) {
    const f = ready(); f.state.text = text; f.state.readError = text === null;
    await f.control.paste();
    assert.equal(f.accepted.filter(x => x.kind === 'paste').length,text === 'small' ? 1 : 0);
    assert.equal(f.errors[0],text === null ? 'paste_failed' : text.length > 1024*1024 ? 'paste_too_large' : undefined);
  }
  console.log('PASS empty, failed and oversized clipboard text retain distinct bounded outcomes'); count++;
  {
    const f = ready(); f.state.text = 'x'.repeat(1024*1024);
    f.api.paste = () => 0;
    await f.control.paste();
    assert.equal(f.control.failed,false,'busy paste must not terminate VT or SSH');
    assert.deepEqual(f.errors,['paste_busy']);
    assert.equal(f.accepted.filter(x=>x.kind==='paste').length,0);
    f.api.paste = (_handle,text,owner) => { f.accepted.push({kind:'paste',text,owner}); return 91; };
    await f.control.paste();
    assert.equal(f.accepted.filter(x=>x.kind==='paste')[0].text.length,1024*1024);
    f.emit('copy-too-large',0,f.control.inputOwner);
    assert.equal(f.errors.at(-1),'copy_too_large');
    assert.equal(f.accepted.filter(x=>x.kind==='copy').length,0,'oversized copy preserves selection');
    f.state.text = '中'.repeat(Math.floor(1024*1024/3)+1);
    await f.control.paste();
    assert.equal(f.errors.at(-1),'paste_too_large','limit is UTF-8 bytes, not characters');
    f.control.key(2017,0,'a'); assert.equal(f.control.failed,false);
  }
  console.log('PASS bounded clipboard rejection preserves selection, session and later input'); count++;
  console.log(`${count} native terminal controller contracts passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
