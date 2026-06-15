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
- "complex" verbs (design, refactor, debug) raise score
- "trivial" verbs (typo, rename, format) lower it

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
| `agent-shell-model-router-high-threshold`    | `6`     | score ≥ this → `high`                        |
| `agent-shell-model-router-complex-keywords`  | list    | words that raise score                        |
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

GPL-3.0-or-later.
