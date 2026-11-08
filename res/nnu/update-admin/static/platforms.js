'use strict';
const platformLabels = {'android-arm64':'Android ARM64 APK','android-armv7':'Android ARMv7 APK','android-x64':'Android x64 APK','android-universal':'Android 通用 APK','android-aab':'Android AAB（分发用）','linux-deb':'Linux DEB','linux-rpm':'Linux RPM','linux-appimage':'Linux AppImage','linux-tar':'Linux tar.gz'};
let platformData, platformUploading = false;
function platformFiles(manifest, parent){
  for(const [kind,a] of Object.entries(manifest.artifacts)){
    const link=node('a','package');link.href=a.url;link.rel='noopener noreferrer';
    link.append(node('strong','',platformLabels[kind]),node('span','',size(a.size)));parent.append(link);
  }
}
function platformPublish(manifest){
  confirmAction('发布多平台版本',`发布 ${manifest.version}（${manifest.build}）。${manifest.windows?'Windows 安装版将按客户端更新设置自动更新；':''}Android/Linux 可在线检查和下载。${overview.paused?'当前暂停推送，发布后仍暂停。':''}`,'发布此版本',async()=>{
    const result=await api(`/platforms/publish/${manifest.build}`,{});$('platform-dialog').close();await load();toast(result.cleanup?.failed?.length?'已发布，部分旧包清理失败，请查看操作记录':'多平台版本已发布');
  });
}
function platformPreview(row){
  const m=row.manifest, area=$('platform-preview');area.replaceChildren();
  area.append(node('h3','',m.version),node('p','fine',`Build ${m.build} · 签名及 SHA-256 已验证${m.windows?' · 含 Windows 更新包':''}`),node('p','notes',m.notes));
  const files=node('div','packages');platformFiles(m,files);area.append(files);
  if(row.pending){const publish=node('button','primary','发布此版本');publish.onclick=()=>platformPublish(m);area.append(publish);}
  $('platform-dialog').showModal();
}
async function loadPlatformPackages(){
  try{
    platformData=await api('/platforms');text($('platform-error'),'');$('platform-current').replaceChildren();$('platform-history').replaceChildren();
    for(const group of ['android','linux']){
      const row=platformData.releases.find(r=>r.manifest.build===platformData.current[group]),card=node('div','platform-card');
      card.append(node('h3','',group==='android'?'Android':'Linux x64'));
      if(row){const m=row.manifest;card.append(node('p','platform-version',m.version),node('p','fine',`Build ${m.build} · ${date(row.published)}`));const links=node('div','packages');platformFiles({...m,artifacts:Object.fromEntries(Object.entries(m.artifacts).filter(([key])=>key.startsWith(group+'-')))},links);card.append(links);}
      else card.append(node('p','muted','尚未登记版本，请导入多平台发布包。'));
      $('platform-current').append(card);
    }
    for(const row of platformData.releases){
      const m=row.manifest,item=node('div','platform-row'),copy=node('div');
      copy.append(node('strong','',m.version),node('p','fine',`Build ${m.build} · ${row.pending?'待发布':Object.values(platformData.current).includes(m.build)?'当前版本':'历史版本'} · ${date(row.imported)}`));
      const actions=node('div','platform-actions'),view=node('button','text-button','查看');view.onclick=()=>platformPreview(row);actions.append(view);
      const download=node('a','text-button','下载发布包');download.href=API+`/platforms/bundle/${m.build}`;actions.append(download);
      if(row.pending){const publish=node('button','text-button','发布');publish.onclick=()=>platformPublish(m);actions.append(publish);const discard=node('button','text-button','移除待发布包');discard.onclick=()=>confirmAction('永久移除待发布包',`删除 ${m.version} 的服务器暂存文件和待发布记录；已发布版本保持可用。`,'永久移除',async()=>{await api(`/platforms/discard/${m.build}`,{});await load();toast('待发布包已移除');});actions.append(discard);}
      item.append(copy,actions);$('platform-history').append(item);
    }
    if(!platformData.releases.length)$('platform-history').append(node('p','muted','暂无多平台版本记录。'));
  }catch(error){text($('platform-error'),error.message);}
}
$('platform-import').onclick=()=>{if(platformUploading)return;$('platform-file').value='';$('platform-preview').replaceChildren();text($('platform-dialog-error'),'');text($('platform-upload-status'),'');$('platform-progress').hidden=true;$('platform-dialog').showModal();};
$('platform-close').onclick=()=>{if(!platformUploading)$('platform-dialog').close();};
$('platform-dialog').addEventListener('cancel',e=>{if(platformUploading)e.preventDefault();});
$('platform-file').onchange=async event=>{
  const file=event.target.files[0];if(!file||platformUploading)return;
  if(!file.name.toLowerCase().endsWith('.zip')||file.size>2100*1024**2){text($('platform-dialog-error'),'请选择不超过 2.05 GB 的 ZIP 发布包');return;}
  platformUploading=true;$('platform-file').disabled=true;$('platform-close').disabled=true;$('platform-progress').hidden=false;$('platform-progress').value=0;$('platform-preview').replaceChildren();text($('platform-dialog-error'),'');text($('platform-upload-status'),'正在上传…');
  try{
    const result=await new Promise((resolve,reject)=>{
      const xhr=new XMLHttpRequest();xhr.open('POST',API+'/platforms/import');xhr.timeout=1800000;xhr.setRequestHeader('Content-Type','application/zip');xhr.setRequestHeader('X-CSRF-Token',csrf);
      xhr.upload.onprogress=e=>{if(e.lengthComputable){const p=Math.round(e.loaded/e.total*100);$('platform-progress').value=p;text($('platform-upload-status'),p<100?`正在上传 ${p}%`:'正在验证签名和文件，请稍候…');if(p===100)$('platform-progress').removeAttribute('value');}};
      xhr.onload=()=>{try{const r=JSON.parse(xhr.responseText);xhr.status>=200&&xhr.status<300?resolve(r):reject(new Error(r.error||'导入失败'));}catch{reject(new Error('服务器响应异常，请刷新重试'));}};xhr.onerror=()=>reject(new Error('网络中断，请重新上传'));xhr.ontimeout=()=>reject(new Error('上传超时，请重试'));xhr.send(file);
    });
    await load();text($('platform-upload-status'),'验证通过，可发布此版本。');$('platform-dialog').close();platformPreview({manifest:result.manifest,pending:platformData.releases.find(r=>r.manifest.build===result.manifest.build)?.pending});
  }catch(error){text($('platform-dialog-error'),error.message);text($('platform-upload-status'),'上传未完成');}
  finally{platformUploading=false;$('platform-file').disabled=false;$('platform-close').disabled=false;$('platform-progress').hidden=true;}
};
