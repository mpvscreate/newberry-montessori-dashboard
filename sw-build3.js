// Newberry Build 3: shows phone notifications and the red badge on the app icon. It does not cache the app.
self.addEventListener("install",()=>self.skipWaiting());
self.addEventListener("activate",e=>e.waitUntil(self.clients.claim()));
/* the number on the app icon: the app writes the real count of unread updates, every push adds one */
const bump=async()=>{
  try{const c=await caches.open("b3-badge"),r=await c.match("n"),n=(r?+(await r.text())||0:0)+1;await c.put("n",new Response(String(n)));return n}catch{return 1}
};
self.addEventListener("push",e=>{
  let d={};try{d=e.data.json()}catch{}
  e.waitUntil((async()=>{
    await self.registration.showNotification(d.title||"Newberry Build",{body:d.body||"",icon:"icons/build-192.png",badge:"icons/build-48.png",tag:"build3-"+(d.open||"update"),data:{open:d.open||""}});
    const n=await bump();
    try{if(self.navigator&&self.navigator.setAppBadge)await self.navigator.setAppBadge(n)}catch{}
  })());
});
self.addEventListener("notificationclick",e=>{
  e.notification.close();
  const open=(e.notification.data||{}).open||"";
  e.waitUntil(self.clients.matchAll({type:"window",includeUncontrolled:true}).then(cs=>{
    const c=cs.find(x=>x.url.includes("newberry-build-v3"));
    if(c){c.postMessage({open});return c.focus()}
    return self.clients.openWindow(new URL("newberry-build-v3.html"+(open?"#open="+open:""),self.registration.scope).href);
  }));
});
