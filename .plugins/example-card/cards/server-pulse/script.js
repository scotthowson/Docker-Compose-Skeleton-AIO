// =============================================================================
// Server Pulse — DCS Plugin Card Script
// =============================================================================
// Simulates live server metrics with random values.
// In a real plugin, you'd use the postMessage API bridge to fetch
// actual data from the DCS API.
//
// Example API call:
//   window.parent.postMessage({
//     type: 'dcs-api-request',
//     path: '/status',
//     requestId: 'status-1'
//   }, '*');
// =============================================================================

var startTime = Date.now();

// DOM references
var cpuBar = document.getElementById('cpu-bar');
var cpuVal = document.getElementById('cpu-val');
var ramBar = document.getElementById('ram-bar');
var ramVal = document.getElementById('ram-val');
var netBar = document.getElementById('net-bar');
var netVal = document.getElementById('net-val');
var uptimeEl = document.getElementById('uptime');

function randomBetween(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function updateMetrics() {
  var cpu = randomBetween(12, 68);
  var ram = randomBetween(35, 78);
  var net = randomBetween(3, 50);

  cpuBar.style.width = cpu + '%';
  cpuVal.textContent = cpu + '%';
  ramBar.style.width = ram + '%';
  ramVal.textContent = ram + '%';
  netBar.style.width = net + '%';
  netVal.textContent = net + '%';

  // Uptime counter
  var seconds = Math.floor((Date.now() - startTime) / 1000);
  var d = Math.floor(seconds / 86400);
  var h = Math.floor((seconds % 86400) / 3600);
  var m = Math.floor((seconds % 3600) / 60);
  var s = seconds % 60;
  uptimeEl.textContent = (d ? d + 'd ' : '') + (h ? h + 'h ' : '') + m + 'm ' + s + 's';
}

// Run immediately, then every 2 seconds
updateMetrics();
setInterval(updateMetrics, 2000);
