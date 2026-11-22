// Newberry Fields: shows phone notifications and the number on the app icon. It does not cache the app.
self.addEventListener("install",()=>self.skipWaiting());
self.addEventListener("activate",e=>e.waitUntil(self.clients.claim()));
/* the app writes the real count of "things need you"; a push adds one until the app opens again */
const bump=async()=>{
  try{const c=await caches.open("nbf-badge"),r=await c.match("n"),n=(r?+(await r.text())||0:0)+1;await c.put("n",new Response(String(n)));return n}catch{return 1}
};
self.addEventListener("push",e=>{
  let d={};try{d=e.data.json()}catch{}
  e.waitUntil((async()=>{
    await self.registration.showNotification(d.title||"Newberry Fields",{body:d.body||"",icon:new URL("icons/fields-192.png",self.registration.scope).href,badge:new URL("icons/fields-badge-96.png",self.registration.scope).href,tag:"fields-"+(d.open||"update"),data:{open:d.open||""}});
    const n=await bump();
    try{if(self.navigator&&self.navigator.setAppBadge)await self.navigator.setAppBadge(n)}catch{}
  })());
});
self.addEventListener("notificationclick",e=>{
  e.notification.close();
  const open=(e.notification.data||{}).open||"";
  e.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(cs=>{
    const c=cs.find(x=>x.url.includes("newberry-fields"));
    if(c){c.postMessage({open});return c.focus()}
    return self.clients.openWindow(new URL("newberry-fields.html"+(open?"#open="+open:""),self.registration.scope).href);
  }));
});
