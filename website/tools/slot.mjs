// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import fs from "node:fs";
import path from "node:path";

// Holds one of SHOT_SLOTS (default 2) machine-wide render slots until the process exits.
export async function takeSlot(pwDir) {
  const locks = path.join(pwDir, "locks");
  fs.mkdirSync(locks, { recursive: true });
  for (;;) {
    for (let i = 0; i < +(process.env.SHOT_SLOTS || 2); i++) {
      const p = path.join(locks, `slot${i}`);
      try {
        fs.mkdirSync(p);
        fs.writeFileSync(path.join(p, "pid"), String(process.pid));
        process.on("exit", () => fs.rmSync(p, { recursive: true, force: true }));
        return;
      } catch {
        try {
          process.kill(+fs.readFileSync(path.join(p, "pid"), "utf8"), 0);
        } catch {
          fs.rmSync(p, { recursive: true, force: true });
        }
      }
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
}
