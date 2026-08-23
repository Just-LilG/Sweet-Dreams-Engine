export function exec(command) {
    return new Promise((resolve, reject) => {
        if (typeof ksu === 'undefined') {
            console.warn('[Bridge] ksu not found. Mock:', command);
            resolve('');
            return;
        }
        const cb = `exec_cb_${Date.now()}_${Math.random().toString(36).substring(2)}`;
        window[cb] = (errno, stdout, stderr) => {
            delete window[cb];
            if (errno !== 0) reject(new Error(stderr || stdout || 'error'));
            else resolve(stdout);
        };
        try {
            ksu.exec(command, `window.${cb}`);
        } catch (e) {
            reject(e);
        }
    });
}

// Native fullscreen — this is the real, documented KernelSU WebUI API (the
// `kernelsu` npm package's `fullScreen()`, backed by window.ksu.fullScreen
// under the hood, same as exec() above). This is what actually hides the
// system status bar for the WebView host, unlike the `settings put global
// policy_control` approach tried previously — that's a legacy debug hook
// that's been progressively locked down on newer Android versions and
// isn't guaranteed to do anything on a modern build. Returns true if the
// call was made, false if this WebView host doesn't expose the API (older
// manager builds) so the caller can fall back gracefully.
export function fullScreen(enabled) {
    try {
        if (typeof ksu !== 'undefined' && typeof ksu.fullScreen === 'function') {
            ksu.fullScreen(enabled);
            return true;
        }
    } catch (e) {
        console.warn('[Bridge] fullScreen call failed:', e);
    }
    return false;
}
