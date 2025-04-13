import { defineConfig } from "vite";

export default defineConfig({
  base: "/",
  root: "./",
  build: {
    minify: false,
  },
  plugins: [],
  server: {
    host: "0.0.0.0",
  },
});
