// Tailwind v4 standalone build configuration for the Lucairn Enterprise
// Dashboard. v4 reads its theme from `@theme` blocks inside the CSS entry
// (see static/css/tailwind-input.css). This file is kept as a marker so
// linters and tooling that expect a tailwind.config.js do not balk; the
// production build script invokes:
//
//   tailwindcss -i static/css/tailwind-input.css -o static/css/dashboard.css --minify
//
// from apps/dashboard/ and never reads this file directly.
//
// If we ever return to v3 / shadcn-style configuration, this file is the
// natural anchor.
module.exports = {
  content: [
    './internal/views/templates/**/*.html.tmpl',
  ],
  theme: {
    extend: {
      colors: {
        'bg-base': 'var(--color-bg-base)',
        'bg-panel': 'var(--color-bg-panel)',
        'bg-inset': 'var(--color-bg-inset)',
        'bg-elevated': 'var(--color-bg-elevated)',
        'text-primary': 'var(--color-text-primary)',
        'text-secondary': 'var(--color-text-secondary)',
        'text-muted': 'var(--color-text-muted)',
        'accent-highlight': 'var(--color-accent-highlight)',
        'accent-mid': 'var(--color-accent-mid)',
        'status-ok': 'var(--color-status-ok)',
        'status-warn': 'var(--color-status-warn)',
        'status-fail': 'var(--color-status-fail)',
      },
      borderRadius: {
        panel: 'var(--radius-panel)',
        button: 'var(--radius-button)',
        badge: 'var(--radius-badge)',
      },
      fontFamily: {
        sans: 'var(--font-sans)',
        mono: 'var(--font-mono)',
        display: 'var(--font-display)',
      },
    },
  },
};
