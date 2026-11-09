// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

export const SPACES = [
  { name: "Personal", glyph: "i-moon", profile: "personal", page: "wp-orion" },
  { name: "Work", glyph: "i-case", profile: "work", page: "gh-artemis" },
  { name: "Skye", glyph: "i-leaf", profile: "personal", page: "osm-skye" },
];
const WP = "en.wikipedia.org";
// tab: [title, host, favicon, page]; a tab with no page opens the model note; the first Today tab is selected
export const TABS = [
  {
    pinned: [
      ["Notion", "www.notion.so", "notion"],
    ],
    today: [
      ["Orion (constellation) - Wikipedia", WP, "wikipedia", "wp-orion"],
      ["Sourdough - Wikipedia", WP, "wikipedia", "wp-sourdough"],
      ["Night sky - Wikipedia", WP, "wikipedia"],
    ],
  },
  {
    pinned: [
      ["Slack", "app.slack.com", "slack"],
      ["Linear", "linear.app", "linear"],
    ],
    today: [
      ["artemisbrowser/artemis", "github.com", "github", "gh-artemis"],
      ["Figma", "www.figma.com", "figma"],
      ["Google Calendar", "calendar.google.com", "calendar"],
    ],
  },
  {
    pinned: [["Gmail", "mail.google.com", "gmail"]],
    today: [
      ["OpenStreetMap", "www.openstreetmap.org", "osm", "osm-skye"],
      ["Isle of Skye - Wikipedia", WP, "wikipedia", "wp-skye"],
    ],
  },
];
export const HISTORY = [
  ["Betelgeuse - Wikipedia", WP, "wikipedia", "wp-betelgeuse"],
];
export const SITE_SECTIONS = [
  ["top", "Overview", "Top of the page"],
  ["native", "Native", "Made for macOS 26"],
  ["privacy", "Privacy", "Private by default"],
  ["spaces", "Spaces", "Spaces and profiles"],
  ["command-bar", "Command bar", "Try it on this page"],
  ["split-view", "Split view", "Up to four pages side by side"],
  ["shape", "Make it yours", "Yours to shape"],
  ["open-source", "Open source", "GPL 3.0, on GitHub"],
  ["fin", "Made by Fin", "A note, and the download"],
];
export const ICONS = [
  ["rigel", "Rigel", "blue", "#9AC0E9", "#4A8FD8"],
  ["aurora", "Aurora", "green", "#57C89A", "#2F8F68"],
  ["hydrogenAlpha", "Hydrogen-alpha", "rose red", "#DA8097", "#C2385A"],
  ["oxygenIII", "Oxygen III", "teal", "#40CCD8", "#1F8F99"],
  ["neptune", "Neptune", "deep blue", "#6785DC", "#2A4FB8"],
  ["mars", "Mars", "rust", "#D98B6B", "#B5562E"],
  ["betelgeuse", "Betelgeuse", "orange", "#E8A77C", "#D9702A"],
  ["io", "Io", "sulphur yellow", "#E2BF55", "#B8921F"],
  ["moon", "The Moon", "grey", "#AEB1B6", "#7B8088"],
  ["cosmicLatte", "Cosmic Latte", "beige", "#CCBEA9", "#A8906C"],
];
