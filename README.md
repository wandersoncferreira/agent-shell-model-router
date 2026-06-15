# agent-shell-model-router

Route your [agent-shell](https://github.com/xenodium/agent-shell) prompts
to the right model automatically. Before a prompt leaves Emacs, it is
classified by **intent and complexity** and the session is switched to
the model best suited for it — a cheap, fast model for trivial edits, a
stronger model for design and debugging — with **no extra LLM call** for
the routing decision.

It works by switching the model *within the same session* (via the ACP
`session/set_model` request), so conversation context is preserved across
a switch.

## How it works

A global minor mode adds an `:around` advice to `agent-shell--send-command`
— the function that receives the raw prompt string just before it is sent
to the agent. The advice:

1. Skips the prompt if it matches an **ignore** rule (e.g. a lone
   `hello` greeting) or is shorter than a configurable word count.
2. **Classifies** the prompt (see layers below) into a target model.
3. If a different model is warranted, sends the `session/set_model`
   request and, in its success callback, re-enters the original send so
   the prompt goes out on the new model. (The original call is always run
   inside the shell buffer, so its buffer-local state is intact even from
   the async callback.)
4. Otherwise sends immediately on the current model.

### Per-prompt routing (restore after the turn)

By default (`agent-shell-model-router-restore-after-turn` = `t`) routing
is **per prompt**: the router records the session's current model, switches
to the chosen one for this prompt, and switches back once the agent
finishes the turn. It restores by subscribing one-shot to agent-shell's
`turn-complete` event, so your session's default model is left untouched
between routed prompts.

Set the option to `nil` for **sticky** routing instead: a routed switch
stays in effect for subsequent prompts until another rule fires.

### Classification layers

Evaluated in order; the first one to produce a model wins.

**Layer A — explicit rules** (`agent-shell-model-router-rules`)

An ordered list of rules. Each rule maps a matcher to a model. A rule
matches when *any* of its matchers matches; rules are tried in order and
the first match wins.

| key          | meaning                                                                 |
|--------------|-------------------------------------------------------------------------|
| `:name`      | label shown in echo-area messages                                       |
| `:model`     | substring matched against the session's available model display names   |
| `:keywords`  | list of strings; matches if any appears as a whole word (case-insensitive) |
| `:regexp`    | regexp matched against the prompt (case-insensitive)                    |
| `:predicate` | function of the prompt string returning non-nil on a match              |

**Layer B — complexity heuristics** (`agent-shell-model-router-complexity-models`)

A no-model score is computed from cheap signals and bucketed into
`high` / `medium` / `low`, each mapped to a model. Signals:

- prompt length (word count)
- presence of fenced code blocks (` ``` `)
- number of file-path-like / `@`-mention references
- enumerated/multi-step requests (`1.`, `2)` …)
- "complex" intent verbs (design, refactor, debug, …) raise the score
- "trivial" intent verbs (typo, rename, format, …) lower it

Thresholds and keyword lists are all customizable. If
`agent-shell-model-router-complexity-models` is left `nil`, Layer B is
disabled and the current model is kept whenever no Layer A rule matches.

## Installation

This package depends on `agent-shell` and `acp`.

### Doom Emacs (local checkout)

```elisp
;; packages.el
(package! agent-shell-model-router
  :recipe (:local-repo "~/dev/nu/agent-shell-model-router"
           :files ("*.el")))
```

### straight.el / use-package

```elisp
(use-package agent-shell-model-router
  :straight (:host github :repo "wandersoncferreira/agent-shell-model-router")
  :after agent-shell)
```

### Manual

Put `agent-shell-model-router.el` on your `load-path` and `(require
'agent-shell-model-router)`.

## Configuration

```elisp
(require 'agent-shell-model-router)

;; Layer A: your categories. :model is a substring of the model's
;; display name as reported by the agent (e.g. Claude Code ACP reports
;; "Opus (1M context)", "Sonnet (1M context)", "Haiku").
;;
;; Keyword matching is whole-word and case-insensitive, so multi-word
;; phrases like "send a message" or "team board" match as phrases.
(setq agent-shell-model-router-rules
      '((:name "researcher" :model "Opus"
         :keywords ("research" "search" "investigate"))
        (:name "replier"    :model "Sonnet"
         :keywords ("reply" "reply comment" "send a message" "read message"))
        (:name "coder"      :model "Opus"
         :keywords ("implement"))
        (:name "internal"   :model "Sonnet (1M context)"
         :keywords ("team-board" "team_board" "team board"))
        ;; matchers can also be regexps or predicates:
        (:name "design"     :model "Opus"
         :regexp "\\b\\(design\\|architect\\|tradeoff\\)\\b")))

;; Layer B: fallback by complexity when no rule matches.
(setq agent-shell-model-router-complexity-models
      '((high   . "Opus")
        (medium . "Sonnet")
        (low    . "Haiku")))

;; Turn it on (global).
(agent-shell-model-router-mode 1)
```

### Useful options

| option                                          | default                         | meaning                                            |
|-------------------------------------------------|---------------------------------|----------------------------------------------------|
| `agent-shell-model-router-rules`                | `nil`                           | Layer A rules                                       |
| `agent-shell-model-router-complexity-models`    | `nil`                           | Layer B bucket→model alist (nil = Layer B off)     |
| `agent-shell-model-router-high-threshold`       | `6`                             | score ≥ this → `high`                              |
| `agent-shell-model-router-medium-threshold`     | `3`                             | score ≥ this → `medium`                            |
| `agent-shell-model-router-complex-keywords`     | design/refactor/debug/…         | verbs that raise the score                          |
| `agent-shell-model-router-trivial-keywords`     | typo/rename/format/…            | verbs that lower the score                          |
| `agent-shell-model-router-ignore-regexps`       | a lone `hello`                  | prompts matching any are never routed               |
| `agent-shell-model-router-min-words`            | `0`                             | skip routing for prompts shorter than this (0 = off)|
| `agent-shell-model-router-restore-after-turn`   | `t`                             | restore the previous model when the turn completes  |
| `agent-shell-model-router-verbose`              | `t`                             | echo decisions and switches                         |

## Inspecting decisions

To see how a prompt *would* be routed without sending anything:

```
M-x agent-shell-model-router-explain
```

(uses the active region if any, else prompts for text). There is also a
string-returning variant for scripting:

```elisp
(agent-shell-model-router-explain-string "refactor the auth module across services")
;; => "-> Opus | complexity:high | score 6 -> high | complexity=6"
```

## Notes & caveats

- **Whole session, next turn.** The switch applies to the session and
  takes effect from the next prompt; context is preserved.
- **Model names are substrings.** `:model "Opus"` matches any available
  model whose display name contains `Opus`. If no available model
  matches, the prompt is sent on the current model (a message is logged
  when `verbose`).
- **Greeting guard.** Some agent-shell setups auto-send a `hello` on
  session init; the default ignore list keeps that from triggering a
  switch. Adjust `agent-shell-model-router-ignore-regexps` for your own
  boilerplate.

## Next steps (not yet implemented)

**Layer C — local embedding classifier.** Embed the prompt with a local
model (e.g. Ollama's `/api/embeddings` endpoint, or fastText) and pick
the category by nearest-centroid against a small set of labeled
exemplars. This generalizes beyond keyword/regexp rules while still
avoiding a *generation* round-trip. It would slot in between Layer A and
Layer B in `agent-shell-model-router-classify`. Tradeoff: it is still a
model and adds ~50–150 ms latency, so it should be opt-in.

Other ideas:

- A manual per-buffer override ("force model X for the next prompt").
- A header-line indicator showing which category last fired.
- A feedback loop that records corrections to tune thresholds/exemplars.

## License

GPL-3.0-or-later.
