// SPDX-FileCopyrightText: 2026 Lukas Backström <lukas@erlang.org>
// SPDX-License-Identifier: Apache-2.0

import js from "@eslint/js";
import globals from "globals";

export default [
  js.configs.recommended,
  {
    files: ["priv/dashboard.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "script",
      globals: {
        ...globals.browser,
        // Globals injected by the surrounding <script> block in
        // lib/mix/tasks/awfy.compare.ex (see page_template/1).
        PAGE_KIND: "readonly",
        BENCH_NAME: "readonly",
        BASELINE_LABEL: "readonly",
        DATASET: "readonly",
        MAX_RELEASED_MAJOR: "readonly",
        // Chart.js loaded from CDN.
        Chart: "readonly"
      }
    },
    rules: {
      // The dashboard uses unused `_` placeholders in destructuring
      // (e.g. `catch (_)`) — silence those.
      "no-unused-vars": ["error", { argsIgnorePattern: "^_", caughtErrors: "none" }]
    }
  }
];
