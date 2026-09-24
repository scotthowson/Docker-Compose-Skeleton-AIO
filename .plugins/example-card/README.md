# Example Card Plugin

Demonstrates how to create custom dashboard cards for DCS Manager.

## Plugin Structure

```
.plugins/your-plugin/
├── plugin.json                  # Plugin manifest
├── README.md                    # Documentation
└── cards/
    └── your-card/
        ├── card.json            # Card configuration (required)
        ├── index.html           # Card content (required — all-in-one)
        ├── style.css            # Stylesheet reference (optional — for docs)
        └── script.js            # Script reference (optional — for docs)
```

> **Note:** Since cards render via blob URLs, external CSS/JS files can't be
> loaded. The `style.css` and `script.js` files are provided as **readable
> reference copies** of what's inlined in `index.html`. Edit `index.html`
> directly — it's the only file that runs.

## card.json Reference

```jsonc
{
  // ── Required ──
  "id": "plugin:your-plugin:your-card",   // Format: plugin:pluginName:cardName
  "title": "My Widget",                   // Display name
  "icon": "Gauge",                        // Lucide icon name
  "description": "What this card shows",  // Shown in card picker

  // ── Default Size (grid units) ──
  "defaultW": 8,      // Width: 1-24 columns (8 = one-third)
  "defaultH": 6,      // Height: 1-20 rows (× 50px each)

  // ── Size Constraints (optional — omit for free resizing) ──
  "minW": 4,           // Minimum width user can resize to
  "minH": 3,           // Minimum height
  "maxW": 12,          // Maximum width
  "maxH": 8,           // Maximum height

  // ── Behavior (optional) ──
  "isScrollable": false,    // Internal scroll when content overflows
  "refreshInterval": 0,     // Auto-refresh in ms (0 = manual)
  "dataEndpoint": null,      // DCS API path to fetch data from

  // ── Metadata (optional) ──
  "author": "Your Name",
  "version": "1.0.0"
}
```

## Size Quick Reference

| Width | Grid | Visual     |
|-------|------|------------|
| 6     | 6/24 | Quarter    |
| 8     | 8/24 | Third      |
| 12    | 12/24| Half       |
| 16    | 16/24| Two-thirds |
| 24    | 24/24| Full width |

| Height | Pixels | Use          |
|--------|--------|--------------|
| 3      | 150px  | Compact stat |
| 4      | 200px  | Small widget |
| 6      | 300px  | Standard     |
| 8      | 400px  | Tall card    |
| 10     | 500px  | Large chart  |

## Writing Your Card HTML

Your `index.html` is a complete HTML page rendered inside a sandboxed iframe.

**Key rules:**
1. Use `background: transparent` on `body` — the DCS glass card effect shows through
2. Inline all CSS and JS — external files won't resolve from blob URLs
3. Use `height: 100vh` on body to fill the card area
4. Use standard HTML/CSS/JS — no frameworks needed

**Template:**
```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      background: transparent;
      color: #e2e8f0;
      height: 100vh;
      overflow: hidden;
    }
    /* Your styles here */
  </style>
</head>
<body>
  <!-- Your content here -->

  <script>
    // Your JavaScript here
  </script>
</body>
</html>
```

## DCS Color Palette

Use these colors to match the DCS dark theme:

| Color        | Hex       | Use                    |
|-------------|-----------|------------------------|
| Background  | #0f172a   | (use transparent instead) |
| Card bg     | transparent | Glass effect from parent |
| Text primary| #e2e8f0   | Main text              |
| Text muted  | #94a3b8   | Labels, titles         |
| Text dim    | #64748b   | Secondary info         |
| Text subtle | #475569   | Hints, timestamps      |
| Emerald     | #34d399   | Success, health, live  |
| Cyan        | #06b6d4   | Info, metrics          |
| Violet      | #8b5cf6   | Plugin accent          |
| Amber       | #f59e0b   | Warnings, network      |
| Rose        | #f87171   | Errors, critical       |
| Border      | rgba(255,255,255,0.05) | Subtle borders |

## Accessing the DCS API (Future)

Plugin cards will be able to fetch data from the DCS API using a postMessage bridge:

```javascript
// Request data
window.parent.postMessage({
  type: 'dcs-api-request',
  path: '/status',
  requestId: 'my-request'
}, '*');

// Receive response
window.addEventListener('message', function(event) {
  if (event.data.type === 'dcs-api-response'
      && event.data.requestId === 'my-request') {
    var data = event.data.body;
    // Use the data...
  }
});
```
