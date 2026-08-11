import './style.css';

/**
 * Landing-page behaviour for Disc Golf Flight Lab.
 *
 * Three jobs only:
 *   1. Point both mode links at the Godot export using the Vite base URL, so
 *      they are correct both at `/` (dev) and `/godot-ai-test/` (Pages).
 *   2. Carry the chosen mode through on the query string. One export serves
 *      both modes; `game/scripts/ui/puzzle/mode_boot.gd` reads
 *      `location.search` because Godot's web shell does not forward the query
 *      string into `OS.get_cmdline_args()`.
 *   3. Refuse to launch — with an explanation — when the browser cannot give
 *      Godot the WebGL2 context it requires.
 */

const GAME_PATH = `${import.meta.env.BASE_URL}game/index.html`;

/** id -> query string appended to the game URL. */
const MODES = {
  'launch-lab': '',
  'launch-puzzle': '?mode=puzzle',
};

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
  const notice = document.querySelector('#notice');
  const links = Object.keys(MODES)
    .map((id) => ({ id, el: document.querySelector(`#${id}`) }))
    .filter((entry) => entry.el);
  if (!links.length || !notice) return;

  // Authoritative hrefs, derived from the base Vite was actually built with.
  for (const { id, el } of links) {
    el.setAttribute('href', GAME_PATH + MODES[id]);
  }

  const webgl = checkWebGL2();
  if (!webgl.ok) {
    for (const { el } of links) {
      el.classList.add('is-disabled');
      el.setAttribute('aria-disabled', 'true');
      el.addEventListener('click', (event) => event.preventDefault());
    }
    notice.textContent = webgl.reason;
    notice.hidden = false;
    return;
  }

  // The engine download is large enough that the navigation itself can feel
  // unresponsive. Give immediate feedback while the browser gets on with it.
  for (const { el } of links) {
    el.addEventListener('click', () => {
      if (el.classList.contains('is-disabled')) return;
      el.classList.add('is-loading');
      const go = el.querySelector('.mode-go');
      if (go) go.textContent = 'Loading engine…';
    });
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}
