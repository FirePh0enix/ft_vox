import { Buffer } from "buffer";
import { init, WASI } from "@wasmer/wasi";
import wasmUrl from "../zig-out/bin/ft_vox.wasm?url";

globalThis.Buffer = Buffer;

document.addEventListener("DOMContentLoaded", async () => {
    await init();

    const wasi = new WASI({
        version: "preview1",
        args: [],
        env: {},
        preopens: {},
    });

    const module = await WebAssembly.compileStreaming(fetch(wasmUrl));

    console.log(getSurface());

    const imports = {
        ...wasi.getImports(module),
        env: {},
    };

    const instance = await WebAssembly.instantiate(module, imports);
    const exit_code = wasi.start(instance);

    console.log(`exited with code ${exit_code}`);
    console.log(wasi.getStderrString());
});

function getSurface() {
    /** @type {HTMLCanvasElement | null} */
    const surface = document.getElementById("surface");
    return surface.getContext("webgpu");
}
