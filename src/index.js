/**
 * v86 Session Sync Worker
 * 
 * Stores and retrieves live session data for real-time interview observation.
 * 
 * Endpoints:
 *   PUT  /session/:id          - Append new snapshots to session
 *   GET  /session/:id          - Get full session data
 *   GET  /session/:id?since=N  - Get snapshots since index N (for polling)
 *   DELETE /session/:id        - Clear session
 *   GET  /health               - Health check
 * 
 * KV Binding: SESSION_DATA
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // CORS headers
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, PUT, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    };

    // Preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders });
    }

    // Health check
    if (path === '/health') {
      return json({ status: 'ok', timestamp: Date.now() }, corsHeaders);
    }

    // Session routes
    const sessionMatch = path.match(/^\/session\/([a-zA-Z0-9_-]{4,64})$/);
    if (!sessionMatch) {
      return json({ 
        error: 'Invalid path',
        usage: {
          'PUT /session/:id': 'Append snapshots (body: { snapshots: [], keystrokes: [] })',
          'GET /session/:id': 'Get full session',
          'GET /session/:id?since=N': 'Get snapshots since index N',
          'DELETE /session/:id': 'Clear session',
        }
      }, corsHeaders, 404);
    }

    const sessionId = sessionMatch[1];
    const kvKey = `session:${sessionId}`;

    try {
      switch (request.method) {
        case 'PUT': {
          return await handlePut(request, env, kvKey, corsHeaders);
        }

        case 'GET': {
          return await handleGet(url, env, kvKey, corsHeaders);
        }

        case 'DELETE': {
          await env.SESSION_DATA.delete(kvKey);
          return json({ success: true, deleted: sessionId }, corsHeaders);
        }

        default:
          return json({ error: 'Method not allowed' }, corsHeaders, 405);
      }
    } catch (e) {
      console.error('Worker error:', e);
      return json({ error: e.message }, corsHeaders, 500);
    }
  }
};

async function handlePut(request, env, kvKey, corsHeaders) {
  const body = await request.json();
  
  // Get existing session or create new
  let session = await getSession(env, kvKey);
  
  if (!session) {
    session = {
      version: 2,
      format: 'snapshots',
      created: Date.now(),
      updated: Date.now(),
      config: body.config || {},
      snapshots: [],
      keystrokes: [],
    };
  }

  // Append new snapshots (if any)
  if (body.snapshots && Array.isArray(body.snapshots)) {
    session.snapshots.push(...body.snapshots);
  }

  // Append new keystrokes (if any)
  if (body.keystrokes && Array.isArray(body.keystrokes)) {
    session.keystrokes.push(...body.keystrokes);
  }

  // Update metadata
  session.updated = Date.now();
  if (body.config) {
    session.config = { ...session.config, ...body.config };
  }

  // Calculate duration from last snapshot
  if (session.snapshots.length > 0) {
    session.duration = session.snapshots[session.snapshots.length - 1].t;
  }

  // Store with 24-hour TTL
  await env.SESSION_DATA.put(kvKey, JSON.stringify(session), {
    expirationTtl: 86400
  });

  return json({
    success: true,
    snapshotCount: session.snapshots.length,
    keystrokeCount: session.keystrokes.length,
    duration: session.duration || 0,
  }, corsHeaders);
}

async function handleGet(url, env, kvKey, corsHeaders) {
  const session = await getSession(env, kvKey);
  
  if (!session) {
    return json({ 
      exists: false,
      snapshots: [],
      keystrokes: [],
    }, corsHeaders);
  }

  // Check for ?since=N parameter (for incremental polling)
  const sinceParam = url.searchParams.get('since');
  
  if (sinceParam !== null) {
    const sinceIndex = parseInt(sinceParam, 10);
    
    // Return only snapshots after the given index
    const newSnapshots = session.snapshots.slice(sinceIndex);
    const keystrokeSince = url.searchParams.get('keystrokeSince');
    const newKeystrokes = keystrokeSince !== null 
      ? session.keystrokes.slice(parseInt(keystrokeSince, 10))
      : [];

    return json({
      exists: true,
      partial: true,
      snapshotIndex: sinceIndex,
      totalSnapshots: session.snapshots.length,
      snapshots: newSnapshots,
      keystrokes: newKeystrokes,
      totalKeystrokes: session.keystrokes.length,
      duration: session.duration || 0,
      updated: session.updated,
    }, corsHeaders);
  }

  // Return full session
  return json({
    exists: true,
    ...session,
  }, corsHeaders);
}

async function getSession(env, kvKey) {
  const data = await env.SESSION_DATA.get(kvKey);
  return data ? JSON.parse(data) : null;
}

function json(data, corsHeaders, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json',
    }
  });
}
