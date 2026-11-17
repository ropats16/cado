// Slow mascot loop; reduced-motion users see a static idle pose.
(function () {
  const mascot = document.querySelector(".mascot-cycle");
  const reduced = matchMedia("(prefers-reduced-motion: reduce)");
  const states = ["idle", "listening", "thinking", "done"],
    durations = [5000, 4000, 3000, 4000];
  let index = 0,
    timer;
  function schedule() {
    clearTimeout(timer);
    if (reduced.matches || document.hidden) return;
    timer = setTimeout(() => {
      index = (index + 1) % states.length;
      mascot.dataset.state = states[index];
      schedule();
    }, durations[index]);
  }
  function sync() {
    clearTimeout(timer);
    mascot.dataset.paused = String(document.hidden || reduced.matches);
    if (reduced.matches) {
      index = 0;
      mascot.dataset.state = "idle";
    }
    schedule();
  }
  reduced.addEventListener("change", sync);
  document.addEventListener("visibilitychange", sync);
  sync();
})();
(function () {
  // Copy button for the brew command.
  var copy = document.getElementById("copy");
  if (copy && navigator.clipboard) {
    copy.hidden = false;
    copy.addEventListener("click", function () {
      navigator.clipboard
        .writeText(document.getElementById("brew").textContent)
        .then(
          function () {
            copy.textContent = "Copied";
            setTimeout(function () {
              copy.textContent = "Copy";
            }, 1800);
          },
          function () {
            copy.textContent = "Select command";
            var range = document.createRange();
            range.selectNodeContents(document.getElementById("brew"));
            var selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
          },
        );
    });
  }

  // Reviews: shown only when the list has entries.
  var list = [];
  try {
    list = JSON.parse(document.getElementById("quotes-data").textContent) || [];
  } catch (e) {}
  if (list.length) {
    var box = document.getElementById("quotes");
    list.forEach(function (q) {
      var f = document.createElement("figure"),
        b = document.createElement("blockquote"),
        c = document.createElement("figcaption");
      b.textContent = q.text;
      c.textContent = q.name || "";
      if (q.link && /^https:\/\//.test(q.link)) {
        var a = document.createElement("a");
        a.href = q.link;
        a.textContent = " (source)";
        c.appendChild(a);
      }
      f.appendChild(b);
      f.appendChild(c);
      box.appendChild(f);
    });
    document.getElementById("reviews").hidden = false;
    document.getElementById("nav-reviews").hidden = false;
  }
})();
