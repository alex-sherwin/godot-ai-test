import './style.css';

/**
 * Landing-page behaviour for Disc Golf Flight Lab.
 *
 * Two jobs only:
 *   1. Point the launch button at the Godot export using the Vite base URL, so
 *      the link is correct both at `/` (dev) and `/godot-ai-test/` (Pages).
 *   2. Refuse to launch — with an explanation — when the browser cannot give
 *      Godot the WebGL2 context it requires.
 */

const GAME_PATH = `${import.meta.env.BASE_URL}game/index.html`;

/** @returns {{ ok: boolean, reason?: string }} */
function checkWebGL2() {
  const canvas = document.createElement('canvas');
  let gl = null;
  try {
    gl = canvas.getContext('webgl2');
  } catch (err) {
    return { ok: false, reason: `WebGL2 context creation threw: ${err.message}` };
  }
  if (!gl) {
    return {
      ok: false,
      reason:
        'This browser did not provide a WebGL2 context. The simulator needs ' +
        'WebGL2 to render. Try a current version of Chrome, Edge, Firefox or ' +
        'Safari, and check that hardware acceleration is enabled.',
    };
  }
  // Release the probe context immediately; some drivers cap concurrent contexts.
  gl.getExtension('WEBGL_lose_context')?.loseContext();
  return { ok: true };
}

function init() {
  const launch = document.querySelector('#launch');
  const notice = document.querySelector('#notice');
  if (!launch || !notice) return;

  // Authoritative href, derived from the base Vite was actually built with.
  launch.setAttribute('href', GAME_PATH);

  const webgl = checkWebGL2();
  if (!webgl.ok) {
    launch.classList.add('is-disabled');
    launch.setAttribute('aria-disabled', 'true');
    launch.addEventListener('click', (event) => event.preventDefault());
    notice.textContent = webgl.reason;
    notice.hidden = false;
    return;
  }

  // The engine download is large enough that the navigation itself can feel
  // unresponsive. Give immediate feedback while the browser gets on with it.
  launch.addEventListener('click', () => {
    if (launch.classList.contains('is-disabled')) return;
    launch.classList.add('is-loading');
    const label = launch.querySelector('.btn-label');
    if (label) label.textContent = 'Loading engine…';
  });
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
