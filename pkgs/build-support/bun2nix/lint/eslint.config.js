// Forbid raw process.exit() in entrypoints. The bug this catches is a
// kernel-pipe-drain race — `process.stdout.write(big); process.exit(0);`
// truncates output when the consumer is not draining. Use
// `process.exitCode = N; return;` or a flush-aware helper instead.
//
// Per-line escape hatch:
//   // eslint-disable-next-line n/no-process-exit
//   process.exit(1);
//
// `n/no-process-exit` only matches the literal AST shape `process.exit(...)`.
// The two extra rules below close holes the AST selector misses:
// `import { exit } from "node:process"` and `require('process').exit()`.

import n from "eslint-plugin-n";
import tsParser from "@typescript-eslint/parser";

export default [
  {
    files: ["**/*.{ts,tsx,mts,cts,js,mjs,cjs}"],
    languageOptions: {
      parser: tsParser,
      sourceType: "module",
      ecmaVersion: "latest",
    },
    plugins: { n },
    rules: {
      "n/no-process-exit": "error",
      "no-restricted-imports": [
        "error",
        {
          paths: [
            {
              name: "process",
              importNames: ["exit"],
              message:
                "Don't import `exit` — set `process.exitCode = N; return;` instead so stdout/stderr can drain.",
            },
            {
              name: "node:process",
              importNames: ["exit"],
              message:
                "Don't import `exit` — set `process.exitCode = N; return;` instead so stdout/stderr can drain.",
            },
          ],
        },
      ],
      "no-restricted-syntax": [
        "error",
        {
          selector:
            "CallExpression[callee.type='MemberExpression'][callee.property.name='exit'][callee.object.type='CallExpression'][callee.object.callee.name='require'][callee.object.arguments.0.value=/^(node:)?process$/]",
          message:
            "Don't call `require('process').exit()` — set `process.exitCode = N; return;` instead so stdout/stderr can drain.",
        },
      ],
    },
  },
];
