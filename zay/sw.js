// مخزون الزي — يجلب الصفحة من الشبكة دائماً حتى تظهر آخر نسخة فوراً
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('fetch',e=>{
  const r=e.request;
  if(r.mode==='navigate'||(r.method==='GET'&&new URL(r.url).pathname.endsWith('/zay/index.html'))){
    e.respondWith(fetch(r,{cache:'no-store'}).catch(()=>fetch(r)));
  }
});
