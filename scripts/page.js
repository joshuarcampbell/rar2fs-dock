// The status page's script (status-page puts it into the page itself).
// It shows times in the viewer's own time zone, and keeps the page live: every few
// seconds it fetches a fresh copy of the page and swaps in the parts that changed.
(function () {
  var EVERY = 5000;                       // milliseconds between looks
  var main = document.querySelector('main');
  var lost = document.getElementById('lost');

  function times(root) {
    root.querySelectorAll('time[data-t]').forEach(function (t) {
      var d = new Date(t.dataset.t * 1000);
      if (!isNaN(d)) { t.textContent = d.toLocaleString(); t.dateTime = d.toISOString(); }
    });
  }

  // what each part looked like when it arrived, before the times were filled in
  var seen = Array.prototype.map.call(main.children, function (c) { return c.outerHTML; });
  times(main);
  if (!window.fetch || !window.DOMParser) return;

  var busy = false, failures = 0, last = new Date();

  function update() {
    if (busy || document.hidden) return;  // nobody is looking: don't make the container work
    busy = true;
    fetch('status.html', { cache: 'no-store' }).then(function (answer) {
      if (!answer.ok) throw new Error(answer.status);
      return answer.text();
    }).then(function (text) {
      var fresh = new DOMParser().parseFromString(text, 'text/html').querySelector('main');
      if (!fresh) throw new Error('empty');
      if (fresh.children.length !== seen.length) { location.reload(); return; }
      var parts = Array.prototype.slice.call(fresh.children);
      var using = document.activeElement;
      parts.forEach(function (part, i) {
        var html = part.outerHTML;
        if (html === seen[i]) return;
        var old = main.children[i];
        // a list that's open or a box being typed in: leave it until next time
        if (using && using !== document.body && old.contains(using)) return;
        var node = document.importNode(part, true);
        old.parentNode.replaceChild(node, old);
        times(node);
        seen[i] = html;
      });
      failures = 0; last = new Date(); lost.hidden = true;
    }).catch(function () {
      failures++;
      if (failures >= 2) {
        lost.textContent = 'Not updating: the container stopped answering. Last update ' +
          last.toLocaleTimeString() + '. Still trying...';
        lost.hidden = false;
      }
    }).then(function () { busy = false; });
  }

  setInterval(update, EVERY);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) update(); });
})();
