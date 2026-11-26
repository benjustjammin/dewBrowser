import Foundation

/// What to do with cookie consent banners.
enum CookieBannerMode: String, CaseIterable, Identifiable {
    case off, reject, accept

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Leave them"
        case .reject: "Reject automatically"
        case .accept: "Accept automatically"
        }
    }
}

/// Clicks "Reject" (or "Accept") on cookie banners for you. Recognises the common consent tools
/// (OneTrust, Cookiebot, Didomi, Quantcast, Usercentrics, TrustArc, Complianz, CookieYes, Osano,
/// iubenda, Google's consent page…) and falls back to a button with a matching label, in several
/// languages, inside something that is clearly a cookie/consent banner. Runs in Dew's own script
/// world in every frame (some banners live in iframes), and never clicks Accept in Reject mode.
enum CookieBanners {
    static func script(mode: CookieBannerMode) -> String? {
        guard mode != .off else { return nil }
        return """
        (() => {
          if (window.__dewCookies) return;
          window.__dewCookies = true;
          const MODE = '\(mode.rawValue)';
          const visible = (el) => el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden';
          const click = (el) => { if (!visible(el)) return false; el.click(); return true; };
          const pick = (selectors) => selectors.split(',').map((s) => document.querySelector(s.trim())).find(visible);

          // [reject, accept] for known consent tools.
          const known = [
            ['#onetrust-reject-all-handler, .ot-pc-refuse-all-handler', '#onetrust-accept-btn-handler'],
            ['#CybotCookiebotDialogBodyButtonDecline, #CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll',
             '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll, #CybotCookiebotDialogBodyButtonAccept'],
            ['#didomi-notice-disagree-button', '#didomi-notice-agree-button'],
            ['.qc-cmp2-summary-buttons button[mode="secondary"]', '.qc-cmp2-summary-buttons button[mode="primary"]'],
            ['#truste-consent-required', '#truste-consent-button'],
            ['.cmplz-btn.cmplz-deny', '.cmplz-btn.cmplz-accept'],
            ['.cky-btn-reject', '.cky-btn-accept'],
            ['.osano-cm-denyAll', '.osano-cm-accept-all'],
            ['.iubenda-cs-reject-btn', '.iubenda-cs-accept-btn'],
            ['.fc-cta-do-not-consent', '.fc-cta-consent'],
            ['[data-cookiefirst-action="reject"]', '[data-cookiefirst-action="accept"]'],
            ['#hs-eu-decline-button', '#hs-eu-confirmation-button'],
            ['.cc-window .cc-deny', '.cc-window .cc-allow'],
            ['button[data-tid="banner-decline"]', 'button[data-tid="banner-accept"]'],
          ];

          const usercentrics = () => {
            const root = document.querySelector('#usercentrics-root, #usercentrics-cmp-ui')?.shadowRoot;
            return !!root && click(root.querySelector(MODE === 'reject' ? '[data-testid="uc-deny-all-button"]' : '[data-testid="uc-accept-all-button"]'));
          };

          const REJECT = ['reject all', 'reject all cookies', 'reject', 'reject cookies', 'no, reject cookies', 'decline all', 'decline',
            'deny all', 'deny', 'refuse all', 'refuse', 'only necessary', 'necessary only', 'only essential', 'essential only',
            'use necessary cookies only', 'allow necessary only', 'only allow essential cookies', 'continue without accepting',
            'alle ablehnen', 'ablehnen', 'nur notwendige', 'tout refuser', 'refuser', 'rifiuta tutto', 'rifiuta',
            'rechazar todo', 'rechazar', 'alles weigeren', 'weigeren', 'odrzuć wszystkie', 'odrzuć'];
          const ACCEPT = ['accept all', 'accept all cookies', 'accept', 'accept cookies', 'allow all', 'allow all cookies', 'allow cookies',
            'yes, allow cookies', 'i agree', 'agree', 'agree and close', 'i accept', 'ok', 'okay', 'got it',
            'alle akzeptieren', 'akzeptieren', 'zustimmen', 'tout accepter', 'accepter', 'accetta tutto', 'accetta',
            'aceptar todo', 'aceptar', 'alles accepteren', 'accepteren', 'akceptuj wszystkie', 'akceptuję'];
          const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim().toLowerCase().replace(/[.!]$/, '');
          // Only buttons inside something that is clearly a cookie/consent banner.
          const inBanner = (el) => {
            for (let n = el.parentElement; n && n !== document.documentElement; n = n.parentElement) {
              const name = ((n.id || '') + ' ' + (typeof n.className === 'string' ? n.className : '')).toLowerCase();
              if (/cookie|consent|gdpr|\\bcmp\\b|privacy-banner|cc-banner/.test(name)) return true;
              const style = getComputedStyle(n);
              if ((style.position === 'fixed' || style.position === 'sticky' || n.getAttribute('role') === 'dialog')
                  && /cookie|consent|datenschutz|cookies/i.test(n.innerText || '')) return true;
            }
            return false;
          };
          const generic = () => {
            const buttons = [...document.querySelectorAll('button, [role="button"], a[role="button"], input[type="button"], input[type="submit"]')]
              .filter(visible);
            for (const word of (MODE === 'reject' ? REJECT : ACCEPT)) {
              for (const b of buttons) {
                const label = norm(b.innerText || b.value || b.getAttribute('aria-label'));
                if (label === word && inBanner(b)) { b.click(); return true; }
              }
            }
            return false;
          };

          let done = false, tries = 0, timer = null;
          const attempt = () => {
            if (done || tries++ > 40) return;
            for (const [reject, accept] of known) {
              const button = pick(MODE === 'reject' ? reject : accept);
              if (button) { button.click(); done = true; break; }
            }
            if (!done && usercentrics()) done = true;
            if (!done && generic()) done = true;
            if (done) observer.disconnect();
          };
          const observer = new MutationObserver(() => { clearTimeout(timer); timer = setTimeout(attempt, 300); });
          observer.observe(document.documentElement, { childList: true, subtree: true });
          attempt();
          setTimeout(attempt, 1200);
          setTimeout(attempt, 3500);
          setTimeout(() => observer.disconnect(), 20000);
        })();
        """
    }
}
