'use strict';
async function loadDownloadSettings(){
 try{const settings=await api('/download-settings');$('download-site-key').value=settings.site_key;$('download-slots').value=settings.concurrency;$('download-rate').value=settings.rate_kib;$('download-queue-size').value=settings.queue_limit;text($('download-settings-status'),settings.secret_configured?'服务端密钥已保存；请确认 Turnstile 允许 rd.nnu.cn，并实际完成一次验证。':'尚未配置服务端密钥：网页下载保持关闭，自动更新保持原流程。');}
 catch(error){text($('download-settings-error'),error.message);}
}
$('download-settings-form').onsubmit=async event=>{
 event.preventDefault();$('download-settings-save').disabled=true;text($('download-settings-error'),'');
 try{
  await api('/download-settings',{site_key:$('download-site-key').value.trim(),secret:$('download-secret').value.trim(),concurrency:Number($('download-slots').value),rate_kib:Number($('download-rate').value),queue_limit:Number($('download-queue-size').value),current_password:$('download-settings-password').value});
  $('download-secret').value='';$('download-settings-password').value='';await loadDownloadSettings();toast('下载配置已保存，未开始的旧凭证已撤销');
 }catch(error){text($('download-settings-error'),error.message);}
 finally{$('download-settings-save').disabled=false;$('download-settings-password').value='';}
};
