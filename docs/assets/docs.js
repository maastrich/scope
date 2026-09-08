// Scope docs — theme, mobile nav, copy buttons, table-of-contents highlighting.

(function () {
  var root = document.documentElement;

  // ---------------------------------------------------------------- theme
  try {
    var stored = localStorage.getItem("scope-docs-theme");
    if (stored === "dark" || stored === "light") root.setAttribute("data-theme", stored);
  } catch (e) { /* private window, blocked storage */ }

  var toggle = document.getElementById("theme-toggle");
  if (toggle) {
    toggle.addEventListener("click", function () {
      var dark = root.getAttribute("data-theme") === "dark" ||
        (!root.hasAttribute("data-theme") && window.matchMedia("(prefers-color-scheme: dark)").matches);
      var next = dark ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try { localStorage.setItem("scope-docs-theme", next); } catch (e) { /* ignore */ }
    });
  }

  // ------------------------------------------------------------ mobile nav
  var menu = document.getElementById("menu-toggle");
  if (menu) {
    menu.addEventListener("click", function () { document.body.classList.toggle("nav-open"); });
    document.addEventListener("click", function (event) {
      if (!document.body.classList.contains("nav-open")) return;
      var sidebar = document.getElementById("sidebar");
      if (sidebar && !sidebar.contains(event.target) && !menu.contains(event.target)) {
        document.body.classList.remove("nav-open");
      }
    });
  }

  // --------------------------------------------------------- copy buttons
  document.querySelectorAll("pre").forEach(function (pre) {
    var button = document.createElement("button");
    button.className = "copy";
    button.type = "button";
    button.textContent = "Copy";
    button.addEventListener("click", function () {
      var code = pre.querySelector("code");
      navigator.clipboard.writeText((code || pre).innerText).then(function () {
        button.textContent = "Copied";
        setTimeout(function () { button.textContent = "Copy"; }, 1400);
      }, function () { button.textContent = "Failed"; });
    });
    pre.appendChild(button);
  });

  // ------------------------------------------------------------ scrollspy
  var links = Array.prototype.slice.call(document.querySelectorAll(".toc a"));
  if (!links.length || !("IntersectionObserver" in window)) return;
  var byId = {};
  links.forEach(function (link) { byId[link.getAttribute("href").slice(1)] = link; });

  var visible = new Set();
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (entry.isIntersecting) visible.add(entry.target.id); else visible.delete(entry.target.id);
    });
    var first = null;
    Object.keys(byId).some(function (id) { if (visible.has(id)) { first = id; return true; } return false; });
    links.forEach(function (link) { link.classList.remove("active"); });
    if (first && byId[first]) byId[first].classList.add("active");
  }, { rootMargin: "-84px 0px -70% 0px" });

  Object.keys(byId).forEach(function (id) {
    var heading = document.getElementById(id);
    if (heading) observer.observe(heading);
  });
})();
