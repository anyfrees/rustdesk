'use strict';
const $ = id => document.getElementById(id);
const API = '/update-admin/api';
const labels = {portable:'便携版 EXE',install:'安装版 EXE',msi:'MSI 安装包',zip:'ZIP 压缩包'};
let csrf = '', overview = null, uploading = false, selectedBuild = null, toastTimer, currentUsername = '', accountBusy = false;
const text = (el, value) => { el.textContent = value ?? ''; return el; };
const node = (tag, cls, value) => { const el = document.createElement(tag); if(cls) el.className = cls; if(value !== undefined) text(el,value); return el; };
const size = bytes => bytes < 1024**3 ? `${(bytes/1024**2).toFixed(1)} MB` : `${(bytes/1024**3).toFixed(2)} GB`;
const date = timestamp => timestamp ? new Intl.DateTimeFormat('zh-CN',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(timestamp*1000)) : '—';
async function api(path, data) {
  const response = await fetch(API+path,{method:data===undefined?'GET':'POST',headers:data===undefined?{}:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:data===undefined?undefined:JSON.stringify(data)});
  const result = await response.json();
  if(!response.ok){if(response.status===401 && path!=='/login')showLogin();throw new Error(result.error||'请求失败，请重试');}
  return result;
}
function toast(message){text($('toast'),message);$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,3500);}
function showLogin(){ $('account-dialog').close();$('import-dialog').close();$('confirm-dialog').close();$('external-dialog').close();$('platform-dialog').close();$('workspace').hidden=true;$('account').hidden=true;$('login-view').hidden=false;$('loading').hidden=true;if(typeof refreshLoginProtection==='function')refreshLoginProtection(true).catch(e=>text($('login-error'),e.message)); }
async function load(){overview=await api('/overview');render();await loadAnnouncement();await loadPlatformPackages();await loadDownloadSettings();}
function render(){
  const d=overview, m=d.current;
  text($('current-version'),m?m.version:'尚未发布');
  const activeRow=d.releases.find(r=>r.manifest.build===m?.build);
  text($('current-meta'),m?`Build ${m.build}　·　${date(activeRow?.published)}`:'');
  text($('current-notes'),m?.notes||'');
  text($('push-status'),d.paused?'已暂停':'正在推送');$('push-status').classList.toggle('paused',d.paused);
  text($('push-caption'),d.paused?'已停止提供更新清单，已安装版本保持不变。':'客户端可检查并下载当前版本。');
  text($('push-button'),d.paused?'恢复推送':'暂停推送');
  $('packages').replaceChildren();
  if(m)for(const [kind,a] of Object.entries(m.artifacts)){const link=node('a','package');link.href=a.mirrors?.[0]||a.url;link.rel='noopener noreferrer';link.append(node('strong','',labels[kind]),node('span','',`${size(a.size)}${m.delivery==='external'?' · 自建网盘':''}`));$('packages').append(link);}
  $('external-open').disabled=!d.external_ready;$('external-open').title=d.external_ready?'使用自建网盘下载地址发布':'外链签名正在配置，配置完成后即可使用';
  text($('stats-caption'),!d.stats_available?'访问日志暂不可用。':d.stats_pending?'正在汇总历史日志，包含重试和分段请求。':'包含重试和分段请求，不代表安装人数。');$('chart').hidden=!d.stats_available;
  if(m?.delivery==='external')text($('stats-caption'),'仅统计服务器下载；自建网盘流量与下载次数请在网盘查看。');
  const requests=d.stats.reduce((n,s)=>n+s.requests,0), bytes=d.stats.reduce((n,s)=>n+s.bytes,0);
  text($('request-total'),d.stats_available?requests.toLocaleString():'—');text($('transfer-total'),d.stats_available?size(bytes):'—');
  const fmt=new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit'});
  const days=Array.from({length:7},(_,i)=>{const day=fmt.format(new Date(Date.now()-(6-i)*86400000));return {day,count:d.stats.filter(s=>s.day===day).reduce((n,s)=>n+s.requests,0)};});
  const max=Math.max(1,...days.map(s=>s.count));$('chart').replaceChildren();
  for(const s of days){const col=node('div','bar-column');col.title=`${s.day}：${s.count} 次`;const bar=node('div','bar');bar.style.height=`${Math.max(3,s.count/max*52)}px`;col.append(bar,node('span','',s.day.slice(5).replace('-','/')));$('chart').append(col);}
  text($('history-count'),d.releases.length);$('release-rows').replaceChildren();
  for(const r of d.releases){const m=r.manifest,tr=node('tr');tr.append(node('td','',m.version),node('td','mono',m.build),node('td','muted',date(r.imported)));const state=node('td');state.append(node('span',m.build===d.current?.build?'status':'dim',m.build===d.current?.build?'当前版本':r.pending?'待发布':'历史版本'));tr.append(state);const actions=node('td');const view=node('button','text-button','查看');view.onclick=()=>preview(r);actions.append(view);if(r.pending && m.build>(d.current?.build||0)){const publish=node('button','text-button','发布');publish.onclick=()=>publishConfirm(m.build);actions.append(publish);}if(r.pending){const remove=node('button','text-button dim','删除待发布包');remove.onclick=()=>confirmAction('永久删除待发布包',`永久删除 ${m.version} 的服务器暂存安装文件及待发布记录，不进回收站。操作日志保留，不影响本机原文件和已发布下载。`,'永久删除',async()=>{await api(`/discard/${m.build}`,{});await load();toast('待发布包已永久删除');});actions.append(remove);}tr.append(actions);$('release-rows').append(tr);}
  $('events').replaceChildren();for(const e of d.events){const li=node('li');li.append(node('time','',date(e.at)),node('span','',`${e.action}${e.build?' · '+e.build:''}`));$('events').append(li);}
}
function preview(r){const m=r.manifest;selectedBuild=m.build;uploading=false;$('upload-step').hidden=true;$('preview-step').hidden=false;text($('import-title'),m.delivery==='external'?'外部地址版本':'版本详情');text($('preview-version'),m.version);text($('preview-build'),`Build ${m.build}`);text($('preview-notes'),m.notes);$('preview-files').replaceChildren();for(const [k,a] of Object.entries(m.artifacts)){const row=node('div','preview-file');row.append(node('strong','',labels[k]),node('span','',`${size(a.size)} · SHA-256 已验证`));if(a.mirrors?.length){row.classList.add('external-preview-file');const address=node('a','fine',a.mirrors[0]);address.href=a.mirrors[0];address.rel='noopener noreferrer';row.append(address);}$('preview-files').append(row);}const eligible=m.build>(overview.current?.build||0);$('publish-button').hidden=!eligible;text($('preview-later'),eligible?'稍后发布':'关闭');text($('preview-message'),eligible?(m.delivery==='external'?'新客户端从自建网盘下载；旧客户端先获取本地兼容版。':'')+(overview.paused?'推送目前已暂停；发布后仍保持暂停。':'发布后客户端将收到此版本的更新清单。'):'此版本已发布，构建号不能回退。');text($('import-error'),'');if(!$('import-dialog').open)$('import-dialog').showModal();}
function openImport(){selectedBuild=null;$('upload-step').hidden=false;$('preview-step').hidden=true;$('upload-progress').hidden=true;$('bundle-file').value='';text($('import-title'),'导入发布包');text($('import-error'),'');$('import-dialog').showModal();}
async function upload(file){
  if(uploading||!file)return;
  if(!file.name.toLowerCase().endsWith('.zip')){text($('import-error'),'请选择 ZIP 发布包');return;}
  if(file.size>2100*1024**2){text($('import-error'),'发布包不能超过 2.05 GB');return;}
  uploading=true;$('import-close').disabled=true;$('dropzone').classList.add('busy');$('bundle-file').disabled=true;$('upload-progress').hidden=false;text($('import-error'),'');text($('upload-label'),'正在上传');text($('upload-percent'),'0%');$('progress').value=0;
  try{
    const result=await new Promise((resolve,reject)=>{const xhr=new XMLHttpRequest();xhr.open('POST',API+'/import');xhr.timeout=1800000;xhr.setRequestHeader('Content-Type','application/zip');xhr.setRequestHeader('X-CSRF-Token',csrf);xhr.upload.onprogress=e=>{if(e.lengthComputable){const p=Math.round(e.loaded/e.total*100);$('progress').value=p;text($('upload-percent'),`${p}%`);if(p===100){text($('upload-label'),'正在验签并校验安装包');$('progress').removeAttribute('value');}}};xhr.onload=()=>{try{const r=JSON.parse(xhr.responseText);xhr.status>=200&&xhr.status<300?resolve(r):reject(new Error(r.error||'导入失败'));}catch{reject(new Error('服务器响应异常，请重试'));}};xhr.onerror=()=>reject(new Error('网络中断，请重新上传'));xhr.ontimeout=()=>reject(new Error('上传超时，请重试'));xhr.send(file);});
    await load();preview({manifest:result.manifest});
  }catch(e){$('upload-progress').hidden=true;text($('import-error'),e.message);}finally{uploading=false;$('import-close').disabled=false;$('dropzone').classList.remove('busy');$('bundle-file').disabled=false;}
}
function confirmAction(title,copy,label,action){text($('confirm-title'),title);text($('confirm-copy'),copy);text($('confirm-ok'),label);text($('confirm-error'),'');$('confirm-dialog').showModal();$('confirm-cancel').focus();$('confirm-ok').onclick=async()=>{const button=$('confirm-ok');button.disabled=true;$('confirm-cancel').disabled=true;try{await action();$('confirm-dialog').close();}catch(e){text($('confirm-error'),e.message);}finally{button.disabled=false;$('confirm-cancel').disabled=false;}};}
function publishConfirm(build){const m=overview.releases.find(r=>r.manifest.build===build)?.manifest;if(!m)return;confirmAction('发布此版本',`将 ${m.version}（${build}）设为当前版本。${overview.paused?'推送保持暂停。':'客户端下次检查更新时即可获取。'}`,'确认发布',async()=>{const result=await api(`/publish/${build}`,{});$('import-dialog').close();await load();toast(result.cleanup?.failed?.length?'版本已发布，部分旧包清理失败，请查看操作记录':'版本已发布');});}
$('login-form').onsubmit=async e=>{e.preventDefault();const b=$('password-login');if(b.disabled)return;b.disabled=true;$('passkey-login').disabled=true;text($('login-error'),'');try{const token=await passwordLoginToken();const r=await api('/login',{username:$('login-user').value.trim(),password:$('login-password').value,turnstile_token:token});csrf=r.csrf;currentUsername=r.username;$('login-password').value='';clearLoginChallenge();$('login-view').hidden=true;await enter();}catch(err){showLogin();text($('login-error'),err.message);}finally{b.disabled=false;$('passkey-login').disabled=false;}};
async function enter(){await load();$('workspace').hidden=false;$('account').hidden=false;text($('username'),currentUsername||$('login-user').value||'admin');$('loading').hidden=true;}
$('logout').onclick=async()=>{try{await api('/logout',{});const s=await api('/session');csrf=s.csrf;showLogin();}catch(e){text($('page-error'),e.message);}};
$('import-open').onclick=openImport;
let externalBusy=false;
$('external-open').onclick=()=>{if(!overview?.external_ready)return;$('external-form').reset();$('external-build').value=overview.next_build;text($('external-error'),'');text($('external-status'),'');$('external-dialog').showModal();$('external-version').focus();};
$('external-close').onclick=()=>{if(!externalBusy)$('external-dialog').close();};
$('external-dialog').addEventListener('cancel',event=>{if(externalBusy)event.preventDefault();});
$('external-form').onsubmit=async event=>{
  event.preventDefault();if(externalBusy)return;
  const urls=Object.fromEntries(Object.keys(labels).map(kind=>[kind,$('external-'+kind).value.trim()]));
  for(const [kind,value] of Object.entries(urls)){try{const u=new URL(value);if(u.protocol!=='https:'||u.username||u.password||u.hash||u.port&&u.port!=='443')throw new Error();}catch{text($('external-error'),`${labels[kind]}：请填写 HTTPS 下载链接`);$('external-'+kind).focus();return;}}
  const build=Number($('external-build').value);if(!Number.isSafeInteger(build)||build<=0){text($('external-error'),'请填写有效的构建号');return;}
  externalBusy=true;$('external-submit').disabled=true;$('external-close').disabled=true;$('external-form').setAttribute('aria-busy','true');text($('external-error'),'');text($('external-status'),'正在跟随链接读取四个安装包并计算校验值，完成后进入预览。大文件可能需要几分钟。');
  try{const result=await api('/external',{build,version:$('external-version').value.trim(),notes:$('external-notes').value.trim(),urls});$('external-dialog').close();await load();preview({manifest:result.manifest});}catch(error){text($('external-error'),error.message);}finally{externalBusy=false;$('external-submit').disabled=false;$('external-close').disabled=false;$('external-form').setAttribute('aria-busy','false');text($('external-status'),'');}
};
$('import-close').onclick=()=>{if(!uploading)$('import-dialog').close();};
$('import-dialog').addEventListener('cancel',e=>{if(uploading)e.preventDefault();});
$('bundle-file').onchange=e=>upload(e.target.files[0]);
$('dropzone').ondragover=e=>{e.preventDefault();$('dropzone').classList.add('drag');};$('dropzone').ondragleave=()=>$('dropzone').classList.remove('drag');$('dropzone').ondrop=e=>{e.preventDefault();$('dropzone').classList.remove('drag');upload(e.dataTransfer.files[0]);};
$('preview-later').onclick=()=>$('import-dialog').close();$('publish-button').onclick=()=>publishConfirm(selectedBuild);
$('confirm-cancel').onclick=()=>$('confirm-dialog').close();
$('confirm-dialog').addEventListener('cancel',e=>{if($('confirm-ok').disabled)e.preventDefault();});
$('push-button').onclick=()=>{const paused=!overview.paused;confirmAction(paused?'暂停客户端推送':'恢复客户端推送',paused?'暂停后将停止返回更新清单。已安装版本不会回退，已有安装包仍可下载。客户端手动检查会显示更新服务暂不可用。':'恢复后，客户端可再次获取当前版本的更新清单。',paused?'暂停推送':'恢复推送',async()=>{await api('/push',{paused});await load();toast(paused?'已暂停推送':'已恢复推送');});};
$('refresh').onclick=async()=>{text($('page-error'),'');$('refresh').disabled=true;try{await load();toast('已刷新');}catch(e){text($('page-error'),e.message);}finally{$('refresh').disabled=false;}};
(async()=>{try{const s=await api('/session');csrf=s.csrf;if(s.authenticated){currentUsername=s.username;$('login-user').value=s.username;await enter();}else showLogin();}catch(e){$('loading').hidden=true;showLogin();text($('login-error'),e.message);}})();


const fromB64 = value => Uint8Array.from(atob(value.replace(/-/g,'+').replace(/_/g,'/')+'='.repeat((4-value.length%4)%4)),c=>c.charCodeAt(0));
const toB64 = value => btoa(String.fromCharCode(...new Uint8Array(value))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
function passkeyOptions(data, registration){
  const result={...data,challenge:fromB64(data.challenge)};
  if(registration)result.user={...data.user,id:fromB64(data.user.id)};
  for(const field of ['allowCredentials','excludeCredentials'])if(data[field])result[field]=data[field].map(c=>({...c,id:fromB64(c.id)}));
  return result;
}
function passkeyJSON(credential, registration){
  const response={clientDataJSON:toB64(credential.response.clientDataJSON)};
  if(registration){response.attestationObject=toB64(credential.response.attestationObject);response.transports=credential.response.getTransports?.()||[];}
  else{response.authenticatorData=toB64(credential.response.authenticatorData);response.signature=toB64(credential.response.signature);response.userHandle=credential.response.userHandle?toB64(credential.response.userHandle):null;}
  return {id:credential.id,rawId:toB64(credential.rawId),type:credential.type,response,clientExtensionResults:credential.getClientExtensionResults(),authenticatorAttachment:credential.authenticatorAttachment};
}
function passkeyAvailable(){return window.isSecureContext && !!window.PublicKeyCredential && !!navigator.credentials;}
function passkeyError(error){
  if(error.name==='NotAllowedError'||error.name==='AbortError')return '未完成 Passkey 验证，可重试或使用密码登录。';
  if(error.name==='InvalidStateError')return '此设备可能已添加 Passkey，请使用现有 Passkey 或其他设备。';
  if(error.name==='SecurityError')return '请通过 https://rd.nnu.cn/update-admin/ 使用 Passkey。';
  return error.message||'Passkey 操作失败，请重试。';
}
function currentPassword(){
  const input=$('account-current-password');
  if(!input.value){input.setAttribute('aria-invalid','true');input.focus();throw new Error('请先填写当前密码。');}
  input.removeAttribute('aria-invalid');return input.value;
}
function setAccountBusy(busy){accountBusy=busy;$('account-dialog').setAttribute('aria-busy',String(busy));for(const id of ['account-save','account-close','passkey-add'])$(id).disabled=busy;$('passkey-list').querySelectorAll('button').forEach(b=>b.disabled=busy);}
async function loadAccount(){
  const data=await api('/account');currentUsername=data.username;text($('username'),data.username);$('account-user').value=data.username;
  $('passkey-list').replaceChildren();
  if(!data.passkeys.length)$('passkey-list').append(node('li','muted','尚未添加 Passkey'));
  for(const key of data.passkeys){const item=node('li','passkey-item'),info=node('div');info.append(node('strong','',key.name),node('span','muted',key.last_used?`上次使用 ${date(key.last_used)}`:`添加于 ${date(key.created)}`));const remove=node('button','text-button','撤销');remove.setAttribute('aria-label',`撤销 ${key.name}`);remove.onclick=()=>{let password;try{password=currentPassword();}catch(e){text($('account-error'),e.message);return;}confirmAction('撤销 Passkey',`撤销“${key.name}”后，该 Passkey 无法继续登录，使用它登录的会话也将退出。密码登录仍可使用。`,'撤销',async()=>{const result=await api(`/passkeys/${encodeURIComponent(key.id)}/delete`,{current_password:password});password=null;$('account-current-password').value='';if(result.logged_out){const s=await api('/session');csrf=s.csrf;showLogin();}else{await loadAccount();toast('Passkey 已撤销');}});};item.append(info,remove);$('passkey-list').append(item);}
}
$('account-open').onclick=async()=>{
  text($('account-error'),'');text($('passkey-error'),'');text($('passkey-status'),'');$('account-form').reset();$('passkey-name').value='';$('account-current-password').removeAttribute('aria-invalid');$('account-new-password').removeAttribute('aria-invalid');$('account-confirm-password').removeAttribute('aria-invalid');
  try{await loadAccount();$('account-dialog').showModal();$('account-user').focus();}catch(e){text($('page-error'),e.message);}
};
$('account-close').onclick=()=>$('account-dialog').close();
$('account-dialog').addEventListener('cancel',e=>{if(accountBusy)e.preventDefault();});
$('account-dialog').addEventListener('close',()=>{$('account-current-password').value='';$('account-new-password').value='';$('account-confirm-password').value='';});
$('account-form').onsubmit=async e=>{
  e.preventDefault();if(accountBusy)return;text($('account-error'),'');
  try{const password=currentPassword(),newPassword=$('account-new-password').value;if(newPassword!==$('account-confirm-password').value){$('account-confirm-password').setAttribute('aria-invalid','true');throw new Error('两次输入的新密码不一致。');}$('account-confirm-password').removeAttribute('aria-invalid');setAccountBusy(true);const result=await api('/account',{username:$('account-user').value.trim(),new_password:newPassword,current_password:password});csrf=result.csrf;currentUsername=result.username;$('login-user').value=result.username;text($('username'),result.username);$('account-dialog').close();toast('账户已更新，其他登录会话已退出');}catch(error){text($('account-error'),error.message);}finally{setAccountBusy(false);}
};
$('passkey-add').onclick=async()=>{
  if(accountBusy)return;text($('passkey-error'),'');text($('passkey-status'),'');
  try{if(!passkeyAvailable())throw new Error('此浏览器暂不支持 Passkey，请使用支持 WebAuthn 的浏览器。');const password=currentPassword();setAccountBusy(true);const result=await api('/passkeys/register/options',{current_password:password,name:$('passkey-name').value.trim()||'Passkey'});$('account-current-password').value='';text($('passkey-status'),'请完成系统 Passkey 验证…');const credential=await navigator.credentials.create({publicKey:passkeyOptions(result.options,true)});if(!credential)throw new Error('未创建 Passkey。');await api('/passkeys/register/verify',{request_id:result.request_id,credential:passkeyJSON(credential,true)});await loadAccount();$('passkey-name').value='';text($('passkey-status'),'Passkey 已添加，下次可直接使用 Passkey 登录。');}catch(error){text($('passkey-error'),passkeyError(error));text($('passkey-status'),'');}finally{setAccountBusy(false);}
};
$('passkey-login').onclick=async()=>{
  const button=$('passkey-login');text($('login-error'),'');button.disabled=true;$('login-form').querySelector('button').disabled=true;
  try{if(!passkeyAvailable())throw new Error('此浏览器暂不支持 Passkey，请使用密码登录。');const options=await api('/passkeys/login/options',{});const credential=await navigator.credentials.get({publicKey:passkeyOptions(options.options,false)});if(!credential)throw new Error('未选择 Passkey。');const result=await api('/passkeys/login/verify',{request_id:options.request_id,credential:passkeyJSON(credential,false)});csrf=result.csrf;currentUsername=result.username;$('login-user').value=result.username;$('login-password').value='';$('login-view').hidden=true;await enter();}catch(error){showLogin();text($('login-error'),passkeyError(error));}finally{button.disabled=false;$('login-form').querySelector('button').disabled=false;}
};

let announcementRevision=0,announcementBusy=false,announcementItems=[],announcementSelected=0;
const announcementThemeLabels={clean:'清爽细栏',safety:'安全提示',capsule:'悬浮胶囊',editorial:'双层卡片',rotation:'多主题轮播',obsidian:'曜石黑',titanium:'钛金黑',glass:'液态玻璃',frosted:'磨砂材质'};
const announcementSymbols={megaphone:'◖',shield:'♢',bell:'♧',warning:'⚠',info:'ⓘ',wrench:'⚒',sparkles:'✧',calendar:'▦',support:'☏',network:'⊞',none:''};
const announcementDefaultIcons={clean:'megaphone',safety:'shield',capsule:'bell',editorial:'calendar',rotation:'info',obsidian:'bell',titanium:'sparkles',glass:'sparkles',frosted:'bell'};
function readAnnouncementEditor(){
  const item=announcementItems[announcementSelected];if(!item)return;
  Object.assign(item,{title:$('announcement-heading').value,body:$('announcement-body').value,theme:$('announcement-theme').value,icon:$('announcement-icon').value,motion:$('announcement-motion').value,enabled:$('announcement-enabled').checked});
  Object.assign(item,{title_font:$('announcement-title-font').value,title_size:Number($('announcement-title-size').value),title_weight:$('announcement-title-weight').value,title_color:$('announcement-title-auto').checked?'':$('announcement-title-color').value,icon_color:$('announcement-icon-auto').checked?'':$('announcement-icon-color').value});
}
function renderAnnouncementEditor(){
  const item=announcementItems[announcementSelected];$('announcement-editor').hidden=!item;
  if(!item)return;
  $('announcement-heading').value=item.title;$('announcement-body').value=item.body;
  $('announcement-theme').value=item.theme;$('announcement-icon').value=item.icon;$('announcement-motion').value=item.motion;$('announcement-enabled').checked=item.enabled;
  $('announcement-title-font').value=item.title_font||'auto';$('announcement-title-size').value=String(item.title_size||0);$('announcement-title-weight').value=item.title_weight||'auto';
  for(const key of ['title','icon']){$(`announcement-${key}-auto`).checked=!item[key+'_color'];$(`announcement-${key}-color`).value=item[key+'_color']||'#26785b';}
  renderAnnouncementPreview();
}
function renderAnnouncementPreview(){
  const item=announcementItems[announcementSelected];if(!item)return;
  $('announcement-preview').dataset.theme=item.theme;
  drawAnnouncementIcon(item.icon==='auto'?announcementDefaultIcons[item.theme]:item.icon);
  const title=$('announcement-preview-title'),icon=$('announcement-preview-icon');
  title.style.fontFamily={sans:'"Microsoft YaHei",sans-serif',serif:'SimSun,"Songti SC",serif',mono:'Consolas,"Microsoft YaHei",monospace'}[item.title_font]||'';
  title.style.fontSize=item.title_size?`${item.title_size}px`:'';title.style.fontWeight={normal:'400',medium:'500',bold:'700'}[item.title_weight]||'';
  const background={clean:'#f0f6ff',safety:'#fff6e6',capsule:'#213b60',editorial:'#ffffff',rotation:'#f0f6ff',obsidian:'#11151b',titanium:'#272b30',glass:'#172434',frosted:'#e6ebf0'}[item.theme];
  title.style.color=announcementReadableColor(item.title_color,background,4.5);icon.style.color=announcementReadableColor(item.icon_color,background,3);
  text($('announcement-preview-title'),item.title||'公告标题预览');text($('announcement-preview-body'),item.body||'在这里输入通知正文。主题、图标和动效可分别选择。');
}
function renderAnnouncementItems(){
  $('announcement-items').replaceChildren();text($('announcement-count'),`${announcementItems.length} / 10`);$('announcement-add').disabled=announcementBusy||announcementItems.length>=10;
  announcementItems.forEach((item,index)=>{
    const row=node('div','announcement-item');row.classList.toggle('selected',index===announcementSelected);
    const edit=node('button','announcement-item-edit',`${index+1}. ${item.title||'未命名通知'}`);edit.type='button';edit.setAttribute('aria-pressed',String(index===announcementSelected));edit.onclick=()=>{readAnnouncementEditor();announcementSelected=index;renderAnnouncementItems();renderAnnouncementEditor();};
    const state=node('span','fine',item.enabled?announcementThemeLabels[item.theme]:'不发布');
    const up=node('button','text-button','上移');up.type='button';up.disabled=index===0;up.setAttribute('aria-label',`上移第 ${index+1} 条通知`);up.onclick=()=>moveAnnouncement(index,-1);
    const down=node('button','text-button','下移');down.type='button';down.disabled=index===announcementItems.length-1;down.setAttribute('aria-label',`下移第 ${index+1} 条通知`);down.onclick=()=>moveAnnouncement(index,1);
    const remove=node('button','text-button dim','移除');remove.type='button';remove.setAttribute('aria-label',`从草稿移除第 ${index+1} 条通知`);remove.onclick=()=>{readAnnouncementEditor();announcementItems.splice(index,1);announcementSelected=Math.min(announcementSelected,Math.max(0,announcementItems.length-1));renderAnnouncementItems();renderAnnouncementEditor();};
    row.append(edit,state,up,down,remove);$('announcement-items').append(row);
  });
}
function moveAnnouncement(index,delta){readAnnouncementEditor();const item=announcementItems.splice(index,1)[0];announcementItems.splice(index+delta,0,item);announcementSelected=index+delta;renderAnnouncementItems();renderAnnouncementEditor();}
async function loadAnnouncement(){
  const d=await api('/announcement');announcementRevision=d.revision;
  announcementItems=d.items||[];announcementSelected=Math.min(announcementSelected,Math.max(0,announcementItems.length-1));
  if(![...$('announcement-interval').options].some(o=>Number(o.value)===d.interval_seconds))$('announcement-interval').append(new Option(`${d.interval_seconds} 秒`,d.interval_seconds));
  $('announcement-interval').value=String(d.interval_seconds||8);
  text($('announcement-state'),d.published?'已发布':'未发布');$('announcement-state').classList.toggle('paused',!d.published);
  $('announcement-published').hidden=!d.published;$('announcement-withdraw').hidden=!d.published;
  text($('announcement-live-title'),d.published?`已发布 ${(d.published_items||[d.published]).length} 条通知`:'');
  text($('announcement-live-body'),(d.published_items||[]).map((item,i)=>`${i+1}. ${item.title} · ${announcementThemeLabels[item.theme]||'清爽细栏'}\n${item.body}`).join('\n'));
  text($('announcement-live-date'),d.published?`发布于 ${date(d.published.published_at)} · 每 ${d.published_interval||8} 秒轮换`:'');
  renderAnnouncementItems();renderAnnouncementEditor();
}
async function announcementAction(action){
  if(announcementBusy)return;readAnnouncementEditor();announcementBusy=true;
  $('announcement-form').querySelectorAll('button,input,select,textarea').forEach(el=>el.disabled=true);
  text($('announcement-error'),'');
  try{
    if(action!=='withdraw'){
      if(action==='publish'){
        const active=announcementItems.filter(i=>i.enabled);
        if(!active.length||active.some(i=>!i.title.trim()||!i.body.trim()))throw new Error('请至少启用一条标题和正文完整的公告。');
      }
      await api('/announcement/save',{revision:announcementRevision,items:announcementItems,interval_seconds:Number($('announcement-interval').value)});announcementRevision++;
    }
    if(action!=='save')await api('/announcement/'+action,{revision:announcementRevision});
    await loadAnnouncement();toast({save:'公告草稿已保存',publish:'通知列表已发布',withdraw:'公告已撤下'}[action]);
  }catch(e){text($('announcement-error'),e.message);throw e;}
  finally{announcementBusy=false;$('announcement-form').querySelectorAll('button,input,select,textarea').forEach(el=>el.disabled=false);renderAnnouncementItems();}
}
$('announcement-add').onclick=()=>{readAnnouncementEditor();if(announcementItems.length>=10)return;announcementItems.push({id:'',title:'',body:'',theme:'clean',icon:'auto',motion:'auto',enabled:true});announcementSelected=announcementItems.length-1;renderAnnouncementItems();renderAnnouncementEditor();$('announcement-heading').focus();};
for(const id of ['announcement-heading','announcement-body','announcement-theme','announcement-icon','announcement-motion','announcement-enabled','announcement-title-font','announcement-title-size','announcement-title-weight','announcement-title-color','announcement-icon-color','announcement-title-auto','announcement-icon-auto'])$(id).addEventListener('input',()=>{if(id.endsWith('-color'))$(id.replace('-color','-auto')).checked=false;readAnnouncementEditor();renderAnnouncementPreview();});
$('announcement-appearance-reset').onclick=()=>{const item=announcementItems[announcementSelected];if(!item)return;readAnnouncementEditor();Object.assign(item,{title_font:'auto',title_size:0,title_weight:'auto',title_color:'',icon_color:''});renderAnnouncementEditor();};
function announcementReadableColor(value,background,minimum){
  if(!/^#[0-9a-f]{6}$/i.test(value||''))return '';
  const luminance=color=>{const parts=[1,3,5].map(i=>parseInt(color.slice(i,i+2),16)/255).map(v=>v<=.04045?v/12.92:((v+.055)/1.055)**2.4);return parts[0]*.2126+parts[1]*.7152+parts[2]*.0722;};
  const a=luminance(value),b=luminance(background);return (Math.max(a,b)+.05)/(Math.min(a,b)+.05)>=minimum?value:b>.179?'#000000':'#ffffff';
}
$('announcement-form').onsubmit=e=>{e.preventDefault();announcementAction('save').catch(()=>{});};
$('announcement-publish').onclick=()=>{readAnnouncementEditor();confirmAction('发布客户端通知',`将按当前顺序发布 ${announcementItems.filter(i=>i.enabled).length} 条已启用通知，替换原公告列表。旧客户端仍显示第一条。`,'确认发布',()=>announcementAction('publish'));};
$('announcement-withdraw').onclick=()=>confirmAction('撤下全部公告','客户端下次同步后收起消息栏，草稿仍然保留。','撤下公告',()=>announcementAction('withdraw'));

function playAnnouncementPreview(){
  const item=announcementItems[announcementSelected];if(!item)return;
  const element=$('announcement-preview');element.dataset.effect='none';
  const motion=item.motion==='auto'?(['safety','glass'].includes(item.theme)?'breathe':'fade'):item.motion;
  if(matchMedia('(prefers-reduced-motion: reduce)').matches||motion==='none')return;
  void element.offsetWidth;element.dataset.effect=motion;
}
$('announcement-preview-replay').onclick=playAnnouncementPreview;
$('announcement-motion').addEventListener('change',playAnnouncementPreview);

function drawAnnouncementIcon(name){
  const paths={
    megaphone:'M3 10v5h5l11 5V4L8 10H3m5 5 2 6h3l-2-5',
    shield:'M12 3 20 6v6c0 5-8 9-8 9s-8-4-8-9V6Zm-4 9 3 3 5-6',
    bell:'M6 9a6 6 0 0 1 12 0v6l2 3H4l2-3Zm4 12h4',
    warning:'M12 3 2 21h20ZM12 9v5m0 3v1',
    info:'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0M12 10v7m0-10v1',
    wrench:'M14 5a6 6 0 0 0-7 8l-4 5a2 2 0 0 0 3 3l5-5a6 6 0 0 0 8-7l-4 4-4-4Z',
    sparkles:'m12 2 3 7 7 3-7 3-3 7-3-7-7-3 7-3ZM21 2v4m-2-2h4',
    calendar:'M4 5h16v16H4Zm3-3v6m10-6v6M4 10h16M8 14h2m4 0h2m-8 3h2',
    support:'M4 14v-3a8 8 0 0 1 16 0v3M4 12H2v6h4v-6Zm16 0h2v6h-4v-6Zm0 6v3h-7',
    network:'M9 3h6v6H9ZM3 16h6v6H3Zm12 0h6v6h-6ZM12 9v4M6 16v-3h12v3'
  };
  const holder=$('announcement-preview-icon');holder.replaceChildren();if(!paths[name])return;
  const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg'),path=document.createElementNS(ns,'path');
  for(const [key,value] of Object.entries({viewBox:'0 0 24 24',width:'24',height:'24',fill:'none',stroke:'currentColor','stroke-width':'1.7','stroke-linejoin':'round','stroke-linecap':'round','aria-hidden':'true'}))svg.setAttribute(key,value);
  path.setAttribute('d',paths[name]);svg.append(path);holder.append(svg);
}
