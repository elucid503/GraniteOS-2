// Minimalist outline icons for the desktop, drawn by the SVG renderer (svg.zig).

pub const apps =
    \\<svg viewBox="0 0 24 24">
    \\<rect x="4" y="4" width="6" height="6" rx="1"/>
    \\<rect x="14" y="4" width="6" height="6" rx="1"/>
    \\<rect x="4" y="14" width="6" height="6" rx="1"/>
    \\<rect x="14" y="14" width="6" height="6" rx="1"/>
    \\</svg>
;

// Price-tag icon for launcher categories, distinct from the apps grid and folder.
pub const category =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M12 3 L20 3 L20 11 L11 20 L3 12 Z"/>
    \\<circle cx="16" cy="7" r="1.5"/>
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

pub const network =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="12" cy="12" r="9"/>
    \\<line x1="3" y1="12" x2="21" y2="12"/>
    \\<path d="M12 3 Q17 12 12 21"/>
    \\<path d="M12 3 Q7 12 12 21"/>
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

pub const bell =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M6 17 L18 17 L16 14 L16 10 Q16 5 12 5 Q8 5 8 10 L8 14 Z"/>
    \\<path d="M10 19 Q12 21 14 19"/>
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

pub const calculator =
    \\<svg viewBox="0 0 24 24">
    \\<line x1="6" y1="6" x2="18" y2="18"/>
    \\<circle cx="8" cy="16" r="1.5"/>
    \\<circle cx="16" cy="8" r="1.5"/>
    \\</svg>
;

pub const timer =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="12" cy="13" r="7"/>
    \\<polyline points="12 13 12 10"/>
    \\<line x1="9" y1="4" x2="15" y2="4"/>
    \\<line x1="12" y1="4" x2="12" y2="6"/>
    \\</svg>
;

pub const paint =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M4 18 L8 14 L18 4 L20 6 L10 16 L6 20 Z"/>
    \\<path d="M14 8 L16 10"/>
    \\</svg>
;

pub const image =
    \\<svg viewBox="0 0 24 24">
    \\<rect x="3" y="5" width="18" height="14" rx="1"/>
    \\<circle cx="9" cy="10" r="2"/>
    \\<polyline points="5 17 10 13 14 16 19 11"/>
    \\</svg>
;

pub const music =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="7" cy="18" r="2.5"/>
    \\<circle cx="17" cy="16" r="2.5"/>
    \\<line x1="9" y1="18" x2="9" y2="6"/>
    \\<line x1="19" y1="16" x2="19" y2="4"/>
    \\<line x1="9" y1="6" x2="19" y2="4"/>
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

// Weather (WMO codes from Open-Meteo current_weather.weathercode).

pub const weather_clear =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="12" cy="12" r="4"/>
    \\<line x1="12" y1="2" x2="12" y2="5"/>
    \\<line x1="12" y1="19" x2="12" y2="22"/>
    \\<line x1="2" y1="12" x2="5" y2="12"/>
    \\<line x1="19" y1="12" x2="22" y2="12"/>
    \\<line x1="4.5" y1="4.5" x2="6.5" y2="6.5"/>
    \\<line x1="17.5" y1="17.5" x2="19.5" y2="19.5"/>
    \\<line x1="4.5" y1="19.5" x2="6.5" y2="17.5"/>
    \\<line x1="17.5" y1="6.5" x2="19.5" y2="4.5"/>
    \\</svg>
;

// Crescent moon for clear nights.
pub const weather_clear_night =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M14 4 Q10 5 8 9 Q6 14 9 18 Q12 21 17 20 Q14 18 13 14 Q12 9 14 4 Z"/>
    \\</svg>
;

pub const weather_partly =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="9" cy="10" r="3"/>
    \\<line x1="9" y1="3" x2="9" y2="5"/>
    \\<line x1="3" y1="10" x2="5" y2="10"/>
    \\<line x1="4" y1="5" x2="5.5" y2="6.5"/>
    \\<path d="M10 16 Q10 13 13 13 Q14 11 17 11 Q20 11 20 14.5 Q22 14.5 22 17 Q22 19.5 19.5 19.5 L11 19.5 Q10 19.5 10 16 Z"/>
    \\</svg>
;

// Crescent + cloud for partly cloudy nights.
pub const weather_partly_night =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M10 5 Q7 6 6 9 Q5 12 7 14 Q8 12 10 11 Q12 10 13 8 Q12 6 10 5 Z"/>
    \\<path d="M10 16 Q10 13 13 13 Q14 11 17 11 Q20 11 20 14.5 Q22 14.5 22 17 Q22 19.5 19.5 19.5 L11 19.5 Q10 19.5 10 16 Z"/>
    \\</svg>
;

pub const weather_cloud =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M7 17 Q5 17 5 14.5 Q5 12 8 12 Q8.5 9 12 9 Q16 9 16.5 12.5 Q19 12.5 19 15 Q19 17.5 16.5 17.5 Z"/>
    \\</svg>
;

pub const weather_fog =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M7 11 Q5 11 5 9 Q5 7 8 7 Q8.5 5 12 5 Q16 5 16.5 7.5 Q19 7.5 19 10 Q19 12 16.5 12 L8 12 Q7 12 7 11 Z"/>
    \\<line x1="5" y1="15" x2="19" y2="15"/>
    \\<line x1="6" y1="18" x2="18" y2="18"/>
    \\<line x1="7" y1="21" x2="17" y2="21"/>
    \\</svg>
;

pub const weather_rain =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M7 13 Q5 13 5 10.5 Q5 8 8 8 Q8.5 5.5 12 5.5 Q16 5.5 16.5 8.5 Q19 8.5 19 11 Q19 13.5 16.5 13.5 Z"/>
    \\<line x1="9" y1="16" x2="8" y2="20"/>
    \\<line x1="13" y1="16" x2="12" y2="20"/>
    \\<line x1="17" y1="16" x2="16" y2="20"/>
    \\</svg>
;

pub const weather_snow =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M7 12 Q5 12 5 9.5 Q5 7 8 7 Q8.5 4.5 12 4.5 Q16 4.5 16.5 7.5 Q19 7.5 19 10 Q19 12.5 16.5 12.5 Z"/>
    \\<line x1="9" y1="16" x2="9" y2="20"/>
    \\<line x1="7.5" y1="17.5" x2="10.5" y2="18.5"/>
    \\<line x1="7.5" y1="18.5" x2="10.5" y2="17.5"/>
    \\<line x1="15" y1="16" x2="15" y2="20"/>
    \\<line x1="13.5" y1="17.5" x2="16.5" y2="18.5"/>
    \\<line x1="13.5" y1="18.5" x2="16.5" y2="17.5"/>
    \\</svg>
;

pub const weather_storm =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M7 12 Q5 12 5 9.5 Q5 7 8 7 Q8.5 4.5 12 4.5 Q16 4.5 16.5 7.5 Q19 7.5 19 10 Q19 12.5 16.5 12.5 Z"/>
    \\<polyline points="12 13 10 17 13 17 11 21"/>
    \\</svg>
;

// Weather app: launcher mark plus condition-detail glyphs for the tile grid.

pub const weather_app =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="15.5" cy="8" r="3.2"/>
    \\<line x1="15.5" y1="2" x2="15.5" y2="3.4"/>
    \\<line x1="20.4" y1="3.6" x2="19.4" y2="4.6"/>
    \\<line x1="21.5" y1="8" x2="20.1" y2="8"/>
    \\<path d="M5.5 19.5 Q3 19.5 3 16.8 Q3 14.2 6 14.2 Q6.5 11 10.2 11 Q13.8 11 14.3 14.6 Q16.8 14.6 16.8 17 Q16.8 19.5 14.4 19.5 Z"/>
    \\</svg>
;

pub const wind =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M3 8.5 L13.5 8.5 Q16.2 8.5 16.2 6.2 Q16.2 4.2 14.2 4.2"/>
    \\<path d="M3 12.5 L18.2 12.5 Q21 12.5 21 15 Q21 17.4 18.6 17.4"/>
    \\<path d="M3 16.5 L10.2 16.5 Q12.4 16.5 12.4 18.4 Q12.4 20.2 10.6 20.2"/>
    \\</svg>
;

pub const droplet =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M12 3 Q17.5 10 17.5 14.3 Q17.5 19.5 12 19.5 Q6.5 19.5 6.5 14.3 Q6.5 10 12 3 Z"/>
    \\<path d="M9.5 14 Q9.5 16.5 11.5 17"/>
    \\</svg>
;

pub const gauge =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M4 17 Q4 8.5 12 8.5 Q20 8.5 20 17"/>
    \\<line x1="12" y1="17" x2="16.2" y2="12"/>
    \\<circle cx="12" cy="17" r="1.6"/>
    \\</svg>
;

pub const thermometer =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M10 4.5 Q10 2.5 12 2.5 Q14 2.5 14 4.5 L14 13 Q16.5 14.4 16.5 17.2 Q16.5 21 12 21 Q7.5 21 7.5 17.2 Q7.5 14.4 10 13 Z"/>
    \\<line x1="12" y1="9" x2="12" y2="16.5"/>
    \\</svg>
;

pub const umbrella =
    \\<svg viewBox="0 0 24 24">
    \\<path d="M3.5 12 Q4.5 4.5 12 4.5 Q19.5 4.5 20.5 12 Z"/>
    \\<line x1="12" y1="3" x2="12" y2="4.5"/>
    \\<path d="M12 12 L12 18.5 Q12 20.5 10.2 20.5 Q8.5 20.5 8.5 19"/>
    \\</svg>
;

pub const sunrise =
    \\<svg viewBox="0 0 24 24">
    \\<line x1="3" y1="18" x2="21" y2="18"/>
    \\<path d="M7.5 18 Q7.5 13.5 12 13.5 Q16.5 13.5 16.5 18"/>
    \\<line x1="12" y1="10.5" x2="12" y2="5.5"/>
    \\<path d="M9.5 8 L12 5.5 L14.5 8"/>
    \\</svg>
;

pub const sunset =
    \\<svg viewBox="0 0 24 24">
    \\<line x1="3" y1="18" x2="21" y2="18"/>
    \\<path d="M7.5 18 Q7.5 13.5 12 13.5 Q16.5 13.5 16.5 18"/>
    \\<line x1="12" y1="5.5" x2="12" y2="10.5"/>
    \\<path d="M9.5 8 L12 10.5 L14.5 8"/>
    \\</svg>
;

pub const uv =
    \\<svg viewBox="0 0 24 24">
    \\<circle cx="12" cy="9" r="3.4"/>
    \\<line x1="12" y1="2.2" x2="12" y2="4"/>
    \\<line x1="6.4" y1="4.4" x2="7.7" y2="5.7"/>
    \\<line x1="17.6" y1="4.4" x2="16.3" y2="5.7"/>
    \\<line x1="5" y1="9" x2="7" y2="9"/>
    \\<line x1="17" y1="9" x2="19" y2="9"/>
    \\<path d="M4.5 18.5 Q8.2 16 12 18.5 Q15.8 21 19.5 18.5"/>
    \\</svg>
;
