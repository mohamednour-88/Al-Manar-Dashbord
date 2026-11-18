// خرائط الإخلاء والسلامة — عامل خدمة بسيط لتمكين التثبيت (لا يخزّن البيانات مؤقتًا)
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));
self.addEventListener('fetch',()=>{});
