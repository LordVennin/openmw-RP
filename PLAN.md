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
- [x] Phase 2.5: bundle llama-server in CMake; the game auto-launches it. Also add user-facing context settings: one context size feeds both llama-server's `-c` and the mod's prompt budget (`scripts/llm/budget.lua`). Also a setting for how long an NPC refuses to talk after ending a conversation (off, short, or the current 24h/72h).
- [x] Phase 3: write the Lua mod: card loader, prompt builder, chat window. Built as a text input inside the vanilla dialogue window (see below).
- [x] Phase 3.5: launcher AI tab: GPU detection, model download, settings (see below).
- [ ] Phase 4: add game actions, memory, and the lorebook. In progress:
  - [x] item and gold exchange, confirmed with dialogue choices
  - [x] quest effects and rewards taken from vanilla handover dialogue
  - [x] starter lorebook
  - [x] persuasion by conversation (admire, intimidate, taunt) with vanilla's formula and the player's stats
  - [x] followers: follow, wait, go home
  - [x] rolling memory summaries
  - [x] other actions (attack, ending the conversation)
  - [ ] running vanilla result scripts faithfully (needs an engine binding to execute MWScript)

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

## Phase 4 so far: items, quests and lore

**Item exchange:** nothing changes hands without the player's click.
1. **Before the NPC replies:** if the player's line mentions something they carry, a short check asks the model to quote the words in that line that hand it over. The decision comes from the quote, which must really appear in the line. Small models quote reliably but get a final yes/no wrong.
2. **Confirmation:** a hit shows vanilla-style dialogue choices ("Give X" / "Keep it").
3. **Applying it:** `scripts/llm/global.lua` moves the item, and the reply is written knowing what happened.
4. **After the reply:** a second check looks only for the NPC giving something ("Accept X" / "Refuse").

**Quest effects without per-quest code:** `handover.lua` finds the NPC's vanilla dialogue line whose result script takes the given item from the player. 440 such lines exist in Morrowind.esm. It applies the safe part of that script:
- journal entries;
- the NPC's own variables;
- disposition, the NPC's own and other NPCs' (deferred until that NPC is loaded);
- item rewards;
- faction reputation.

If the player doesn't name an amount, the quest's required amount is offered (e.g. Vodunius Nuccius's 100 drakes). The vanilla reaction line and rewards are given to the model, so the reply plays them out. Optional `llm/quests/*.json` hooks can override auto-detection.

**Intent check:** one check before each reply classifies the player's line as give, admire, intimidate, taunt, follow, wait, dismiss or none. It uses the same evidence-quote method, and got 28/28 live test lines right, including negatives like "should I follow the road north?".

**Persuasion:** `persuasion.lua` is a line-for-line port of `MechanicsManager::getPersuasionDispositionChange`, using the player's and NPC's Speechcraft, Personality, Luck, Reputation, Level and fatigue, and the game's GMSTs. Like vanilla:
- the change is temporary while talking, and only the permanent part remains when the window closes (a successful threat makes the NPC cooperative now and resentful later);
- Speechcraft trains on success and failure;
- the same approach used more than twice in one conversation has no effect.

The model is told the outcome in words, never numbers, and only the bar shows the change.

**Followers:** whether an NPC agrees is decided by `followers.lua`, in this order:
1. **NPCs moved by quests refuse:** their own script, or their vanilla dialogue, calls AiFollow/AiEscort/AiTravel.
2. **Essential NPCs refuse.**
3. **Coerced or outranked NPCs agree even if they dislike the player:** a successful threat in this conversation, or the player outranks them in their faction.
4. **NPCs who like the player agree:** disposition 70, or 85 for NPCs with a job.

The reply comes first, then "Take X along" / "Never mind". `global.lua` keeps a saved follower registry:
- following uses a Follow package, so the NPC goes through doors and fights alongside the player;
- "wait" stands them still;
- "go home" teleports them home once the player has left the cell.

Notices mark each change.

**Knowledge:** an NPC's own topic and their personal topics are always known, alongside mentioned topics, within one shared budget. `Local` conditions are evaluated from a snapshot of the NPC's script variables.

**Hostility and ending the conversation:** Taunt and Intimidate change the NPC's Fight and Flee as in vanilla, through `npc.lua`, a CUSTOM script attached to the NPC (Fight can only be written by a script on the NPC itself). After each attempt, Lua computes the engine's fight term (`getFightTerm`): at 100 or more the NPC attacks, and from 80 they threaten the player. The model is told which, and can't start a fight on its own. The chat ends:
- when the NPC attacks (the engine AI takes over once the window closes);
- when disposition falls to 20 or less;
- when an upset NPC's reply walks away (an evidence check, plus detection of actions like *walks away*).

The player then sees a notice and a single Goodbye choice. The NPC refuses to talk for 24 game hours (72 after an attack), saved with the game.

**Memory:** when a window closes on a history longer than 16 turns, everything but the last 8 turns is summarized in the background, merged with any earlier summary. The summary is saved, given to the model as `[What X remembers]` within its own budget share, and shown first in Recall.

## Phase 2.5: the bundled server

**Build:** `cmake/LlamaServer.cmake` builds llama.cpp `b11559` as a separate project (`ExternalProject`) and copies `llama-server`, its libraries and backend plug-ins to a `llama/` folder next to `openmw`. Backends are plug-ins (`GGML_BACKEND_DL`): one build carries CPU (every instruction-set variant), plus CUDA if a CUDA compiler is found and Vulkan if Vulkan and `glslc` are found. Options:
- `OPENMW_BUNDLE_LLAMA_SERVER` (ON);
- `OPENMW_LLAMA_CUDA` and `OPENMW_LLAMA_VULKAN` (AUTO, ON or OFF);
- `OPENMW_LLAMA_CUDA_ARCHITECTURES` (`native`; a list for releases);
- `OPENMW_LLAMA_SOURCE_DIR` (build from a local checkout instead of downloading).

**Start-up** (`apps/openmw/mwlua/llmserver.cpp`): a monitor thread started with the game.
1. If a server already answers on `[LLM] port`, it is used ("external").
2. Otherwise, with `server autostart` on, it finds the model (`[LLM] model`, or the first `.gguf` in the models folder) and the device. `auto` runs `llama-server --list-devices` and takes the first CUDA, ROCm, Vulkan or Metal device, else the CPU. Only one device is passed, so the same GPU is never used twice through two backends.
3. It starts llama-server hidden on the first free port from `[LLM] port`, polls `/health` until the model is loaded, and reads the real context size from `/props`.
4. The server is stopped when the game exits. If the game crashes, Linux stops it through `PR_SET_PDEATHSIG` and Windows through a kill-on-close job object.

**Lua:** `openmw.llm.serverStatus()` returns `state` (`starting`, `ready`, `external`, `disabled`, `noModel` or `failed`), `contextSize`, `model`, `device` and `error`. The prompt budget uses the server's context size, so it always matches `-c`. Until the server is ready, the text box is disabled with a hint and enables itself.

**Settings for players:** `[LLM]` in `settings.cfg`, edited in the launcher's AI Dialogue tab (Phase 3.5); the server can only be configured before it starts. In game, AI Dialogue → General → Refusal Duration sets how long an NPC refuses to talk after ending a conversation.

Windows process code is written but not yet compiled or tested.

## Phase 3.5: the launcher's AI Dialogue tab

`apps/launcher/aipage.cpp`, with two sub-tabs that fit the launcher's default window. The device, model and server logic it shares with the game is in `components/llm/server.cpp`, so the Test button runs exactly what the game runs.

**Model tab**
- **Use:** the installed models (every `.gguf` in the models folder), or Browse… for another file. The chosen one is saved as `[LLM] model`.
- **Folder:** where models are kept, with Open and Change… (`[LLM] models folder`). By default it is a visible `models` folder next to the game, or the user data folder if the game's folder isn't writable.
- **Download list:** `files/launcher/llm-models.json` (Gemma4-12B-RP Q6_K, Q4_K_M, IQ4_XS and Q3_K_M, plus Rocinante XL as an alternative), marked Fits / Tight / Too large / Recommended for the selected GPU. Downloads come from Hugging Face with progress, speed and time left. They can be cancelled and resume where they stopped, and are checked against the SHA256 before being installed.

**Performance tab**
- **Run on:** Automatic, CPU, or a device found by `llama-server --list-devices` (`[LLM] device`).
- **Context size**, with a video memory estimate.
- **GPU layers:** Auto (the default) uses llama.cpp's `--fit` to put as many layers on the GPU as fit while keeping **Keep free for the game** (`[LLM] vram reserve`, default 3 GB) free. The rest run on the CPU. A number sets the layers by hand; the model's layer count is read from its GGUF metadata.
- **Port, start with the game, extra arguments.**
- **Test:** starts the server on a spare port, asks for one sentence, and reports the load time, tokens per second and how many layers ran on the GPU.

**Instruct template:** the in-game setting defaults to Automatic, picked from the model's file name (`templates.forModel`). For a hand-run server, the name comes from its `/props`.

**Measured on the RTX 4090** with Gemma Q6_K:

| Setting | Load time | Speed | Layers on GPU |
|---|---|---|---|
| CUDA | 3 s | 68 tokens/s | all 49 |
| Vulkan | 7 s | 63 tokens/s | all 49 |
| Auto with 16 GB kept free (like an 8 GB card) | | 9 tokens/s | 28 of 49 |
| CPU only | | about 2 minutes per reply | none |

**Tests:** the Lua test harness and suites live in the git-ignored `tests/llm/` (`tests/llm/run.sh`), with `tests/llm/uipreview/` rendering the tab's layout offscreen.

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

**The game starts the server itself** (Phase 2.5). The build puts `llama-server` and its backend plug-ins in `build/llama/`, and the game starts it from there with the model chosen in the launcher, from `build/models/` (the dev models are symlinked there). Settings are in the `[LLM]` section of `settings.cfg`. The server's output goes to `~/.config/openmw/llama-server.log`.

**Hand-run server**, for testing models outside the game. The game uses it instead of starting its own while it runs on the `[LLM] port` (8080):

```
~/llm/llama.cpp/build/bin/llama-server -m ~/llm/models/Gemma4-12B-RP.i1-Q6_K.gguf -ngl 99 -c 8192 --jinja --port 8080
```

The mod uses the text-completion endpoint `/completion`. Set **AI Dialogue → Advanced → Instruct Template** to match the model: Gemma 4 for the Gemma models; Metharme or Mistral Tekken for Rocinante.

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
