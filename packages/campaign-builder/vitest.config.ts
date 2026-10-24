import { defineConfig } from 'vitest/config';

// tsconfig keeps jsx: "preserve" for Next; tests transform JSX with the automatic runtime.
export default defineConfig({
  oxc: { jsx: { runtime: 'automatic' } },
  test: { environment: 'node' },
});
