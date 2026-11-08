'use strict';
const el=id=>document.getElementById(id);
const formats={install:['Windows 安装版 EXE','推荐日常使用。安装后可按客户端设置检查并安装更新。'],portable:['Windows 便携版 EXE','无需安装。适合临时远程支持，下载后手动运行。'],msi:['Windows MSI 安装包','适合由管理员统一部署的电脑。'],zip:['Windows ZIP 文件夹版','解压到独立目录后运行。'],'android-arm64':['Android ARM64 APK','多数较新的安卓手机适用。'],'android-universal':['Android 通用 APK','不确定设备架构时选此版本，体积较大。'],'android-armv7':['Android ARMv7 APK','适合较旧的 32 位安卓设备。'],'android-x64':['Android x64 APK','仅适合 x86_64 安卓设备。'],'android-aab':['Android AAB 分发包','供应用分发使用，不能直接点击安装。'],'linux-deb':['Linux DEB','适合 Debian / Ubuntu，需 glibc 2.35 或更新版本。'],'linux-rpm':['Linux RPM','适合 RPM 系发行版，需相应图形和音频环境。'],'linux-appimage':['Linux AppImage','便携分发方式，运行前需允许文件执行。'],'linux-tar':['Linux tar.gz','解压后按自己的系统环境运行。']};
const platforms={windows:['Windows x64','适合日常远程支持的安装版，安装后可自动检查更新。','install'],android:['Android','选择与你的手机或平板匹配的 APK，安装由系统确认。','android-arm64'],linux:['Linux x64','按发行版选择格式，下载后由你确认安装。','linux-deb']};
let data,selected='windows',artifact,widgetId,pollTimer,joining=false,queueState='none',captchaLoaded=false;
const put=(id,value)=>{if(el(id).textContent!==String(value))el(id).textContent=value;};
window.turnstileReady=()=>{captchaLoaded=true;if(el('download-dialog').open)renderCaptcha();};
const bytes=n=>`${(n/1024**2).toFixed(1)} MB`;
async function api(path,body){
 const response=await fetch('/downloads/api/'+path,{method:body===undefined?'GET':'POST',headers:body===undefined?{}:{'Content-Type':'application/json','X-Download-Token':data.csrf},body:body===undefined?undefined:JSON.stringify(body)});
 const result=await response.json();if(!response.ok)throw new Error(result.error||'请求未完成，请稍后重试');return result;
}
function updatePackage(){
 artifact=data.packages.find(a=>a.id===el('package-select').value);
 if(!artifact){el('download-button').disabled=true;put('download-label','此平台暂未发布');return;}
 put('version',artifact.version);put('file-size',bytes(artifact.size));
 el('download-button').disabled=!data.ready;put('download-label',data.ready?'下载':'暂不可下载');
 el('availability').hidden=data.ready;put('availability',data.ready?'':'下载暂未开放，请稍后再试。');
}
function choosePlatform(platform,animate=false){
 const previous=selected;selected=platform;for(const button of document.querySelectorAll('[data-platform]'))button.setAttribute('aria-pressed',String(button.dataset.platform===platform));
 el('package-choice').hidden=platform==='ios';el('download-button').hidden=platform==='ios';el('ios-download').hidden=platform!=='ios';el('file-size').hidden=platform==='ios';el('version').hidden=platform==='ios';el('availability').hidden=true;
 if(platform==='ios'){artifact=null;put('platform-label','iPhone / iPad');}else{
 put('platform-label',platforms[platform][0]);
 const options=data.packages.filter(a=>a.platform===platform).sort((a,b)=>(a.kind===platforms[platform][2]?-1:b.kind===platforms[platform][2]?1:0));
 el('package-select').replaceChildren(...options.map(a=>{const option=document.createElement('option');option.value=a.id;option.textContent=formats[a.kind]?.[0]||a.name;return option;}));
 el('package-select').disabled=!options.length;updatePackage();
 }
 if(animate&&platform!==previous&&window.matchMedia('(prefers-reduced-motion: no-preference)').matches){
  const panel=el('package-panel');for(const animation of panel.getAnimations())animation.cancel();
  const direction=['windows','android','linux','ios'].indexOf(platform)>['windows','android','linux','ios'].indexOf(previous)?1:-1;
  panel.animate([{opacity:.35,transform:`translateY(${direction*9}px)`},{opacity:1,transform:'translateY(0)'}],{duration:190,easing:'cubic-bezier(0.23,1,0.32,1)'});
 }
}
function renderCaptcha(){
 if(!data?.ready||!captchaLoaded||!window.turnstile){if(data?.ready)put('dialog-error','安全验证正在加载；若长时间无响应，请检查网络后重新验证。');return;}
 if(widgetId!==undefined)window.turnstile.remove(widgetId);
 put('dialog-error','');put('dialog-status','正在验证…');el('captcha').hidden=false;el('retry-verification').hidden=false;
 widgetId=window.turnstile.render('#captcha',{sitekey:data.site_key,action:'software_download',theme:'light',size:'flexible',retry:'never','refresh-expired':'manual','refresh-timeout':'manual','timeout-callback':()=>{put('dialog-error','安全验证超时，请重新验证。');el('retry-verification').hidden=false;},callback:joinQueue,'expired-callback':()=>{put('dialog-error','安全验证已过期，请重新验证。');el('retry-verification').hidden=false;},'error-callback':code=>{put('dialog-error',String(code)==='110200'?'当前域名尚未获得验证服务授权，请联系管理员。':'安全验证未完成，请重试或检查网络。');el('retry-verification').hidden=false;return true;}});
}
function stopPolling(){clearTimeout(pollTimer);pollTimer=null;}
async function poll(){
 if(!el('download-dialog').open)return;
 try{showState(await api('status'));}catch(error){put('dialog-error',error.message);}
 if(el('download-dialog').open&&['waiting','ready','active'].includes(queueState))pollTimer=setTimeout(poll,2500);
}
function showState(state){

 if(queueState!==state.status){
  el('start-download').hidden=state.status!=='ready';el('retry-verification').hidden=['waiting','ready','active'].includes(state.status);
  el('cancel-download').hidden=state.status==='active';el('captcha').hidden=['waiting','ready','active','completed'].includes(state.status);
  if(['waiting','ready','active','completed'].includes(state.status)&&widgetId!==undefined){window.turnstile.remove(widgetId);widgetId=undefined;}
 }
 queueState=state.status;
 if(state.status==='waiting')put('dialog-status',`排队中，前面还有 ${Math.max(0,state.position-1)} 人。`);
 else if(state.status==='ready'){put('dialog-status',`请在 ${Math.max(1,Math.ceil(state.expires-Date.now()/1000))} 秒内开始下载。`);if(el('start-download').getAttribute('href')!==state.download)el('start-download').href=state.download;}
 else if(state.status==='active')put('dialog-status','下载中…');
 else if(state.status==='completed'){put('dialog-status','下载完成。');el('retry-verification').hidden=true;put('cancel-download','关闭');}
 else put('dialog-status','下载已过期或中断，请重试。');
}
async function joinQueue(token){
 if(joining||!el('download-dialog').open)return;joining=true;put('dialog-error','');put('dialog-status','正在核验请求…');
 try{showState(await api('join',{artifact:artifact.id,token}));stopPolling();pollTimer=setTimeout(poll,1500);}
 catch(error){put('dialog-error',error.message);put('dialog-status','请重新验证。');el('retry-verification').hidden=false;}
 finally{joining=false;}
}
async function openDownload(value){
 if(!data.ready)return;
 artifact=value;queueState='none';stopPolling();put('selected-name',`${formats[artifact.kind]?.[0]||'源码'} · ${bytes(artifact.size)}`);put('dialog-status','正在验证…');put('dialog-error','');put('cancel-download','取消');el('cancel-download').hidden=false;el('start-download').hidden=true;el('retry-verification').hidden=true;el('download-dialog').showModal();
 try{const state=await api('status');if(['waiting','ready','active'].includes(state.status)){showState(state);pollTimer=setTimeout(poll,2500);return;}renderCaptcha();}catch(error){put('dialog-error',error.message);el('retry-verification').hidden=false;}
}
async function closeDialog(){
 if(joining)return;
 try{if(['waiting','ready'].includes(queueState))await api('cancel',{});el('download-dialog').close();stopPolling();if(widgetId!==undefined){window.turnstile.remove(widgetId);widgetId=undefined;}}
 catch(error){put('dialog-error',error.message);}
}
el('download-button').onclick=()=>artifact&&openDownload(artifact);
el('package-select').onchange=updatePackage;
el('dialog-close').onclick=closeDialog;el('cancel-download').onclick=closeDialog;
el('download-dialog').addEventListener('cancel',event=>{event.preventDefault();closeDialog();});
el('start-download').onclick=()=>{el('start-download').hidden=true;put('dialog-status','正在开始下载…');};
el('retry-verification').onclick=()=>{queueState='none';put('dialog-status','请重新完成安全验证。');renderCaptcha();};
for(const button of document.querySelectorAll('[data-platform]'))button.onclick=event=>data&&choosePlatform(button.dataset.platform,event.detail>0);
(async()=>{try{
 data=await api('catalog');
 const platform=/iPhone|iPad|iPod/i.test(navigator.userAgent)||(/Macintosh/i.test(navigator.userAgent)&&navigator.maxTouchPoints>1)?'ios':/Android/i.test(navigator.userAgent)?'android':/Linux/i.test(navigator.userAgent)?'linux':'windows';choosePlatform(platform);
 for(const source of data.packages.filter(a=>a.platform==='source')){const button=document.createElement('button');button.type='button';button.textContent=source.kind==='source-Windows'?'Windows 源码':'跨平台源码';button.disabled=!data.ready;button.onclick=()=>openDownload(source);el('source-links').append(button);}
}catch(error){put('page-error','无法读取正式版本，请稍后刷新。'+error.message);put('download-label','暂时无法下载');}})();
