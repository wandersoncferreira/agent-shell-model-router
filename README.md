# agent-shell-model-router

Automatically route [agent-shell](https://github.com/xenodium/agent-shell) prompts to the best model. Classifies by **intent & complexity** on the fly, switching models mid-session with zero extra LLM calls. Context flows unbroken.

Routes cheap models (Haiku) for trivial edits, stronger models (Opus) for design & debugging. Uses `session/set_model` to switch within the same conversation.

## How it works

Hooks into `agent-shell--send-command` with an `:around` advice that:

1. Skips ignored rules (e.g. `hello`) or short prompts (configurable threshold)
2. Classifies the prompt into a target model (see layers)
3. If routing needed: sends `session/set_model`, then re-sends on the new model
4. Otherwise sends immediately

### Per-prompt routing (restore after turn)

By default, routing is **per-prompt**: switches to the chosen model for one turn, then restores. Uses agent-shell's `turn-complete` event.

Set `agent-shell-model-router-restore-after-turn` to `nil` for **sticky** routing: switches stay until another rule fires.

### Classification layers

Evaluated in order; first match wins.

**Layer A: explicit rules** (`agent-shell-model-router-rules`)

Map matchers to models:

| key          | purpose                                            |
|--------------|----------------------------------------------------|
| `:name`      | shown in messages                                   |
| `:model`     | substring of model name                            |
| `:keywords`  | whole-word list (case-insensitive)                |
| `:regexp`    | regex pattern (case-insensitive)                  |
| `:predicate` | function(prompt) → truthy                         |

**Layer B: complexity heuristics** (`agent-shell-model-router-complexity-models`)

Scores prompts as `high` / `medium` / `low` by:
- word count, code blocks, file refs, `@` mentions, step indicators
- "complex" verbs (design, refactor, debug) raise score — stem-matched, so `debugging` counts
- "trivial" verbs (typo, rename, format) lower it — but only when no complex signal competes

**Conservative by default.** Scoring starts from a baseline (`agent-shell-model-router-baseline-score`, default `3` = the medium bucket), so a prompt with *no* signal routes to the medium model rather than the cheapest. Demoting to `low` requires positive evidence of triviality. Two signals force the `high` bucket outright regardless of score:

- **Strong-complex keywords** (`security`, `concurrency`, `deadlock`, `auth`, …)
- **Artifact creation** — a creation verb (`create`, `write`, `generate`, …) paired with an artifact noun (`pr`, `doc`, `rfc`, `migration`, …). Covers "create a PR", "write a document", "generate a report", etc. Both lists are customisable via `agent-shell-model-router-creation-verbs` and `agent-shell-model-router-creation-artifact-keywords`.

Set the baseline to `0` to restore plain fail-low scoring.

Disabled if `agent-shell-model-router-complexity-models` is `nil`.

## Installation

Requires `agent-shell` and `acp`.

**Doom Emacs:**
```elisp
(package! agent-shell-model-router
  :recipe (:local-repo "~/dev/nu/agent-shell-model-router" :files ("*.el")))
```

**straight.el:**
```elisp
(use-package agent-shell-model-router
  :straight (:host github :repo "wandersoncferreira/agent-shell-model-router")
  :after agent-shell)
```

**Manual:** Add `agent-shell-model-router.el` to `load-path`, then `(require 'agent-shell-model-router)`.

## Configuration

```elisp
(require 'agent-shell-model-router)

;; Layer A: explicit rules. :model matches substrings of model display names.
(setq agent-shell-model-router-rules
      '((:name "research"  :model "Opus"
         :keywords ("research" "investigate" "analyze"))
        (:name "reply"     :model "Sonnet"
         :keywords ("reply" "send a message"))
        (:name "code"      :model "Opus"
         :keywords ("implement" "refactor"))
        (:name "trivial"   :model "Haiku"
         :keywords ("typo" "rename" "format"))))

;; Layer B: fallback by complexity.
(setq agent-shell-model-router-complexity-models
      '((high   . "Opus") (medium . "Sonnet") (low . "Haiku")))

(agent-shell-model-router-mode 1)
```

### Key options

| option                                       | default | meaning                                       |
|----------------------------------------------|---------|-----------------------------------------------|
| `agent-shell-model-router-rules`             | `nil`   | Layer A rules                                 |
| `agent-shell-model-router-complexity-models` | `nil`   | Layer B buckets (nil = off)                  |
| `agent-shell-model-router-baseline-score`    | `3`     | starting score (0 = fail-low)                |
| `agent-shell-model-router-high-threshold`    | `6`     | score ≥ this → `high`                        |
| `agent-shell-model-router-complex-keywords`  | list    | words that raise score (stem-matched)        |
| `agent-shell-model-router-strong-complex-keywords` | list | words that force `high`                  |
| `agent-shell-model-router-creation-verbs`    | list    | creation verbs (force `high` when paired with artifact) |
| `agent-shell-model-router-creation-artifact-keywords` | list | artifact nouns (force `high` when paired with creation verb) |
| `agent-shell-model-router-trivial-keywords`  | list    | words that lower score                        |
| `agent-shell-model-router-min-words`         | `0`     | skip routing if prompt is shorter            |
| `agent-shell-model-router-verbose`           | `t`     | log routing decisions                         |

## Inspecting decisions

Preview routing without sending:
```
M-x agent-shell-model-router-explain
```

Or call programmatically:
```elisp
(agent-shell-model-router-explain-string "refactor auth module")
;; => "-> Opus | complexity:high | score 6"
```

## Notes

- **Per-session, per-prompt.** Switches apply to the session; context flows unbroken.
- **Model substring matching.** `:model "Opus"` matches any model containing "Opus".
- **Greeting filter.** Auto-sent `hello` won't trigger routing by default.

## Future ideas

- **Layer C: embedding classifier.** Local model scores prompts by semantic similarity (Ollama, fastText).
- Manual per-buffer overrides ("force model X for one prompt").
- Header-line indicator of last-fired category.
- Feedback loop to auto-tune thresholds.

## License

MIT License. See [LICENSE](LICENSE) for details.
