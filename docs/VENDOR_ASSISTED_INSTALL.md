# Vendor-Assisted Install

For the first 2-3 design partners, offer a screen-share session as an exception, not as the default enterprise install model.

Rules:

- Customer hands stay on keyboard.
- Lucairn never shells into the customer box.
- Lucairn never receives unredacted env files.
- Every edge case discovered goes back into `INSTALL.md`, `OPS.md`, `TROUBLESHOOTING.md`, or `bin/lucairn doctor`.

After three assisted installs, the runbook should be self-sufficient enough that a normal customer platform engineer can install without a call.

Before the first assisted install for a new bundle shape, run the clean-host rehearsal in `docs/CLEAN_HOST_REHEARSAL.md`. Treat the rehearsal transcript as the baseline; the screen-share session should only explain or unblock customer-environment issues, not discover missing product instructions for the first time.
