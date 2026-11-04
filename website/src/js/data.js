// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

export const SPACES = [
  {
    name: "Personal",
    glyph: "i-moon",
    profile: "personal",
    page: "lowlight-orion",
  },
  { name: "Work", glyph: "i-case", profile: "work", page: "ashgrove-print" },
  { name: "Garden", glyph: "i-leaf", profile: "personal", page: "plot14-sow" },
];
export const HOST = {
  sky: "lowlight.press",
  bake: "slowloaf.kitchen",
  plot: "plot14.garden",
  studio: "wiki.ashgrove.studio",
};
// tab: [title, hostKey, favicon, page or dek]; the first Today tab is selected
export const TABS = [
  {
    pinned: [
      [
        "Recipes to try",
        "bake",
        "slowloaf",
        "Twelve recipes saved for slow weekends.",
      ],
      [
        "Reading list",
        "sky",
        "lowlight",
        "Long reads about the night sky, saved for later.",
      ],
    ],
    today: [
      ["Orion, star by star", "sky", "lowlight", "lowlight-orion"],
      [
        "Sky tonight",
        "sky",
        "lowlight",
        "What’s up after dark this week, and when to look.",
      ],
      ["Sourdough, day six", "bake", "slowloaf", "slowloaf-sourdough"],
      [
        "Choosing binoculars",
        "sky",
        "lowlight",
        "Why 10×50 is where most people start.",
      ],
    ],
  },
  {
    pinned: [
      ["Team calendar", "studio", "studio", "This week at the studio."],
      ["Inbox", "studio", "mail", "Three new messages since this morning."],
    ],
    today: [
      ["Print checklist", "studio", "studio", "ashgrove-print"],
      [
        "Cover photo options",
        "studio",
        "studio",
        "Three shots for the spring cover, with notes.",
      ],
      [
        "Supplier quotes",
        "studio",
        "studio",
        "Paper and binding, side by side.",
      ],
      ["Q4 planning", "studio", "studio", "What ships before the new year."],
    ],
  },
  {
    pinned: [["Plot plan", "plot", "plot", "Where everything goes this year."]],
    today: [
      ["What to sow in November", "plot", "plot", "plot14-sow"],
      ["Garlic varieties to try", "plot", "plot", "plot14-garlic"],
      ["Seed order", "plot", "plot", "Everything to order before spring."],
      [
        "Frost dates",
        "plot",
        "plot",
        "When the first and last frosts usually fall here.",
      ],
      [
        "Compost bin plans",
        "plot",
        "plot",
        "A three-bay bin from old pallets.",
      ],
    ],
  },
];
export const HISTORY = [
  ["Betelgeuse, the red shoulder", "sky", "lowlight", "lowlight-betelgeuse"],
  [
    "Seed potatoes, when to chit",
    "plot",
    "plot",
    "Set them out somewhere light and cool about six weeks before planting.",
  ],
  [
    "Paper weights explained",
    "studio",
    "studio",
    "What the numbers mean, and which to use for covers.",
  ],
];
export const SITE_SECTIONS = [
  ["top", "Overview", "Top of the page"],
  ["window", "Sidebar", "The page gets the whole window"],
  ["spaces", "Spaces", "Separate sets of tabs"],
  ["command-bar", "Command bar", "Try it on this page"],
  ["split-view", "Split view", "Up to four pages side by side"],
  ["privacy", "Privacy", "No account and no telemetry"],
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
