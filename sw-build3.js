// Newberry Build 3: shows phone notifications. It does not cache anything.
self.addEventListener("install",()=>self.skipWaiting());
self.addEventListener("activate",e=>e.waitUntil(self.clients.claim()));
self.addEventListener("push",e=>{
  let d={};try{d=e.data.json()}catch{}
  e.waitUntil(self.registration.showNotification(d.title||"Newberry Build",{body:d.body||"",icon:"icons/build-192.png",badge:"icons/build-48.png",tag:"build3-"+(d.open||"update"),data:{open:d.open||""}}));
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
