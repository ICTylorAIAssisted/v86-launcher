// ============================================
// SESSION SYNC MODULE
// Add this to your index.html inside the <script> tag
// ============================================

// Configuration - UPDATE THIS after deploying your worker
const SYNC_CONFIG = {
  // Your Cloudflare Worker URL (update after deployment)
  workerUrl: '', // e.g., 'https://v86-session-sync.yourname.workers.dev'
  
  // Sync interval in milliseconds
  syncInterval: 3000,
  
  // Enable sync (can be toggled)
  enabled: false,
  
  // Session ID (set via URL param or generated)
  sessionId: null,
};

// Sync state
let syncState = {
  lastSyncedSnapshotIndex: 0,
  lastSyncedKeystrokeIndex: 0,
  syncTimer: null,
  issyncing: false,
};

/**
 * Initialize session sync
 * Call this after the emulator boots (in onBootComplete or startRecording)
 */
function initSessionSync() {
  // Check URL params for session config
  const params = new URLSearchParams(window.location.search);
  
  // Get or generate session ID
  SYNC_CONFIG.sessionId = params.get('sync_session') || generateSessionId();
  
  // Check if sync is enabled via URL param
  if (params.get('sync') === 'true' || params.get('sync_session')) {
    SYNC_CONFIG.enabled = true;
  }
  
  // Get worker URL from param or use default
  if (params.get('sync_url')) {
    SYNC_CONFIG.workerUrl = params.get('sync_url');
  }
  
  // Add sync UI if not exists
  addSyncUI();
  
  // Start sync if enabled and configured
  if (SYNC_CONFIG.enabled && SYNC_CONFIG.workerUrl) {
    startSync();
  }
  
  console.log('Session sync initialized:', {
    sessionId: SYNC_CONFIG.sessionId,
    enabled: SYNC_CONFIG.enabled,
    workerUrl: SYNC_CONFIG.workerUrl ? '(configured)' : '(not set)',
  });
}

function generateSessionId() {
  // Generate a readable session ID
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let id = '';
  for (let i = 0; i < 12; i++) {
    if (i === 4 || i === 8) id += '-';
    id += chars[Math.floor(Math.random() * chars.length)];
  }
  return id;
}

function addSyncUI() {
  // Find the status bar or create sync indicator
  const statusBar = document.querySelector('.status-bar') || document.querySelector('.vm-header');
  if (!statusBar) return;
  
  // Check if already exists
  if (document.getElementById('syncStatus')) return;
  
  // Create sync status element
  const syncDiv = document.createElement('div');
  syncDiv.id = 'syncStatus';
  syncDiv.className = 'status-item';
  syncDiv.style.cssText = 'display: flex; align-items: center; gap: 6px; font-size: 0.8rem;';
  syncDiv.innerHTML = `
    <span id="syncDot" style="width: 8px; height: 8px; border-radius: 50%; background: #666;"></span>
    <span id="syncText">Sync: Off</span>
  `;
  
  statusBar.appendChild(syncDiv);
  
  // Make it clickable to show session info
  syncDiv.style.cursor = 'pointer';
  syncDiv.onclick = showSyncInfo;
}

function showSyncInfo() {
  if (!SYNC_CONFIG.sessionId) return;
  
  const viewerUrl = getViewerUrl();
  const message = SYNC_CONFIG.enabled 
    ? `Session ID: ${SYNC_CONFIG.sessionId}\n\nViewer URL:\n${viewerUrl}\n\nCopy viewer URL?`
    : `Sync is disabled.\n\nSession ID: ${SYNC_CONFIG.sessionId}\n\nTo enable, add ?sync=true to URL or configure SYNC_CONFIG.workerUrl`;
  
  if (SYNC_CONFIG.enabled && confirm(message)) {
    navigator.clipboard.writeText(viewerUrl).then(() => {
      showToast('Viewer URL copied!', 'success');
    }).catch(() => {
      // Fallback: show in prompt for manual copy
      prompt('Copy this URL:', viewerUrl);
    });
  } else if (!SYNC_CONFIG.enabled) {
    alert(message);
  }
}

function getViewerUrl() {
  // Construct the viewer URL
  const base = window.location.origin + window.location.pathname.replace('index.html', 'session-replay.html');
  const params = new URLSearchParams({
    live: 'true',
    session: SYNC_CONFIG.sessionId,
  });
  
  if (SYNC_CONFIG.workerUrl) {
    params.set('sync_url', SYNC_CONFIG.workerUrl);
  }
  
  return `${base}?${params.toString()}`;
}

function startSync() {
  if (!SYNC_CONFIG.workerUrl) {
    console.warn('Sync worker URL not configured');
    updateSyncStatus('error', 'Not configured');
    return;
  }
  
  if (syncState.syncTimer) {
    clearInterval(syncState.syncTimer);
  }
  
  SYNC_CONFIG.enabled = true;
  updateSyncStatus('active', 'Starting...');
  
  // Initial sync
  syncSession();
  
  // Periodic sync
  syncState.syncTimer = setInterval(syncSession, SYNC_CONFIG.syncInterval);
  
  console.log('Session sync started:', SYNC_CONFIG.sessionId);
}

function stopSync() {
  if (syncState.syncTimer) {
    clearInterval(syncState.syncTimer);
    syncState.syncTimer = null;
  }
  
  SYNC_CONFIG.enabled = false;
  updateSyncStatus('off', 'Sync: Off');
  
  console.log('Session sync stopped');
}

async function syncSession() {
  if (syncState.isSyncing || !sessionRecording) return;
  
  syncState.isSyncing = true;
  
  try {
    // Get new snapshots since last sync
    const newSnapshots = sessionRecording.snapshots.slice(syncState.lastSyncedSnapshotIndex);
    const newKeystrokes = sessionRecording.keystrokes.slice(syncState.lastSyncedKeystrokeIndex);
    
    // Skip if nothing new
    if (newSnapshots.length === 0 && newKeystrokes.length === 0) {
      syncState.isSyncing = false;
      return;
    }
    
    updateSyncStatus('syncing', 'Syncing...');
    
    const payload = {
      config: {
        title: activeConfig?.branding?.title || 'VM Session',
        started: new Date(sessionRecording.started).toISOString(),
      },
      snapshots: newSnapshots,
      keystrokes: newKeystrokes,
    };
    
    const response = await fetch(`${SYNC_CONFIG.workerUrl}/session/${SYNC_CONFIG.sessionId}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}`);
    }
    
    const result = await response.json();
    
    // Update sync state
    syncState.lastSyncedSnapshotIndex = sessionRecording.snapshots.length;
    syncState.lastSyncedKeystrokeIndex = sessionRecording.keystrokes.length;
    
    updateSyncStatus('active', `Live (${result.snapshotCount})`);
    
  } catch (error) {
    console.error('Sync failed:', error);
    updateSyncStatus('error', 'Sync error');
  } finally {
    syncState.isSyncing = false;
  }
}

function updateSyncStatus(status, text) {
  const dot = document.getElementById('syncDot');
  const textEl = document.getElementById('syncText');
  
  if (!dot || !textEl) return;
  
  const colors = {
    off: '#666',
    active: '#22c55e',
    syncing: '#f59e0b',
    error: '#ef4444',
  };
  
  dot.style.background = colors[status] || colors.off;
  textEl.textContent = text;
  
  // Pulse animation for syncing
  if (status === 'syncing') {
    dot.style.animation = 'pulse 1s infinite';
  } else {
    dot.style.animation = 'none';
  }
}

// ============================================
// INTEGRATION POINT
// ============================================
// Add this call inside your existing startRecording() function,
// right after the sessionRecording object is initialized:
//
//   function startRecording() {
//     sessionRecording = {
//       started: Date.now(),
//       snapshots: [],
//       keystrokes: [],
//       isRecording: true,
//       snapshotInterval: null,
//     };
//
//     // >>> ADD THIS LINE <<<
//     initSessionSync();
//
//     sessionRecording.snapshotInterval = setInterval(captureTerminalSnapshot, 1000);
//     console.log('Session recording started');
//   }
//
// ============================================

// CSS for pulse animation (add to your styles)
const syncStyles = document.createElement('style');
syncStyles.textContent = `
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.5; }
  }
  #syncStatus:hover {
    background: var(--bg-tertiary, #2d2d2d);
    border-radius: 4px;
  }
`;
document.head.appendChild(syncStyles);
