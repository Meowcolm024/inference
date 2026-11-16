import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { fileURLToPath } from "node:url";

export default defineConfig({
  plugins: [react()],
  base: "./",
  resolve: { dedupe: ["markdown-it", "react", "react-dom"] },
  worker: { format: "es" },
  build: { target: "es2022" },
  server: {
    fs: {
      allow: [
        fileURLToPath(new URL(".", import.meta.url)),
        fileURLToPath(new URL("../vscode-extension/src", import.meta.url)),
      ],
    },
  },
});
