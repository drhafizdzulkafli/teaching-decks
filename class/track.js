/* Records which deck/tool a logged-in Class Portal participant opens.
   Added automatically to every HTML deck by build_index.py. Does nothing for visitors who are not logged in. */
(function () {
  var C = window.CLASS_CONFIG;
  if (!C || !C.url || !C.key) return;
  var ref = C.url.replace(/^https?:\/\//, '').split('.')[0];
  var KEY = 'sb-' + ref + '-auth-token';

  function read() { try { return JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (e) { return null; } }

  function token() {
    var s = read();
    if (!s || !s.access_token) return Promise.resolve(null);
    if (!s.expires_at || s.expires_at * 1000 > Date.now() + 30000) return Promise.resolve(s.access_token);
    if (!s.refresh_token) return Promise.resolve(null);
    // Session expired: refresh it the same way the portal does, and save it back
    return fetch(C.url + '/auth/v1/token?grant_type=refresh_token', {
      method: 'POST', headers: { apikey: C.key, 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: s.refresh_token })
    }).then(function (r) { return r.ok ? r.json() : null; }).then(function (n) {
      if (!n || !n.access_token) return null;
      var latest = read();
      if (latest && latest.refresh_token !== s.refresh_token) return latest.access_token; // another tab refreshed first
      try { localStorage.setItem(KEY, JSON.stringify(Object.assign({}, s, n))); } catch (e) {}
      return n.access_token;
    }).catch(function () { return null; });
  }

  window.classTrack = function (path, title) {
    token().then(function (t) {
      if (!t) return;
      fetch(C.url + '/rest/v1/activity', {
        method: 'POST', keepalive: true,
        headers: { apikey: C.key, Authorization: 'Bearer ' + t, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
        body: JSON.stringify({ path: String(path).slice(0, 490), title: String(title || '').slice(0, 290) })
      }).catch(function () {});
    });
  };

  if (!window.CLASS_TRACK_MANUAL) {
    var p = location.pathname;
    try { p = decodeURIComponent(p); } catch (e) {}
    var i = p.indexOf('/decks/');
    window.classTrack(i >= 0 ? p.slice(i + 1) : p, document.title);
  }
})();
