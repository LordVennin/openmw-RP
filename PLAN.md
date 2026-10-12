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

**Instruct templates, not the embedded chat template.** Phase 3's prompt builder formats the prompt itself with SillyTavern-style instruct templates and sends it to llama-server's raw text-completion endpoint (`openmw.llm.request(body, cb, { endpoint = 'completion' })`), with the template's sequences as stop strings. It does not rely on the chat template embedded in the model file.
- **Why:** the roleplay fine-tune produces broken, repetitive output through `/v1/chat/completions`, but works through text completion when driven the way SillyTavern does it.
- **Gemma 4 sequences:** `<|turn>system`, `<|turn>user` and `<|turn>model`, each turn closed with `<turn|>`. Stop on `<turn|>` and `<|turn>`.
- **Templates are data:** templates live in Lua data, so supporting another model family means adding a template, not changing C++.

**No emojis or other glyphs the game fonts can't draw.** OpenMW renders text with its own font system, so emojis (and any character missing from the game font) don't display. Handle this in two places:
- **Prompt:** tell the model in the system prompt not to use emojis.
- **Reply sanitizer:** strip unsupported characters in Lua before text reaches the chat window. Models still emit emojis now and then, so the sanitizer is the real guarantee.

Phase 2 testing confirmed that emojis come through `openmw.llm` and json.lua intact as UTF-8; they just can't be drawn.

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
- [x] Phase 2: add the async HTTP request (a header-only library like cpp-httplib keeps dependencies simple) and test it from the Lua console.
- [ ] Phase 2.5: bundle llama-server in CMake; the game auto-launches it. Also add user-facing context settings: one context size feeds both llama-server's `-c` and the mod's prompt budget (`scripts/llm/budget.lua`).
- [x] Phase 3: write the Lua mod: card loader, prompt builder, chat window. Built as a text input inside the vanilla dialogue window (see below).
- [ ] Phase 3.5: launcher AI tab: GPU detection, model download, settings.
- [ ] Phase 4: add game actions, memory, and the lorebook.

Phases 2.5 and 3.5 come from [DISTRIBUTION.md](DISTRIBUTION.md), which covers bundling llama-server and the launcher AI tab.

After phase 2, everything else is Lua with hot reloading, which iterates much faster than rebuilding C++.

## Phase 3: AI dialogue in the dialogue window

The player talks to any NPC in their own words from the vanilla dialogue window. The NPC's reply appears in the history like a normal response, with topic links.

**Engine (small C++ changes):**
- The dialogue window has a hidden single-line text input (`openmw_dialogue_window.layout`, `mwgui/dialogue.cpp`).
- Pressing Enter sends the `DialogueTextInput` event (`{ actor, text }`) to player scripts.
- `openmw.llm.setDialogueInput{ visible, enabled, hint }` and `openmw.llm.addDialogueResponse(text, { title })` drive the window from Lua.

**Mod** (built-in: `files/data/scripts/llm/`, registered in `builtin.omwscripts`; settings page "AI Dialogue"):
- **`player.lua`** ties it together. It keeps a per-NPC history, saved with the game: the last 20 exchanges for each of the 30 most recent NPCs. Vanilla greetings and clicked topics become context. `I.LLMDialogue.lastPrompt()` shows the last prompt sent.
- **`cards.lua`** loads SillyTavern V2 cards from `llm/cards/<record id>.json`. Every other NPC gets a card built from game data by **`generated.lua`**.
- **`prompt.lua`** + **`templates.lua`** build the prompt from an instruct template, with SillyTavern's samplers and stop strings.
- **`scene.lua`** builds the `[Scene]` note: place, time, weather, both characters, nearby people, doors and things. It is capped, in words, and rebuilt for every request.
- **`knowledge.lua`** builds a lorebook from vanilla dialogue. When a topic is mentioned, the NPC's vanilla answer is added, using the first line whose filters and conditions pass. Lines gated on script variables or death counts are skipped.
- **`budget.lua`** derives every limit from one context size.
- **`sanitize.lua`** strips characters the game font can't draw, and leaked special tokens.

## Dev setup

llama.cpp is built with CUDA in `~/llm/llama.cpp`, outside this repo, and runs on an RTX 4090 (24 GB).

**Models** (in `~/llm/models/`):

| File | Source | Template | Notes |
|---|---|---|---|
| `Gemma4-12B-RP.i1-Q6_K.gguf` (9.8 GB) | [mradermacher](https://huggingface.co/mradermacher/Gemma4-12B-RP-i1-GGUF) | Gemma 4 | **Default for development.** |
| `gemma-4-12b-marvin-gutenberg-rp-v2.Q6_K.gguf` (9.8 GB) | [mradermacher](https://huggingface.co/mradermacher/gemma-4-12b-marvin-gutenberg-rp-v2-GGUF) | Gemma 4 | Good alternative. |
| `TheDrummer_Rocinante-XL-16B-v1-Q5_K_M.gguf` (11.7 GB) | [bartowski](https://huggingface.co/bartowski/TheDrummer_Rocinante-XL-16B-v1-GGUF) | Metharme or Mistral Tekken | Mistral Nemo based; richest prose. |
| `gemma-4-12b-it-Q6_K.gguf` (9.8 GB) | [unsloth](https://huggingface.co/unsloth/gemma-4-12b-it-GGUF) | Gemma 4 | Base model. |
| `gemma-4-12b-it-roleplay-sft-epoch2-bf16.Q6_K.gguf` (9.8 GB) | [mradermacher](https://huggingface.co/mradermacher/gemma-4-12b-it-roleplay-sft-epoch2-bf16-GGUF) | Gemma 4 | **Broken on this llama.cpp build:** gibberish even through SillyTavern, though it works in oobabooga. Don't use. |

**Launch command:**

```
~/llm/llama.cpp/build/bin/llama-server -m ~/llm/models/Gemma4-12B-RP.i1-Q6_K.gguf -ngl 99 -c 8192 --jinja --port 8080
```

The mod uses the text-completion endpoint `http://localhost:8080/completion`. Set **AI Dialogue → Advanced → Instruct Template** to match the model: Gemma 4 for the Gemma models; Metharme or Mistral Tekken for Rocinante.

**Model comparison** (Oct 12, 2026). Every model got the same prompt built by the mod: Fargoth's card, the scene and knowledge notes, the vanilla greeting, two turns of the ring conversation, then "what can you offer me for this ring?". Each model ran five fixed seeds with the mod's samplers.
- **Gemma4-12B-RP:** 5/5 clean; the most grounded in the card (Sellus Gravius, Elone, Arrille's tradehouse, glances at the lighthouse); concise; always stops on its own.
- **marvin-gutenberg-rp-v2:** 5/5 clean, very in character.
- **Rocinante XL 16B:** 5/5 clean in both formats; the richest prose. It makes factual slips (Arrille as a woman and a "fence", "gold crowns") and writes long, so 4/5 replies hit the 170-token limit. It would want a higher reply length, and Phase 4's lorebook.
- **Base Gemma 4:** 5/5 clean but generic.
- **The first roleplay fine-tune:** 0/5, gibberish. That upload is the problem, not Gemma 4 fine-tunes in general.

**Gemma 4 needs an empty thought block before each reply** (`<|channel>thought\n<channel|>`, the `replyPrefix` in `scripts/llm/templates.lua`). Without it, replies are full of misspellings and nonsense words.

**Base model on the chat endpoint:** Gemma 4 thinks by default. Unless a `/v1/chat/completions` request includes `"chat_template_kwargs": {"enable_thinking": false}`, it can spend the whole token budget reasoning and return an empty `content`.

**SillyTavern against llama-server:** set DRY's sequence breakers to a non-empty list (for example `["\n", ":", "\"", "*"]`). llama-server rejects an empty list.

**VRAM:** with a 9.8 GB model and an 8K context, the GPU used about 13.4 GB of 24 GB in total, including about 2 GB already used by the desktop. That leaves about 10 GB for Morrowind. Rocinante Q5_K_M uses about 2 GB more.
