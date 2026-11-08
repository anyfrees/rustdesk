'use strict';
let loginChallengeId, loginChallengeToken = '', loginChallengeScript;
function clearLoginChallenge(){
  if(loginChallengeId!==undefined && window.turnstile)window.turnstile.remove(loginChallengeId);
  loginChallengeId=undefined;loginChallengeToken='';
}
async function refreshLoginProtection(reset=false){
  if(reset)clearLoginChallenge();
  const response=await fetch(API+'/login-protection',{cache:'no-store'});
  if(!response.ok)throw new Error('无法获取登录保护状态，请稍后重试。');
  const protection=await response.json();
  $('login-protection').hidden=!protection.required;
  if(!protection.required){clearLoginChallenge();return protection;}
  text($('login-protection-status'),protection.configured?'登录失败次数较多，请先完成安全验证。':'安全验证尚未配置，请使用 Passkey 或稍后重试。');
  if(!protection.configured)return protection;
  if(!window.turnstile){
    if(!loginChallengeScript)loginChallengeScript=new Promise((resolve,reject)=>{
      const script=document.createElement('script');script.src='https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';script.async=true;
      script.onload=resolve;script.onerror=()=>{script.remove();loginChallengeScript=undefined;reject(new Error('安全验证加载失败，请检查网络后重新验证。'));};document.head.append(script);
    });
    await loginChallengeScript;
  }
  if($('login-view').hidden)return protection;
  if(loginChallengeId===undefined)loginChallengeId=window.turnstile.render($('login-challenge'),{
    sitekey:protection.site_key,action:'admin_login',theme:'light',size:'flexible',retry:'never','refresh-expired':'manual','refresh-timeout':'manual',
    'timeout-callback':()=>{loginChallengeToken='';text($('login-protection-status'),'安全验证超时，请重新验证。');$('login-challenge-retry').hidden=false;},
    callback:token=>{loginChallengeToken=token;text($('login-protection-status'),'安全验证通过，可以登录。');$('login-challenge-retry').hidden=true;},
    'expired-callback':()=>{loginChallengeToken='';text($('login-protection-status'),'验证已过期，请重新验证。');$('login-challenge-retry').hidden=false;},
    'error-callback':()=>{loginChallengeToken='';text($('login-protection-status'),'安全验证暂不可用，请重新验证或使用 Passkey。');$('login-challenge-retry').hidden=false;return true;}
  });
  return protection;
}
async function passwordLoginToken(){
  const protection=await refreshLoginProtection();
  if(protection.required&&!loginChallengeToken)throw new Error('请先完成安全验证，也可使用 Passkey 登录。');
  return loginChallengeToken;
}
$('login-challenge-retry').onclick=()=>refreshLoginProtection(true).catch(e=>text($('login-error'),e.message));
