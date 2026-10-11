# OpenMW LLM Roleplay Fork

Oct 11, 2026 · @Vennin

## Feasibility

Yes, this is feasible, and a fork is the right call. OpenMW's Lua scripts run in a sandbox with no access to the operating system ([OpenMW Lua docs](https://openmw-improved-docs.readthedocs.io/en/latest/reference/lua-scripting/overview.html)). That means no sockets and no HTTP, so a plain Lua mod can't reach llama.cpp.

The network call is the only part that needs engine changes. Everything else can be ordinary Lua on top.

## Architecture

The design keeps the C++ fork to one small async HTTP binding and puts everything else in a hot-reloadable Lua mod.

```
Character cards (V2 JSON) --\
                             +--> Lua mod (prompt builder, actions, memory)
Game state (race, faction) --/            ^
                                          |
Chat window (Lua UI) <--> Lua mod <--> openmw.llm (C++ fork patch, async) <--> llama-server (OpenAI-compatible HTTP)
```

Requests flow left to right and streamed replies flow back; only `openmw.llm` lives in C++.

**Keep the C++ patch tiny.** Add one async HTTP binding to the Lua API, such as an `openmw.llm` or `openmw.http` package. It POSTs a JSON body to a local URL and delivers the response, ideally as streamed token chunks, through a callback or event. It must be non-blocking: replies take seconds, and a blocking call freezes the game. Run requests on a worker thread and hand results back on the main thread.

A small patch is the most important design decision. OpenMW moves fast (0.50/0.51 are current), and a fork that touches 30 files is painful to rebase. One module added in `apps/openmw/mwlua/` stays maintainable.

**llama.cpp side.** Use `llama-server`, which exposes an OpenAI-compatible HTTP API. The binding then also works with KoboldCpp, Ollama, LM Studio, or a remote API.

**Character cards in Lua.** SillyTavern cards (the V2 `chara_card_v2` spec) are JSON with fields like `name`, `description`, `personality`, `scenario`, `first_mes`, `mes_example`, `system_prompt`, and an optional `character_book` lorebook. PNG cards store that JSON base64-encoded in a `tEXt` chunk named `chara`.

- Extract cards to JSON ahead of time and ship them in a data folder.
- Map each card to an NPC by record ID.
- Runtime PNG parsing would need more engine work, since Lua reads files only through the VFS.

**Prompt order.** Send the system prompt first, then the card's greeting (`first_mes`) as an assistant message, then the alternating conversation turns, always ending with the user's message.

**Game state goes into the prompt.** This is what makes it feel like Morrowind rather than a chatbot in costume. The Lua API exposes the NPC's race, class, faction and rank, disposition, current cell, time of day, and the player's reputation and some quest state. Inject that into the system prompt each turn. A keyword-triggered lorebook covering the Tribunal, Great Houses, Sixth House and so on does the rest.

**UI.** The vanilla dialogue window is C++/MyGUI and hard to extend. A separate Lua UI chat window with a text input is much easier. Open it from an added topic like "Let's talk," or a hotkey while looking at an NPC.

## Hard parts

Chat alone is straightforward; letting the model change the game is where most of the effort goes.

- **Game actions.** Having an NPC change disposition, give an item, refuse service, or attack needs structured output (tags or JSON) that Lua parses and validates. Small local models are unreliable at this, so use a whitelist and sanity checks.
- **Memory.** Per-NPC history grows fast. Keep rolling summaries and store them with the save via `onSave`/`onLoad`.
- **Canon consistency.** The model will invent quests or talk about dead NPCs as if alive. Feeding real quest and journal state into the prompt helps, but expect some drift.
- **Latency and hardware.** Morrowind is light, so sharing a GPU with a 7–13B model is fine on most setups. Stream tokens into the window so it never feels dead.
- **License.** OpenMW is GPLv3, so the fork stays GPL.

## Using Claude Code

Make "build unmodified OpenMW from source" phase zero: the codebase is large C++ (CMake, OpenSceneGraph, MyGUI, LuaJIT via sol2), and getting it to build is often the biggest early hurdle, especially on Windows.

- [x] Phase 0: get a clean build of unmodified OpenMW running.
- [x] Phase 1: have Claude Code map how an existing Lua package is registered in `apps/openmw/mwlua/`, then add a trivial `openmw.llm.ping()` to prove the plumbing.
- [ ] Phase 2: add the async HTTP request (a header-only library like cpp-httplib keeps dependencies simple) and test it from the Lua console.
- [ ] Phase 2.5: bundle llama-server in CMake; the game auto-launches it.
- [ ] Phase 3: write the Lua mod: card loader, prompt builder, chat window.
- [ ] Phase 3.5: launcher AI tab: GPU detection, model download, settings.
- [ ] Phase 4: add game actions, memory, and the lorebook.

Phases 2.5 and 3.5 come from [DISTRIBUTION.md](DISTRIBUTION.md), which covers bundling llama-server and the launcher AI tab.

After phase 2, everything else is Lua with hot reloading, which iterates much faster than rebuilding C++.

## Dev setup

llama.cpp is built with CUDA in `~/llm/llama.cpp`, outside this repo, and runs on an RTX 4090 (24 GB).

**Models** (both Q6_K, 9.8 GB each, in `~/llm/models/`):

- `gemma-4-12b-it-roleplay-sft-epoch2-bf16.Q6_K.gguf` from [mradermacher](https://huggingface.co/mradermacher/gemma-4-12b-it-roleplay-sft-epoch2-bf16-GGUF). **Default for development.**
- `gemma-4-12b-it-Q6_K.gguf` from [unsloth](https://huggingface.co/unsloth/gemma-4-12b-it-GGUF), the base Gemma 4 model.

**Launch command:**

```
~/llm/llama.cpp/build/bin/llama-server -m ~/llm/models/gemma-4-12b-it-roleplay-sft-epoch2-bf16.Q6_K.gguf -ngl 99 -c 8192 --jinja --port 8080
```

The endpoint is then `http://localhost:8080/v1/chat/completions`. To use the base model, swap the `-m` path.

**Base model needs thinking turned off.** Gemma 4 thinks by default. Unless a request includes `"chat_template_kwargs": {"enable_thinking": false}`, it can spend the whole token budget reasoning and return an empty `content`. The roleplay fine-tune does not need this.

**VRAM:** with either model loaded and an 8K context, the GPU used 13.4 GB of 24 GB in total, including about 2 GB already used by the desktop. That leaves about 10 GB for Morrowind.
