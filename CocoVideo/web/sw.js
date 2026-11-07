var CACHE = 'coco-web-v1';
self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) {
    return c.addAll(['./', './index.html', './css/app.css', './js/app.js', './icon-192.png']);
  }));
  self.skipWaiting();
});
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function (e) {
  var u = e.request.url;
  if (e.request.method !== 'GET' || u.indexOf('/api.php') > -1 || u.indexOf('/index.php') > -1 || u.indexOf('/admin') > -1) return;
  e.respondWith(caches.match(e.request).then(function (r) {
    return r || fetch(e.request).then(function (res) {
      var cp = res.clone();
      caches.open(CACHE).then(function (c) { c.put(e.request, cp); });
      return res;
    });
  }).catch(function () { return caches.match('./index.html'); }));
});