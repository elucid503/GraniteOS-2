// Minimalist outline icons for the desktop, drawn by the SVG renderer (svg.zig). Each is a 24x24 stroke-only glyph
// from the shape subset the renderer supports (path/line/polyline/rect/circle), so they scale to any icon box.

pub const apps =
    \\<svg viewBox="0 0 24 24">
    \\<rect x="4" y="4" width="6" height="6" rx="1"/>
    \\<rect x="14" y="4" width="6" height="6" rx="1"/>
    \\<rect x="4" y="14" width="6" height="6" rx="1"/>
    \\<rect x="14" y="14" width="6" height="6" rx="1"/>
    \\</svg>
;

pub const folder =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M3 7 L3 19 L21 19 L21 9 L11 9 L9 6 L4 6 Z"/>
    \\</svg>
;

pub const file =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M6 3 L14 3 L19 8 L19 21 L6 21 Z"/>
    \\<polyline points="14 3 14 8 19 8"/>
    \\</svg>
;

pub const chart =
    \\<svg viewBox="0 0 24 24">
    \\<polyline points="3 17 9 11 13 15 21 5"/>
    \\<polyline points="21 9 21 5 17 5"/>
    \\</svg>
;

pub const terminal =
    \\<svg viewBox="0 0 24 24">
    \\<polyline points="6 8 11 12 6 16"/>
    \\<line x1="14" y1="17" x2="19" y2="17"/>
    \\</svg>
;

pub const home =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M4 11 L12 4 L20 11"/>
    \\<path d="M6 10 L6 20 L18 20 L18 10"/>
    \\</svg>
;

pub const arrow_up =
    \\<svg viewBox="0 0 24 24">
    \\<polyline points="6 13 12 7 18 13"/>
    \\<line x1="12" y1="7" x2="12" y2="19"/>
    \\</svg>
;

pub const search =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="11" cy="11" r="6"/>
    \\<line x1="16" y1="16" x2="20" y2="20"/>
    \\</svg>
;

pub const clock =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="12" cy="12" r="8"/>
    \\<polyline points="12 8 12 12 15 14"/>
    \\</svg>
;

pub const cpu =
    \\<svg viewBox="0 0 24 24">
    \\<rect x="7" y="7" width="10" height="10" rx="1"/>
    \\<line x1="10" y1="3" x2="10" y2="7"/>
    \\<line x1="14" y1="3" x2="14" y2="7"/>
    \\<line x1="10" y1="17" x2="10" y2="21"/>
    \\<line x1="14" y1="17" x2="14" y2="21"/>
    \\<line x1="3" y1="10" x2="7" y2="10"/>
    \\<line x1="3" y1="14" x2="7" y2="14"/>
    \\<line x1="17" y1="10" x2="21" y2="10"/>
    \\<line x1="17" y1="14" x2="21" y2="14"/>
    \\</svg>
;

pub const disk =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="12" cy="12" r="8"/>
    \\<circle cx="12" cy="12" r="2"/>
    \\</svg>
;

pub const memory =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="12" cy="12" r="8"/>
    \\<line x1="12" y1="12" x2="12" y2="4"/>
    \\<line x1="12" y1="12" x2="18" y2="17"/>
    \\</svg>
;

// Lucide mouse-pointer-2 — default arrow cursor.
pub const pointer =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M4 4l7 16 2-7 7-2z"/>
    \\</svg>
;

// Lucide hand — open hand for clickable targets.
pub const hand =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M18 11V6a2 2 0 0 0-2-2a2 2 0 0 0-2 2"/>
    \\<path d="M14 10V4a2 2 0 0 0-2-2a2 2 0 0 0-2 2v2"/>
    \\<path d="M10 10V4a2 2 0 0 0-2-2a2 2 0 0 0-2 2v2"/>
    \\<path d="M6 10V4a2 2 0 0 0-2-2"/>
    \\<path d="M18 11v2a8 8 0 0 1-8 8"/>
    \\<path d="M6 10v10"/>
    \\</svg>
;

// Single caret line for text fields.
pub const text_cursor =
    \\<svg viewBox="0 0 24 24">
    \\<line x1="12" y1="4" x2="12" y2="20"/>
    \\</svg>
;
