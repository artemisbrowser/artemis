// canonical, og:url, og:image, JSON-LD, sitemap and the link capsule's host.
export const DOMAIN = "artemisbrowser.app";
// a price string such as "Free", or null; adds " {PRICE}." to every fine print line and offers to JSON-LD.
export const PRICE = "Free";
// a release stage such as "Public alpha", or null; leads both fine print lines and joins every description.
export const STAGE = "Public alpha";
// true for an unsigned build: adds the Gatekeeper line and the "How to open it" Peek.
export const UNSIGNED = true;
// the release URL; when set, /download redirects there (302) instead of serving the placeholder page.
export const DOWNLOAD_URL = "https://github.com/artemisbrowser/artemis/releases/download/v0.9.5/Artemis-0.9.5.dmg";
// the Arc block ships only while this is true and src/partials/07-arc.html exists.
export const ARC_BLOCK = true;
// invented demo sites; every registrable domain must be unregistered (rdap.org 404).
export const HOSTS = {
  sky: "lowlight.press",
  bake: "slowloaf.kitchen",
  plot: "plot14.garden",
  studio: "wiki.ashgrove.studio",
};

// Fin's note in the closing section, in his words; it may name Arc in either build.
export const NOTE =
  "Arc felt like heaven. Since it stopped development, I’ve been itching for something better, and more than ever now that Arc is officially being sunset. So I made my own. It has a familiar Arc feel, with a Liquid Glass redesign, extra features and a WebKit base. I think you’ll love it.";
