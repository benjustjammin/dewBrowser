import Foundation

/// "Darken pages": when Dew is dark, pages that are still light (no dark mode of their own) are shown dark by
/// inverting their colours and flipping images, video and embedded frames back, so photos keep their colours.
/// Pages with a dark background already (their own dark mode, or a dark design) are left alone. Runs in Dew's
/// own JS world, follows light/dark changes live, and `window.__dewDarkSet(bool)` turns it on or off in place.
enum DarkPages {
    static func script(enabled: Bool) -> String {
        """
        (() => {
          if (window.__dewDarkSet) return;
          const STYLE_ID = '__dew_dark_pages';
          const css = `html { filter: invert(1) hue-rotate(180deg) !important; background-color: #fff !important; }
            img, video, picture, canvas, iframe, embed, object, svg image,
            [style*="background-image"] { filter: invert(1) hue-rotate(180deg) !important; }`;
          const darkMedia = window.matchMedia('(prefers-color-scheme: dark)');
          let enabled = \(enabled);
          let pageIsDark = null;   // decided once per page, before Dew's own style changes anything

          function luminance(colour) {
            const parts = (colour || '').match(/[\\d.]+/g);
            if (!parts || parts.length < 3) return null;
            const [r, g, b, a = 1] = parts.map(Number);
            if (a < 0.1) return null;   // transparent: look further out
            return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
          }

          function measure() {
            for (const el of [document.body, document.documentElement]) {
              if (!el) continue;
              const l = luminance(getComputedStyle(el).backgroundColor);
              if (l !== null) return l < 0.45;
            }
            return false;   // no background at all: the default white canvas
          }

          function apply() {
            if (!document.documentElement) return;
            let style = document.getElementById(STYLE_ID);
            if (pageIsDark === null && document.body) pageIsDark = style ? false : measure();
            const wanted = enabled && darkMedia.matches && pageIsDark === false;
            if (wanted && !style) {
              style = document.createElement('style');
              style.id = STYLE_ID;
              style.textContent = css;
              (document.head || document.documentElement).appendChild(style);
            } else if (!wanted && style) {
              style.remove();
            } else {
              return;
            }
            if (window.__dewThemeResample) window.__dewThemeResample();   // match the toolbar to the new look
          }

          window.__dewDarkSet = (value) => { enabled = !!value; apply(); };
          darkMedia.addEventListener('change', apply);
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', apply);
          else apply();
        })();
        """
    }
}
