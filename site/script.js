// No inline handlers anywhere, because the Content-Security-Policy in _headers
// allows scripts from this origin only. A page that promises privacy should be
// able to run under a policy that strict.

(function () {
  "use strict";

  // Nothing here decides whether content is visible. The page reads correctly
  // with this file blocked, missing or broken, which for a page about not
  // having to trust software is the least it can do. Animation is CSS.

  // The masthead only grows a hairline once the page has moved, so the top of
  // the page is one uninterrupted surface.
  var masthead = document.getElementById("masthead");
  if (masthead) {
    var sync = function () {
      masthead.setAttribute("data-scrolled", window.scrollY > 8 ? "true" : "false");
    };
    sync();
    window.addEventListener("scroll", sync, { passive: true });
  }

  // Copy buttons. The label says what happened rather than only changing
  // colour, so it works without seeing the colour change.
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
