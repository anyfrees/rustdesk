(() => {
  'use strict';
  let loadedToken='', loading=false;
  const cardId='nnu-mobile-import';
  const token=()=>{try{return localStorage.getItem('access_token')||'';}catch{return '';}};
  const home=()=>['','/'].includes(location.hash.slice(1).split('?')[0]);
  function remove(){const card=document.getElementById(cardId);if(card){card.querySelector('input').value='';card.remove();}}
  async function refresh(force=false){
    const current=token(), anchor=document.querySelector('.app-main .info-form')?.closest('.el-card');
    if(!home()||!current){remove();loadedToken='';return;}
    if(!anchor||loading||(!force&&loadedToken===current))return;
    loading=true;
    try{
      const response=await fetch('/downloads/api/mobile-import',{headers:{'api-token':current},cache:'no-store'});
      if(current!==token()||!home())return;
      loadedToken=current;
      if(!response.ok){remove();return;}
      const result=await response.json();
      if(typeof result.code!=='string'||!result.code)return;
      remove();
      const card=document.createElement('section');card.id=cardId;card.className='nnu-mobile-import';card.setAttribute('aria-labelledby','nnu-mobile-title');
      card.innerHTML='<h2 id="nnu-mobile-title">手机端快速导入</h2><div class="nnu-import-row"><input id="nnu-mobile-code" aria-label="手机端配置码，点击复制" readonly spellcheck="false" autocapitalize="off" autocomplete="off"><button type="button" class="nnu-copy-code"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="8" y="8" width="12" height="13" rx="2"/><path d="M15 8V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h3"/></svg><span>复制配置码</span></button></div><p class="nnu-import-status" role="status" aria-live="polite"></p>';
      const input=card.querySelector('input'), button=card.querySelector('button'), status=card.querySelector('[role=status]');input.value=result.code;
      const copy=async()=>{
        try{
          if(navigator.clipboard?.writeText)await navigator.clipboard.writeText(input.value);
          else{input.focus();input.select();input.setSelectionRange(0,input.value.length);if(!document.execCommand('copy'))throw new Error('copy');}
          status.textContent='已复制';
        }catch{input.focus();input.select();input.setSelectionRange(0,input.value.length);status.textContent='请长按或手动复制';}
      };
      button.onclick=copy;input.onclick=copy;anchor.insertAdjacentElement('afterend',card);
    }catch{loadedToken='';}
    finally{loading=false;}
  }
  window.addEventListener('hashchange',()=>{remove();loadedToken='';refresh();});
  window.addEventListener('storage',event=>{if(event.key==='access_token'){remove();loadedToken='';refresh();}});
  window.addEventListener('focus',()=>refresh(true));
  new MutationObserver(()=>refresh()).observe(document.getElementById('app')||document.body,{childList:true,subtree:true});
  refresh();
})();
