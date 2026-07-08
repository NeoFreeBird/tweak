// BHTWebXTID.js — injected into NeoFreeBird's authenticated offscreen x.com webview.
//
// Purpose: get a valid `x-client-transaction-id` for the CreateTweet rewrite (X
// rate-limits requests without one) by reusing the web client's OWN generator, so
// there are no reimplemented algorithm constants to go stale.
//
// The only hardcoded strings here are structural anchors used to LOCATE the client's
// code (the webpack global name and the transaction module's stable feature-flag +
// header strings) — not algorithm secrets.
//
// Exposes on window:
//   __bhtTransactionId(path, method) -> calls the client's own transaction-id
//       generator. `path` is the client-internal form: /graphql/<queryId>/<Operation>.
(function(){
 if(window.__bhtTransactionId)return;

 function withTimeout(p,ms){return Promise.race([p,new Promise(function(_,rej){setTimeout(function(){rej(new Error("timeout"));},ms);})]);}

 // Acquire webpack's require via the chunk-array push trick. The chunk array may not
 // exist yet when we run (bundles still loading), so we pre-create it: webpack's
 // bootstrap does `self[name]=self[name]||[]` then forEach()s existing entries, so our
 // pushed entry is processed (and our callback invoked) once the runtime installs.
 async function getWreq(){
  if(window.__bhtWreq)return window.__bhtWreq;
  var name="webpackChunk_twitter_responsive_web";
  window[name]=window[name]||[];
  var arr=window[name];
  var req=await new Promise(function(resolve,reject){
   var done=false;
   var finish=function(r){ if(!done){ done=true; resolve(r); } };
   try{ arr.push([["__bht_"+Date.now()],{},finish]); }
   catch(e){ reject(e); return; }
   setTimeout(function(){ if(!done){ done=true; reject(new Error("webpack not ready (timeout)")); } },15000);
  });
  window.__bhtWreq=req;
  return req;
 }

 // Find and call the client's transaction-id generator. The transaction module is
 // located by a stable source signature (not its per-build numeric id). Rather than
 // guess which minified export is the generator, we call EVERY function export with
 // (host, path, method) and keep whichever returns a valid token. The winning function
 // is cached on window.__bhtGen for subsequent calls.
 async function realGen(host,path,method){
  if(window.__bhtGen){ return await window.__bhtGen(host,path,method); }
  var req=await getWreq();
  if(!req||!req.m)throw new Error("no req.m");
  var keys=Object.keys(req.m);
  var cands=[];
  for(var i=0;i<keys.length;i++){
   var src;
   try{src=req.m[keys[i]].toString();}catch(e){continue;}
   if(src.indexOf("x-client-transaction-id")!==-1&&src.indexOf("rweb_client_transaction_id_enabled")!==-1){cands.push(keys[i]);}
  }
  if(cands.length===0)throw new Error("txn module not found ("+keys.length+" mods)");
  var lastErr=null;
  for(var c=0;c<cands.length;c++){
   var exp;
   try{exp=req(cands[c]);}catch(e){continue;}
   for(var k in exp){
    var f;
    try{f=exp[k];}catch(e){continue;}
    if(typeof f!=="function")continue;
    try{
     var out=await f(host,path,method);
     if(typeof out==="string"&&out.length>10){
      var dec="";try{dec=atob(out);}catch(e){}
      if(dec.slice(0,2)!=="e:"){ window.__bhtGen=f; return out; }
      lastErr="client:"+dec.slice(0,80);
     }
    }catch(e){}
   }
  }
  throw new Error(lastErr||("generator export not found (cands="+cands.length+")"));
 }

 window.__bhtTransactionId=async function(path,method){
  try{
   var t=await realGen("https://x.com",path,method);
   if(typeof t==="string"&&t.length>10){
    var dec="";try{dec=atob(t);}catch(e){}
    if(dec.slice(0,2)!=="e:")return t; // the client returns btoa("e:"+err) on failure
    return "BHTERR:client-returned-error";
   }
   return "BHTERR:gen-returned:"+String(t).slice(0,60);
  }catch(e){
   return "BHTERR:"+(((e&&e.message)?e.message:String(e))||"unknown").slice(0,120);
  }
 };
})();
