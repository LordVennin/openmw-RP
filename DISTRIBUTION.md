# OpenMW LLM Fork: All-in-One Player Setup

Oct 11, 2026 · @Vennin

Players never touch a terminal: llama.cpp ships with the fork, the launcher handles models, and the game starts the AI server itself. It stays a separate process, keeping the small patch and crash isolation.

## Player experience

A player goes from install to talking NPCs in three steps, with no terminal, console, or config file.

1. Install the OpenMW build. llama.cpp comes bundled with it.
2. Open the launcher's new **AI tab**, pick a model from a short list sized to their GPU, and click Download.
3. Click Play. The game starts the AI server in the background, waits until it's ready, and shuts it down on exit.

The Lua console is only a development tool; players use the in-game chat window.

## What it takes

Five pieces of work make the setup invisible, and none of them require embedding llama.cpp in the game process.

| Piece | What it involves |
| --- | --- |
| Bundle llama.cpp | Add it to OpenMW's CMake as a dependency fetched at build time, so `llama-server` ships next to `openmw`. llama.cpp is MIT licensed, which is fine inside a GPL project. |
| Vulkan for distributed builds | CUDA only works on NVIDIA and means shipping hundreds of MB of libraries. Vulkan works on NVIDIA, AMD and Intel with the driver players already have. CUDA can stay on the dev machine. |
| Auto-launch from the game | OpenMW starts `llama-server` as a hidden child process, picks a free port, polls its health endpoint, and shows "AI loading…" until ready. It cleans up the process on exit or crash. |
| Launcher AI tab | Ordinary Qt UI: GPU and VRAM detection, a recommended-model list, Hugging Face downloads with a progress bar, context size, and a Test button. |
| Model downloads | Model files are 7–13 GB, so the launcher downloads them on first setup instead of shipping them with the game. |

Most Morrowind players are on Windows, so a public release eventually needs Windows builds. Vulkan plus auto-launch makes that much easier.

## Updated phases

The original phases stay; two new ones slot in after phase 2, replacing the old "auto-launch later" idea with a fuller version.

- [x] Phase 0: build unmodified OpenMW from source
- [x] Phase 1: `openmw.llm` Lua package with `ping()`
- [x] Phase 2: async HTTP binding, tested against a hand-run llama-server
- [x] **Phase 2.5 (new):** bundle llama-server in CMake; the game auto-launches it. Expose context settings to users; the same context size drives llama-server's `-c` and the mod's prompt budget.
- [x] Phase 3: Lua mod: card loader, prompt builder, chat window
- [x] **Phase 3.5 (new):** launcher AI tab: GPU detection, model download, settings
- [ ] Phase 4: game actions, memory, and the lorebook

Keep developing against a hand-run server until NPCs are talking; bundling and the launcher tab are easier to get right once the core works.
