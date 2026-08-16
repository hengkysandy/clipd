// Nothing here decides whether content is visible. Block this file, or let it
// fail, and the page still reads: the hero already shows a selected card and a
// pasted snippet in the markup. This only makes the demo answer back.

(function () {
  "use strict";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------------- the demo ---------------- */

  var demo = document.getElementById("demo");
  var cards = Array.prototype.slice.call(document.querySelectorAll(".card"));
  var out = document.getElementById("outCode");
  var file = document.querySelector(".demo__file");
  var badge = document.getElementById("badge");
  var status = document.getElementById("status");
  var timer = null;
  var armTimer = null;
  var index = 0;

  function announce(text) { if (status) status.textContent = text; }

  // Types the plain text in, then puts the syntax colours back. The two
  // strings are the same glyphs, so the swap is invisible except for colour
  // arriving, which is also the order the real app works in: it takes the
  // text first and works out the language from it afterwards.
  function typeInto(text, html, then) {
    if (timer) { window.clearInterval(timer); timer = null; }
    if (reduced) { out.innerHTML = html; then(); return; }

    var frames = 34, per = Math.ceil(text.length / frames), i = 0;
    out.textContent = "";
    timer = window.setInterval(function () {
      i = Math.min(text.length, i + per);
      out.textContent = text.slice(0, i);
      if (i >= text.length) {
        window.clearInterval(timer);
        timer = null;
        out.innerHTML = html;
        then();
      }
    }, 16);
  }

  function select(next, andPaste) {
    if (!cards.length) return;
    index = (next + cards.length) % cards.length;
    cards.forEach(function (card, i) {
      card.setAttribute("aria-selected", i === index ? "true" : "false");
    });
    var card = cards[index];
    if (card.scrollIntoView) {
      card.scrollIntoView({ block: "nearest", inline: "nearest",
                            behavior: reduced ? "auto" : "smooth" });
    }
    if (andPaste) paste(card);
  }

  function paste(card) {
    var body = card.querySelector(".card__body");
    var name = card.getAttribute("data-file") || "";
    if (file) file.textContent = name;
    if (badge) badge.textContent = "pasted";
    typeInto(body.textContent, body.innerHTML, function () {
      announce("Pasted " + name);
      if (badge) badge.textContent = "try it";
    });
  }

  cards.forEach(function (card, i) {
    card.addEventListener("click", function () { select(i, true); });
    card.addEventListener("focus", function () { arm(); });
  });

  // Armed means the demo is what the number keys talk to. Hovering or
  // focusing it is enough, so the keys never fire while somebody is reading
  // further down the page.
  function arm() {
    if (!demo) return;
    demo.setAttribute("data-armed", "true");
    if (armTimer) window.clearTimeout(armTimer);
    armTimer = window.setTimeout(function () {
      demo.removeAttribute("data-armed");
    }, 6000);
  }

  if (demo) {
    demo.addEventListener("mouseenter", arm);
    demo.addEventListener("mouseleave", function () {
      if (!demo.contains(document.activeElement)) demo.removeAttribute("data-armed");
    });
  }

  function armed() {
    return demo && (demo.getAttribute("data-armed") === "true" ||
                    demo.contains(document.activeElement));
  }

  /* ---------------- keys ---------------- */

  // The page is about a keyboard shortcut, so the keys on the page press when
  // the real ones do.
  function light(key, down) {
    document.querySelectorAll('kbd[data-key="' + key + '"]').forEach(function (el) {
      if (down) el.setAttribute("data-down", "true");
      else el.removeAttribute("data-down");
    });
  }

  function typingSomewhereElse(target) {
    return target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" ||
                      target.isContentEditable);
  }

  document.addEventListener("keydown", function (e) {
    if (typingSomewhereElse(e.target)) return;

    if (e.metaKey) light("Meta", true);
    if (e.shiftKey) light("Shift", true);

    // The whole joke of the page: it answers the app's own shortcut.
    if (e.metaKey && e.shiftKey && (e.key === "v" || e.key === "V")) {
      e.preventDefault();
      light("v", true);
      if (demo) {
        demo.scrollIntoView({ block: "center", behavior: reduced ? "auto" : "smooth" });
        arm();
        cards[index].focus();
      }
      window.setTimeout(function () { light("v", false); }, 220);
      return;
    }

    if (!armed()) return;

    if (e.key >= "1" && e.key <= String(Math.min(9, cards.length))) {
      light(e.key, true);
      select(parseInt(e.key, 10) - 1, true);
      arm();
    } else if (e.key === "ArrowRight") {
      e.preventDefault(); select(index + 1, false); cards[index].focus(); arm();
    } else if (e.key === "ArrowLeft") {
      e.preventDefault(); select(index - 1, false); cards[index].focus(); arm();
    } else if (e.key === "Enter" && demo.contains(document.activeElement)) {
      e.preventDefault(); paste(cards[index]);
    } else if (e.key === "Escape") {
      demo.removeAttribute("data-armed");
      if (demo.contains(document.activeElement)) document.activeElement.blur();
    }
  });

  document.addEventListener("keyup", function (e) {
    if (!e.metaKey) light("Meta", false);
    if (!e.shiftKey) light("Shift", false);
    if (e.key >= "1" && e.key <= "9") light(e.key, false);
    if (e.key === "v" || e.key === "V") light("v", false);
  });

  window.addEventListener("blur", function () {
    ["Meta", "Shift", "v", "1", "2", "3", "4", "5", "6"].forEach(function (k) {
      light(k, false);
    });
  });

  /* ---------------- masthead ---------------- */

  var masthead = document.getElementById("masthead");
  if (masthead) {
    var sync = function () {
      masthead.setAttribute("data-scrolled", window.scrollY > 8 ? "true" : "false");
    };
    sync();
    window.addEventListener("scroll", sync, { passive: true });
  }

  /* ---------------- copy buttons ---------------- */

  document.querySelectorAll(".copy").forEach(function (button) {
    button.addEventListener("click", function () {
      var text = button.getAttribute("data-copy") || "";
      var done = function () {
        button.textContent = "Copied";
        button.setAttribute("data-copied", "true");
        window.setTimeout(function () {
          button.textContent = "Copy";
          button.removeAttribute("data-copied");
        }, 1800);
      };
      if (navigator.clipboard && window.isSecureContext) {
        navigator.clipboard.writeText(text).then(done, function () {
          button.textContent = "Press ⌘C";
        });
      } else {
        button.textContent = "Press ⌘C";
      }
    });
  });
})();
