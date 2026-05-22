package views

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Inline-SVG chart renderers consumed by views.FuncMap (sparklineSVG /
// donutSVG / barRowSVG). All charts use the locked design tokens via
// inline `stroke="#8ec0f0"` etc. (we can't @use CSS vars inside an
// inline SVG body because the embedded `<svg>` lives in the page DOM
// and inherits the document's CSS scope, but inline attribute values
// are unambiguous + match the tailwind-input.css palette). Status
// colours follow the same locked semantics as .lc-statusdot--ok /
// .lc-statusdot--warn / .lc-statusdot--fail.
//
// No external dependencies, no CDN fetch — matches the project's
// "ship Bricolage + Geist locally; never load fonts at runtime" rule.

const (
	accentHighlight = "#8ec0f0"
	accentMid       = "#5a8cc8"
	statusOK        = "#10b981"
	statusWarn      = "#f59e0b"
	statusFail      = "#ef4444"
	textMuted       = "#6d6f78"
	bgInset         = "#0b0c0e"
	borderDefault   = "#1c1d21"
)

// renderSparkline draws an SVG polyline across the values normalised
// to the chart's height. A small accent dot is drawn on the last
// value so the operator can read "the current state" without parsing
// the whole line.
func renderSparkline(values []int, width, height int) string {
	if len(values) == 0 {
		return fmt.Sprintf(`<svg width="%d" height="%d" role="img" aria-label="No data"></svg>`, width, height)
	}
	if width <= 0 {
		width = 320
	}
	if height <= 0 {
		height = 60
	}

	maxVal := 1
	for _, v := range values {
		if v > maxVal {
			maxVal = v
		}
	}
	stepX := float64(width) / float64(max(len(values)-1, 1))
	padding := 4.0
	usable := float64(height) - 2*padding

	var pts strings.Builder
	for i, v := range values {
		x := float64(i) * stepX
		y := padding + usable - (float64(v)/float64(maxVal))*usable
		if i > 0 {
			pts.WriteByte(' ')
		}
		pts.WriteString(fmt.Sprintf("%.1f,%.1f", x, y))
	}
	lastIdx := len(values) - 1
	lastX := float64(lastIdx) * stepX
	lastY := padding + usable - (float64(values[lastIdx])/float64(maxVal))*usable

	// Build an area-fill polygon by closing the line back to the bottom.
	areaPts := pts.String()
	closing := fmt.Sprintf(" %.1f,%.1f 0,%.1f", float64(width), float64(height)-padding, float64(height)-padding)

	return fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" preserveAspectRatio="none" width="100%%" height="%d" role="img" aria-label="Time-series sparkline, latest value %d, max %d">
  <polygon points="%s%s" fill="%s" fill-opacity="0.12"/>
  <polyline points="%s" fill="none" stroke="%s" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/>
  <circle cx="%.1f" cy="%.1f" r="2.5" fill="%s"/>
</svg>`,
		width, height, height,
		values[lastIdx], maxVal,
		areaPts, closing, accentHighlight,
		pts.String(), accentHighlight,
		lastX, lastY, accentHighlight,
	)
}

// renderDonut draws an SVG donut chart from parallel label + value
// slices. Slice colours follow status semantics: index 0 (passed /
// dominant) gets statusOK, index 1 (partial) gets statusWarn, index 2
// (failed) gets statusFail, the rest get textMuted. Centre shows the
// total count + the leading label.
func renderDonut(labels []string, values []int, size int) string {
	if len(values) == 0 || len(labels) != len(values) {
		return fmt.Sprintf(`<svg width="%d" height="%d" role="img" aria-label="No data"></svg>`, size, size)
	}
	if size <= 0 {
		size = 140
	}
	total := 0
	for _, v := range values {
		total += v
	}
	if total == 0 {
		return fmt.Sprintf(`<svg width="%d" height="%d" role="img" aria-label="No data"></svg>`, size, size)
	}

	cx := float64(size) / 2
	cy := float64(size) / 2
	rOuter := float64(size)/2 - 4
	rInner := rOuter * 0.62

	palette := []string{statusOK, statusWarn, statusFail, accentMid, textMuted}

	var arcs strings.Builder
	startAngle := -math.Pi / 2 // start at 12 o'clock
	for i, v := range values {
		if v == 0 {
			continue
		}
		fraction := float64(v) / float64(total)
		endAngle := startAngle + fraction*2*math.Pi
		colour := palette[i%len(palette)]
		path := annularArcPath(cx, cy, rOuter, rInner, startAngle, endAngle)
		arcs.WriteString(fmt.Sprintf(`<path d="%s" fill="%s" />`, path, colour))
		startAngle = endAngle
	}

	// Centre label = total count, secondary label = top slice's label.
	centreFont := size / 6
	if centreFont < 14 {
		centreFont = 14
	}
	smallFont := size / 14
	if smallFont < 10 {
		smallFont = 10
	}
	leader := labels[0]
	return fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" role="img" aria-label="Donut chart total %d">
  %s
  <text x="%.0f" y="%.0f" text-anchor="middle" dominant-baseline="middle" fill="#e5e5e7" font-family="Geist Mono, ui-monospace, monospace" font-size="%d" font-weight="600">%s</text>
  <text x="%.0f" y="%.0f" text-anchor="middle" dominant-baseline="middle" fill="%s" font-family="Geist, system-ui, sans-serif" font-size="%d">%s</text>
</svg>`,
		size, size, size, size, total,
		arcs.String(),
		cx, cy-float64(smallFont)/1.5, centreFont, commaSeparate(total),
		cx, cy+float64(centreFont)/1.4, textMuted, smallFont, leader,
	)
}

// annularArcPath builds an SVG path string for one annular arc
// (outer arc, line in, reverse inner arc, line back).
func annularArcPath(cx, cy, rOuter, rInner, startAngle, endAngle float64) string {
	largeArc := "0"
	if endAngle-startAngle > math.Pi {
		largeArc = "1"
	}
	x1 := cx + rOuter*math.Cos(startAngle)
	y1 := cy + rOuter*math.Sin(startAngle)
	x2 := cx + rOuter*math.Cos(endAngle)
	y2 := cy + rOuter*math.Sin(endAngle)
	x3 := cx + rInner*math.Cos(endAngle)
	y3 := cy + rInner*math.Sin(endAngle)
	x4 := cx + rInner*math.Cos(startAngle)
	y4 := cy + rInner*math.Sin(startAngle)
	return fmt.Sprintf("M %.2f %.2f A %.2f %.2f 0 %s 1 %.2f %.2f L %.2f %.2f A %.2f %.2f 0 %s 0 %.2f %.2f Z",
		x1, y1, rOuter, rOuter, largeArc, x2, y2,
		x3, y3, rInner, rInner, largeArc, x4, y4,
	)
}

// renderBarRow draws one horizontal bar row: label + value + a
// proportional bar at the right. Designed to be wrapped in a flex
// container by the caller; the bar fills the supplied width.
func renderBarRow(label string, value, max, width int) string {
	if max <= 0 {
		max = 1
	}
	frac := float64(value) / float64(max)
	if frac > 1 {
		frac = 1
	}
	if frac < 0 {
		frac = 0
	}
	if width <= 0 {
		width = 160
	}
	barW := int(float64(width) * frac)
	height := 8
	return fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" role="img" aria-label="%s: %d of %d">
  <rect x="0" y="0" width="%d" height="%d" rx="2" fill="%s"/>
  <rect x="0" y="0" width="%d" height="%d" rx="2" fill="%s"/>
</svg>`,
		width, height, label, value, max,
		width, height, borderDefault,
		barW, height, accentHighlight,
	)
}

// commaSeparate renders an int with thousand separators (4567 → "4,567")
// without depending on golang.org/x/text/message (which would pull in
// the i18n package + tables for ~1MB). The dashboard's number-rendering
// is en-US only; future i18n is a v1.1 candidate.
func commaSeparate(n int) string {
	neg := n < 0
	if neg {
		n = -n
	}
	s := strconv.Itoa(n)
	if len(s) <= 3 {
		if neg {
			return "-" + s
		}
		return s
	}
	var out strings.Builder
	first := len(s) % 3
	if first > 0 {
		out.WriteString(s[:first])
		if len(s) > first {
			out.WriteByte(',')
		}
	}
	for i := first; i < len(s); i += 3 {
		out.WriteString(s[i : i+3])
		if i+3 < len(s) {
			out.WriteByte(',')
		}
	}
	if neg {
		return "-" + out.String()
	}
	return out.String()
}

// max is a tiny helper that pre-dates Go 1.21's builtin. Kept local
// so the build still works on a Go toolchain that doesn't expose
// the builtin form yet.
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
