import Foundation

/// JavaScript injected into the Google Messages page. Each script follows the behavior of
/// a script embedded in Texty 1.3.13 (Resources/CustomScript.js plus string literals in the
/// main executable); they are rewritten here rather than copied.
enum WebScripts {
    // Message handler names used by the page -> native bridge.
    static let notifyHandler = "notify"
    static let ajaxHandler = "ajaxFinished"
    static let consoleHandler = "consoleLog"
    static let loadedHandler = "conversationsLoaded"
    static let sendButtonHandler = "sendButtonLocation"
    static let unreadHandler = "unreadCount"

    /// Forwards console output to the native Console Output window.
    static let consoleRedirect = #"""
    (function() {
        const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.consoleLog;
        if (!h) { return; }
        ['log', 'error', 'warn', 'info'].forEach(function(name) {
            const original = console[name];
            console[name] = function() {
                try {
                    const parts = Array.prototype.map.call(arguments, function(a) {
                        if (typeof a === 'string') { return a; }
                        try { return JSON.stringify(a); } catch (e) { return String(a); }
                    });
                    h.postMessage({ type: name, message: parts.join(' ') });
                } catch (e) {}
                return original.apply(console, arguments);
            };
        });
    })();
    """#

    /// Core helper: notification bridge, draft persistence across reloads, and XHR hook
    /// that reports page state (composer / start-chat button present) to native code.
    static let helper = #"""
    (function() {
        if (window.__sideTextHelperInstalled) { return; }
        window.__sideTextHelperInstalled = true;

        const TEXTAREA = 'textarea[data-e2e-message-input-box]';
        const DRAFT_KEY = 'sidetext-draft';

        // ---- Notification bridge -------------------------------------------------
        function post(name, payload) {
            try { window.webkit.messageHandlers[name].postMessage(payload); } catch (e) {}
        }
        function plain(value, depth) {
            depth = depth || 0;
            if (value == null || depth > 6) { return null; }
            const t = typeof value;
            if (t === 'string' || t === 'number' || t === 'boolean') { return value; }
            if (Array.isArray(value)) { return value.map(function(v) { return plain(v, depth + 1); }); }
            if (t === 'object') {
                const out = {};
                Object.keys(value).forEach(function(k) {
                    const v = value[k];
                    if (typeof v !== 'function') { out[k] = plain(v, depth + 1); }
                });
                return out;
            }
            return null;
        }
        class NotificationShim {
            static get permission() { return 'granted'; }
            static requestPermission(cb) {
                if (typeof cb === 'function') { cb('granted'); }
                return Promise.resolve('granted');
            }
            constructor(title, options) {
                this.title = title;
                this.options = options || {};
                this.onclick = null;
                this.onclose = null;
                post('notify', { title: String(title || ''), options: plain(this.options) || {} });
            }
            close() {}
            addEventListener() {}
            removeEventListener() {}
        }
        window.Notification = NotificationShim;
        // Service-worker notifications go through registration.showNotification; route those too.
        try {
            if (window.ServiceWorkerRegistration) {
                ServiceWorkerRegistration.prototype.showNotification = function(title, options) {
                    post('notify', { title: String(title || ''), options: plain(options) || {} });
                    return Promise.resolve();
                };
            }
        } catch (e) {}

        // ---- Draft persistence ---------------------------------------------------
        function restoreDraft() {
            const draft = sessionStorage.getItem(DRAFT_KEY);
            if (!draft) { return true; }
            const box = document.querySelector(TEXTAREA);
            if (!box) { return false; }
            box.value = draft;
            box.dispatchEvent(new Event('input', { bubbles: true }));
            sessionStorage.removeItem(DRAFT_KEY);
            return true;
        }
        window.addEventListener('pagehide', function() {
            const box = document.querySelector(TEXTAREA);
            if (box && box.value) { sessionStorage.setItem(DRAFT_KEY, box.value); }
        });
        function waitForDraftTarget() {
            if (restoreDraft()) { return; }
            const obs = new MutationObserver(function() { if (restoreDraft()) { obs.disconnect(); } });
            obs.observe(document.documentElement, { childList: true, subtree: true });
            setTimeout(function() { obs.disconnect(); }, 30000);
        }
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', waitForDraftTarget);
        } else {
            waitForDraftTarget();
        }

        // ---- XHR state reporting -------------------------------------------------
        let lastSignature = null;
        const originalOpen = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function() {
            if (!this.__sideTextHooked) {
                this.__sideTextHooked = true;
                this.addEventListener('loadend', () => {
                    const msg = {
                        status: this.status,
                        currentURL: location.href,
                        responseURL: this.responseURL || '',
                        inputBoxExists: document.querySelector('.input-box, ' + TEXTAREA) != null,
                        newMessageButtonExists: document.querySelector('[data-e2e-start-button]') != null
                    };
                    const sig = [msg.status, msg.currentURL, msg.inputBoxExists, msg.newMessageButtonExists].join('|');
                    if (sig === lastSignature) { return; }
                    lastSignature = sig;
                    post('ajaxFinished', msg);
                });
            }
            return originalOpen.apply(this, arguments);
        };

        // ---- Unread count --------------------------------------------------------
        // Counts conversation-list rows marked unread; reported only when it changes.
        let lastUnread = -1;
        function countUnread() {
            const items = document.querySelectorAll('mws-conversation-list-item');
            let n = 0;
            items.forEach(function(item) {
                const a = item.querySelector('a');
                if (item.querySelector('.unread') || (a && /\bunread\b/.test(a.className))) { n += 1; }
            });
            if (n !== lastUnread) {
                lastUnread = n;
                post('unreadCount', { count: n, rows: items.length });
            }
        }
        setInterval(countUnread, 2000);
    })();
    """#

    /// Turns on spellcheck/autocorrect in the composer.
    static let spellcheck = #"""
    (function() {
        function apply() {
            const el = document.querySelector('textarea[data-e2e-message-input-box]') ||
                       document.querySelector('.input textarea, textarea.input');
            if (!el || el.getAttribute('data-sidetext-spellcheck') === '1') { return; }
            el.setAttribute('spellcheck', 'true');
            el.setAttribute('autocorrect', 'on');
            el.setAttribute('data-sidetext-spellcheck', '1');
        }
        apply();
        const obs = new MutationObserver(function() { apply(); });
        const start = function() { obs.observe(document.body || document.documentElement, { childList: true, subtree: true }); };
        if (document.readyState === 'loading') { document.addEventListener('DOMContentLoaded', start); } else { start(); }
    })();
    """#

    /// Forces a font stack with Apple Color Emoji so emoji render inside WKWebView.
    static let emojiCSS = #"""
    (function() {
        const css = 'html, body, * { font-family: -apple-system, system-ui, "SF Pro Text", "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji", sans-serif !important; font-variant-emoji: emoji !important; } mat-icon, .material-icons, .material-symbols-outlined, .google-symbols, [class*="material-symbol"], [class*="google-symbol"] { font-family: inherit; }';
        function install() {
            const head = document.head || document.documentElement;
            if (!head) { return; }
            let el = document.getElementById('sidetext-emoji-font');
            if (!el) {
                el = document.createElement('style');
                el.id = 'sidetext-emoji-font';
                el.textContent = css;
            }
            head.appendChild(el);
        }
        install();
        document.addEventListener('DOMContentLoaded', install, { once: true });
    })();
    """#

    /// Reports when the conversation list has rendered so queued replies can be sent.
    static let conversationsLoaded = #"""
    (function() {
        let reported = false;
        function onConversations() {
            const p = location.pathname || '';
            return p === '/web/conversations' || p.startsWith('/web/conversations/') ||
                   /^\/web\/u\/\d+\/conversations(\/.*)?$/.test(p);
        }
        function uiReady() {
            return document.querySelector('textarea[data-e2e-message-input-box]') ||
                   document.querySelector('[data-e2e-conversation-list]') ||
                   document.querySelector('mws-conversations-list') ||
                   document.querySelector('mws-conversation-list-item');
        }
        function check() {
            if (onConversations() && uiReady()) {
                if (!reported) {
                    reported = true;
                    try { window.webkit.messageHandlers.conversationsLoaded.postMessage({ url: location.href }); } catch (e) {}
                }
            } else if (!onConversations()) {
                reported = false;
            }
        }
        setInterval(check, 500);
    })();
    """#

    /// Strips Google's custom scroll bar CSS when native scroll bars are selected.
    /// Exposes window.SideText.setScrollbarMode('system' | 'google').
    static let scrollbar = #"""
    (function() {
        window.SideText = window.SideText || {};
        let mode = 'google';
        let observer = null;
        function isScrollbarRule(text) {
            return text && (text.indexOf('scrollbar-width') !== -1 || text.indexOf('scrollbar-color') !== -1 ||
                            text.indexOf('::-webkit-scrollbar') !== -1);
        }
        function strip(sheet) {
            let rules;
            try { rules = sheet.cssRules; } catch (e) { return; }
            if (!rules) { return; }
            for (let i = rules.length - 1; i >= 0; i--) {
                const rule = rules[i];
                let text = '';
                try { text = rule.cssText || ''; } catch (e) { continue; }
                if (rule.cssRules && rule.cssRules.length) { strip(rule); continue; }
                if (!isScrollbarRule(text)) { continue; }
                if ((rule.selectorText || '').indexOf('::-webkit-scrollbar') !== -1) {
                    try { sheet.deleteRule(i); } catch (e) {}
                    continue;
                }
                try { rule.style.removeProperty('scrollbar-width'); rule.style.removeProperty('scrollbar-color'); } catch (e) {}
            }
        }
        function stripAll() {
            if (mode !== 'system') { return; }
            for (const sheet of Array.from(document.styleSheets)) { strip(sheet); }
        }
        window.SideText.setScrollbarMode = function(value) {
            mode = value;
            if (mode === 'system') {
                stripAll();
                if (!observer && document.head) {
                    observer = new MutationObserver(function() { setTimeout(stripAll, 0); });
                    observer.observe(document.head, { childList: true });
                }
            } else if (observer) {
                observer.disconnect();
                observer = null;
                location.reload();
            }
            return true;
        };
    })();
    """#

    /// On the Google Messages settings page, hide web notification options (the app
    /// manages notifications natively) and make sure notifications stay on.
    static let settingsPage = #"""
    (function() {
        function isOn(el) {
            const aria = el.getAttribute('aria-checked');
            if (aria === 'true') { return true; }
            if (aria === 'false') { return false; }
            return el.classList.contains('mdc-switch--selected') || el.classList.contains('mat-mdc-slide-toggle-checked');
        }
        function tweak() {
            ['[data-e2e-setting-preview]', '[data-e2e-setting-audio-notifications]'].forEach(function(sel) {
                const el = document.querySelector(sel);
                if (el) { el.remove(); }
            });
            const n = document.querySelector('[data-e2e-setting-notifications]');
            if (n) {
                const t = n.querySelector("button[role='switch']") || n.querySelector('.mat-mdc-slide-toggle button');
                if (t && !isOn(t)) { t.click(); }
                n.remove();
            }
        }
        tweak();
        const obs = new MutationObserver(tweak);
        obs.observe(document.body || document.documentElement, { childList: true, subtree: true });
        setTimeout(function() { obs.disconnect(); }, 8000);
    })();
    """#

    /// On the QR pairing page, switch on "Remember this computer".
    static let authPage = #"""
    (function() {
        function isOn(el) {
            const aria = el.getAttribute('aria-checked');
            if (aria === 'true') { return true; }
            if (aria === 'false') { return false; }
            return el.classList.contains('mdc-switch--selected') || el.classList.contains('mat-mdc-slide-toggle-checked');
        }
        function apply() {
            const el = document.getElementById('mat-mdc-slide-toggle-0-button') ||
                       document.getElementById('mat-mdc-slide-toggle-1-button') ||
                       document.querySelector("mws-authentication-container button[role='switch'], button[role='switch']");
            if (!el) { return false; }
            if (!isOn(el)) { el.click(); }
            return true;
        }
        if (apply()) { return; }
        const obs = new MutationObserver(function() { if (apply()) { obs.disconnect(); } });
        obs.observe(document.body || document.documentElement, { childList: true, subtree: true });
        setTimeout(function() { obs.disconnect(); }, 8000);
    })();
    """#

    /// Google sign-in passkeys do not work inside WKWebView. Point at "Try another way".
    static func passkeyHint(title: String, message: String) -> String {
        let t = jsString(title), m = jsString(message)
        return #"""
        (function() {
            const TITLE = \#(t), MESSAGE = \#(m);
            let attempts = 0;
            const timer = setInterval(function() {
                attempts += 1;
                const btn = document.querySelector('button[name="action"][value="2"]') ||
                            Array.from(document.querySelectorAll('button, [role="button"]')).find(function(b) {
                                return /try another way/i.test(b.textContent || '');
                            });
                if (btn) {
                    clearInterval(timer);
                    show(btn);
                } else if (attempts > 40) {
                    clearInterval(timer);
                }
            }, 250);
            function show(btn) {
                const style = document.createElement('style');
                style.textContent = '#sidetext-passkey{position:fixed;max-width:320px;padding:10px 12px;border-radius:10px;font:13px -apple-system;z-index:2147483647;pointer-events:none;box-shadow:0 10px 30px rgba(0,0,0,.22);background:rgba(245,245,247,.98);color:#1d1d1f;border:1px solid rgba(0,0,0,.1)}@media (prefers-color-scheme: dark){#sidetext-passkey{background:rgba(32,33,36,.96);color:#fff;border-color:rgba(255,255,255,.1)}}#sidetext-passkey b{display:block;margin-bottom:4px}[data-sidetext-highlight]{outline:2px solid rgba(10,132,255,.85)!important;outline-offset:3px!important;border-radius:6px!important}';
                document.head.appendChild(style);
                btn.setAttribute('data-sidetext-highlight', '1');
                const pop = document.createElement('div');
                pop.id = 'sidetext-passkey';
                const b = document.createElement('b'); b.textContent = TITLE;
                const p = document.createElement('div'); p.textContent = MESSAGE;
                pop.appendChild(b); pop.appendChild(p);
                document.body.appendChild(pop);
                function place() {
                    const r = btn.getBoundingClientRect();
                    const w = pop.offsetWidth, h = pop.offsetHeight;
                    let left = Math.max(10, Math.min(r.left + r.width / 2 - w / 2, innerWidth - w - 10));
                    let top = r.top - h - 12;
                    if (top < 10) { top = r.bottom + 12; }
                    pop.style.left = left + 'px'; pop.style.top = top + 'px';
                }
                place();
                addEventListener('resize', place, true);
                addEventListener('scroll', place, true);
                setTimeout(function() { pop.remove(); style.remove(); btn.removeAttribute('data-sidetext-highlight'); }, 12000);
            }
        })();
        """#
    }

    /// Hides the "Send feedback" link on Google's unable-to-connect page.
    static let hideFeedbackLink = #"""
    (function() {
        const l = document.getElementsByClassName('footer-link feedback');
        if (l.length) { l[0].style.display = 'none'; }
    })();
    """#

    /// Opens a conversation by id, or by matching the visible name/snippet in the list.
    /// Returns the matched conversation id (or null).
    static func selectConversation(cid: String?, name: String?, phone: String?, snippet: String?) -> String {
        #"""
        (function() {
            const cid = \#(jsString(cid ?? "")), name = \#(jsString(name ?? "")),
                  phone = \#(jsString(phone ?? "")), snippet = \#(jsString(snippet ?? ""));
            const items = Array.from(document.querySelectorAll('mws-conversation-list-item'));
            function idOf(item) {
                const a = item.querySelector('a');
                const href = a && a.getAttribute('href');
                return href ? href.split('/').pop() : null;
            }
            if (cid) {
                for (const item of items) {
                    if (idOf(item) === cid) { item.querySelector('a').click(); return cid; }
                }
            }
            function find(useSnippet) {
                for (const item of items) {
                    const n = (item.querySelector('[data-e2e-conversation-name]') || {}).innerText;
                    const s = (item.querySelector('[data-e2e-conversation-snippet] span') || {}).innerText;
                    const nameMatch = n && (n.trim() === name || (phone && n.trim() === phone));
                    const snippetMatch = !useSnippet || (s && snippet && s.trim().indexOf(snippet.trim().slice(0, 40)) !== -1);
                    if (nameMatch && snippetMatch) {
                        const a = item.querySelector('a');
                        if (a) { a.click(); return idOf(item); }
                    }
                }
                return null;
            }
            return find(true) || find(false);
        })();
        """#
    }

    /// Fills the composer and reports the enabled Send button's position to native code,
    /// which then clicks it with a real mouse event (synthetic DOM clicks are ignored by
    /// the Google Messages composer in some states).
    static func fillReply(_ text: String) -> String {
        #"""
        (function() {
            const body = \#(jsString(text));
            const box = document.querySelector('textarea[data-e2e-message-input-box]');
            if (!box) { return 'missing'; }
            box.focus();
            box.value = body;
            box.dispatchEvent(new Event('input', { bubbles: true }));
            box.dispatchEvent(new Event('change', { bubbles: true }));
            function visibleButton() {
                return Array.from(document.querySelectorAll('button[data-e2e-send-text-button]'))
                    .find(function(b) { return b.offsetParent !== null && !b.disabled && b.getAttribute('disabled') == null; });
            }
            function report(btn) {
                const r = btn.getBoundingClientRect();
                window.webkit.messageHandlers.sendButtonLocation.postMessage({
                    x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2)
                });
            }
            let done = false;
            function attempt() {
                if (done) { return true; }
                const btn = visibleButton();
                if (btn) { done = true; report(btn); return true; }
                return false;
            }
            setTimeout(function() {
                if (attempt()) { return; }
                const obs = new MutationObserver(function() { if (attempt()) { obs.disconnect(); } });
                obs.observe(document.body, { childList: true, subtree: true, attributes: true });
                setTimeout(function() { obs.disconnect(); if (!done) { window.webkit.messageHandlers.sendButtonLocation.postMessage({ error: 'timeout' }); } }, 10000);
            }, 200);
            return 'filled';
        })();
        """#
    }

    static let composerState = #"""
    (function() {
        const box = document.querySelector('textarea[data-e2e-message-input-box]');
        if (!box) { return 'missing'; }
        return box.value.length === 0 ? 'cleared' : 'not-cleared';
    })();
    """#

    static let domClickSend = #"""
    (function() {
        const btn = Array.from(document.querySelectorAll('button[data-e2e-send-text-button]'))
            .find(function(b) { return b.offsetParent !== null; });
        if (btn) { btn.click(); return true; }
        return false;
    })();
    """#

    static let startNewMessage = #"""
    (function() {
        const b = document.querySelector('[data-e2e-start-button]');
        if (b) { b.click(); return true; }
        return false;
    })();
    """#

    static let downloadFilename = #"""
    (function() {
        const el = document.activeElement;
        if (!el) { return null; }
        const f = el.closest('.file-attachment-msg');
        const n = f && f.querySelector('.filename');
        return n ? n.textContent.trim() : null;
    })();
    """#

    /// JSON-encodes a Swift string as a JavaScript string literal.
    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }
}
