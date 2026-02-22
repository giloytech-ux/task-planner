const CACHE_NAME = 'planory-v62';
const APP_SHELL = [
  './',
  './index.html',
  'https://cdn.tailwindcss.com',
  'https://cdn.jsdelivr.net/npm/frappe-gantt@0.6.1/dist/frappe-gantt.min.js',
  'https://cdn.jsdelivr.net/npm/frappe-gantt@0.6.1/dist/frappe-gantt.css',
  'https://fonts.googleapis.com/icon?family=Material+Icons+Round',
  'https://cdnjs.cloudflare.com/ajax/libs/html2canvas/1.4.1/html2canvas.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(APP_SHELL))
  );
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);

  // Skip caching for Supabase API calls and Gemini API calls
  if (url.hostname.includes('supabase') || url.hostname.includes('googleapis.com/v1beta')) {
    return;
  }

  // Network-first for everything else
  e.respondWith(
    fetch(e.request)
      .then(res => {
        const clone = res.clone();
        caches.open(CACHE_NAME).then(cache => cache.put(e.request, clone));
        return res;
      })
      .catch(() => caches.match(e.request))
  );
});
