// منصة متابعات المنار — عامل الخدمة: استقبال الإشعارات وفتح الطلب عند الضغط
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('push',e=>{
  let d={};try{d=e.data?e.data.json():{}}catch(_){d={title:'منصة متابعات المنار',body:e.data?e.data.text():''}}
  const url=new URL(d.url||'./',self.registration.scope).href;
  e.waitUntil(self.registration.showNotification(d.title||'منصة متابعات المنار',{body:d.body||'',tag:d.tag,renotify:!!d.tag,dir:'rtl',lang:'ar',icon:'icon-192.png',badge:'icon-192.png',data:url}));
});
self.addEventListener('notificationclick',e=>{e.notification.close();const u=e.notification.data||'./';
  e.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(cs=>{for(const c of cs){if('focus' in c){if(c.navigate)c.navigate(u);return c.focus()}}return self.clients.openWindow(u)}))});
