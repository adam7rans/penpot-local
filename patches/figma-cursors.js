// Penpot Local: Figma-style modifier cursors for vector editing.
//
// - Option held + hovering a bezier handle -> standalone V (break) cursor.
// - Cmd held + hovering a path anchor    -> arrow + mirror badge.
// - Cmd press-drag started on an anchor  -> arrow + bend badge until release.
// Visual only: passive listeners, never calls preventDefault/stopPropagation,
// so it cannot break the app. If this file fails to load or throws, Penpot
// behaves exactly like stock.
(function () {
  "use strict";

  var OPEN =
    "%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'" +
    " viewBox='0 0 24 24' fill='none'%3E";
  var CLOSE = "%3C/svg%3E";

  // Classic pointer arrow, tip at (5, 2).
  var ARROW =
    "%3Cpath d='M5 2L5 13L8 10.6L9.7 14.4L11.4 13.7L9.7 9.9L12.6 9.9Z'" +
    " fill='%23fff' stroke='%23000' stroke-width='1.2'" +
    " stroke-linejoin='round'/%3E";
  var BADGE =
    "%3Ccircle cx='17.5' cy='17.5' r='5.5'" +
    " fill='%23fff' stroke='%23000' stroke-width='1.2'/%3E";

  // Standalone V chevron (Option + handle). Hotspot at the apex (8, 4).
  var V_SVG =
    "%3Csvg xmlns='http://www.w3.org/2000/svg' width='16' height='16'" +
    " viewBox='0 0 16 16' fill='none'%3E" +
    "%3Cpath d='M3 12L8 3.5L13 12' stroke='%23000' stroke-width='3'" +
    " stroke-linecap='round' stroke-linejoin='round'/%3E" +
    "%3Cpath d='M3 12L8 3.5L13 12' stroke='%23fff' stroke-width='1.5'" +
    " stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E";

  // Symmetric double arrow (Cmd + anchor hover).
  var MIRROR_GLYPH =
    "%3Cpath d='M13.9 17.5H21.1M15.4 16L13.9 17.5L15.4 19" +
    "M19.6 16L21.1 17.5L19.6 19'" +
    " fill='none' stroke='%23000' stroke-width='1.3'" +
    " stroke-linecap='round' stroke-linejoin='round'/%3E";

  // Curved hook (Cmd drag). Arc with arrowhead at the upper end.
  var BEND_GLYPH =
    "%3Cpath d='M14.2 20.3A5.5 5.5 0 0 1 20.8 13.7" +
    "M20.8 13.7L18.1 14.1M20.8 13.7L20.4 16.4'" +
    " fill='none' stroke='%23000' stroke-width='1.3'" +
    " stroke-linecap='round' stroke-linejoin='round'/%3E";

  function dataUrl(svg) {
    return 'url("data:image/svg+xml,' + svg + '")';
  }
  var V_CURSOR = dataUrl(V_SVG) + " 8 4, auto";
  var MIRROR_CURSOR =
    dataUrl(OPEN + ARROW + BADGE + MIRROR_GLYPH + CLOSE) + " 5 2, auto";
  var BEND_CURSOR =
    dataUrl(OPEN + ARROW + BADGE + BEND_GLYPH + CLOSE) + " 5 2, auto";

  var mouseX = -1;
  var mouseY = -1;
  var optDown = false;
  var cmdDown = false;
  var styled = null; // circle currently carrying a hover cursor
  var dragBend = false; // Cmd-drag started on an anchor
  var rootStyled = false; // documentElement carrying BEND_CURSOR

  function unstyle() {
    if (styled) {
      styled.style.removeProperty("cursor");
      styled = null;
    }
  }

  function styleEl(el, cursor) {
    if (styled === el) return;
    unstyle();
    if (el) {
      el.style.setProperty("cursor", cursor, "important");
      styled = el;
    }
  }

  function setRoot() {
    if (!rootStyled) {
      document.documentElement.style.setProperty(
        "cursor", BEND_CURSOR, "important");
      rootStyled = true;
    }
  }

  function clearRoot() {
    if (rootStyled) {
      document.documentElement.style.removeProperty("cursor");
      rootStyled = false;
    }
  }

  // Anchor hit circle under (x, y), or null. Anchors render as g.path-point.
  function anchorAt(x, y) {
    if (x < 0 || typeof document.elementFromPoint !== "function") return null;
    var el = document.elementFromPoint(x, y);
    if (!el || typeof el.closest !== "function") return null;
    var g = el.closest("g.path-point");
    if (!g) return null;
    var c = el.closest("circle");
    return c && g.contains(c) ? c : null;
  }

  // Handle hit element under (x, y), or null. Handles render as g.handler
  // with the visible square (rect) and a larger hit-area circle.
  function handleAt(x, y) {
    if (x < 0 || typeof document.elementFromPoint !== "function") return null;
    var el = document.elementFromPoint(x, y);
    if (!el || typeof el.closest !== "function") return null;
    var g = el.closest("g.handler");
    if (!g) return null;
    var t = el.closest("circle, rect");
    return t && g.contains(t) ? t : null;
  }

  function refresh(alt, meta) {
    if (dragBend) {
      unstyle();
      setRoot();
      return;
    }
    clearRoot();
    var el = null;
    var cursor = null;
    if ((meta || cmdDown) && mouseX >= 0) {
      el = anchorAt(mouseX, mouseY);
      cursor = MIRROR_CURSOR;
    }
    if (!el && (alt || optDown) && mouseX >= 0) {
      el = handleAt(mouseX, mouseY);
      cursor = V_CURSOR;
    }
    styleEl(el, cursor);
  }

  function isAltKey(e) {
    return e.key === "Alt" || e.key === "AltGraph";
  }

  function isCmdKey(e) {
    return e.key === "Meta";
  }

  function track(e) {
    mouseX = e.clientX;
    mouseY = e.clientY;
  }

  document.addEventListener("mousemove", function (e) {
    track(e);
    refresh(e.altKey, e.metaKey);
  }, true);

  document.addEventListener("mouseover", function (e) {
    track(e);
    refresh(e.altKey, e.metaKey);
  }, true);

  document.addEventListener("mouseout", function (e) {
    if (!dragBend && styled && e.target === styled) unstyle();
  }, true);

  document.addEventListener("mousedown", function (e) {
    track(e);
    if (e.button === 0 && e.metaKey && !dragBend) {
      if (anchorAt(mouseX, mouseY)) {
        dragBend = true;
        unstyle();
        setRoot();
      }
    }
  }, true);

  document.addEventListener("mouseup", function (e) {
    if (dragBend) {
      dragBend = false;
      clearRoot();
    }
    track(e);
    refresh(e.altKey, e.metaKey);
  }, true);

  // Pointer may rest on a target while a modifier is pressed/released.
  document.addEventListener("keydown", function (e) {
    if (isAltKey(e)) {
      optDown = true;
    } else if (isCmdKey(e)) {
      cmdDown = true;
    } else {
      return;
    }
    refresh(optDown, cmdDown);
  }, true);

  document.addEventListener("keyup", function (e) {
    if (isAltKey(e)) {
      optDown = false;
    } else if (isCmdKey(e)) {
      cmdDown = false;
    } else {
      return;
    }
    refresh(optDown, cmdDown);
  }, true);

  window.addEventListener("blur", function () {
    optDown = false;
    cmdDown = false;
    dragBend = false;
    clearRoot();
    unstyle();
  });
})();
