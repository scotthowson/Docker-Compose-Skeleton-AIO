// =============================================================================
// System Clock — DCS Plugin Card Script
// =============================================================================
// Updates the clock display every second.
// DOM elements are referenced by ID from index.html.
// =============================================================================

var timeEl = document.getElementById('t');
var dateEl = document.getElementById('d');

function updateClock() {
  var now = new Date();

  timeEl.textContent = now.toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: true
  });

  dateEl.textContent = now.toLocaleDateString([], {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric'
  });
}

// Run immediately, then every second
updateClock();
setInterval(updateClock, 1000);
