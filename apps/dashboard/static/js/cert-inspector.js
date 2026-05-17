// Lucairn Enterprise Dashboard — cert inspector + bulk-progress
// client-side glue. Loaded as a deferred <script> after alpine.min.js;
// registers one Alpine component used by the progress template.
//
// Design constraints (Slice 3):
//   - No external CDN at runtime (local woff2 stance carries over).
//   - One Alpine component per surface; no global state shared between
//     pages. The click-to-reveal flow in signature_pill uses inline
//     x-data with no helper here — the partial owns its own state.
//   - JSON poll cadence: 1s. The witness side of bulk verify is rate-
//     limited to 10 RPC/s; polling more aggressively would create more
//     network than helpful UI movement.
//   - Finishes the poll loop on the server's `finished: true` flag,
//     not on `done === total`. The server-side write order makes
//     finished the authoritative "no more updates coming" signal.
//
// No emojis. No animations beyond the bar's natural width transition
// (controlled in CSS via lc-progress-bar transition rule). No
// auto-redirect on finish — operator stays on the page and can read
// the summary at their own pace.

(function () {
  "use strict";

  if (typeof window === "undefined") {
    return;
  }

  function bulkProgress(total, progressURL) {
    return {
      total: total || 0,
      done: 0,
      verified: 0,
      partial: 0,
      failed: 0,
      finished: false,
      timer: null,
      start: function () {
        var self = this;
        var tick = function () {
          fetch(progressURL, { credentials: "same-origin", cache: "no-store" })
            .then(function (resp) {
              if (!resp.ok) {
                return null;
              }
              return resp.json();
            })
            .then(function (body) {
              if (!body) {
                return;
              }
              self.total = body.total || self.total;
              self.done = body.done || 0;
              self.verified = body.verified || 0;
              self.partial = body.partial || 0;
              self.failed = body.failed || 0;
              self.finished = !!body.finished;
              if (self.finished && self.timer) {
                window.clearInterval(self.timer);
                self.timer = null;
              }
            })
            .catch(function () {
              // Swallow transient fetch errors; the next tick retries.
              // If the dashboard is restarted mid-job the page becomes
              // permanently stale — that's intentional + visible (no
              // updates ever land).
            });
        };
        tick();
        self.timer = window.setInterval(tick, 1000);
      },
    };
  }

  // Defer Alpine registration until alpine fires its alpine:init event
  // (load order is alpine first then this file; the listener wires the
  // component before Alpine starts walking the DOM).
  if (typeof window.bulkProgress === "undefined") {
    window.bulkProgress = bulkProgress;
  }
  document.addEventListener("alpine:init", function () {
    if (window.Alpine && typeof window.Alpine.data === "function") {
      window.Alpine.data("bulkProgress", bulkProgress);
    }
  });
})();
