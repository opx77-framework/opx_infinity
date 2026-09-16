// `tsc` cannot parse a single-file component. This makes `import X from './X.vue'` resolve
// for the plain compiler; `npm run typecheck` runs vue-tsc against ui/tsconfig.app.json,
// which omits this file and checks the real component types instead.
declare module '*.vue' {
  import type { DefineComponent } from 'vue'
  const component: DefineComponent<Record<string, unknown>, Record<string, unknown>, unknown>
  export default component
}
