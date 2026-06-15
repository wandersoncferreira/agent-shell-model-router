;;; agent-shell-model-router.el --- Route agent-shell prompts to models by intent/complexity  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Wanderson Ferreira

;; Author: Wanderson Ferreira
;; Maintainer: Wanderson Ferreira
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (agent-shell "0.1.0") (acp "0.1.0"))
;; Keywords: tools, convenience
;; URL: https://github.com/wandersoncferreira/agent-shell-model-router

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Automatically switch the `agent-shell' session model based on the
;; prompt you are about to send.  When the global minor mode is on, the
;; prompt is classified *before* it leaves Emacs and the session is
;; switched to the model best suited for it -- a cheap fast model for
;; trivial edits, a stronger model for design/debugging work.
;;
;; Classification uses no extra LLM call.  Two layers are evaluated in
;; order:
;;
;;   Layer A -- explicit rules (`agent-shell-model-router-rules'):
;;     keyword / regexp / predicate matchers you define, each mapped to
;;     a model.  First match wins.
;;
;;   Layer B -- complexity heuristics
;;     (`agent-shell-model-router-complexity-models'): a no-model score
;;     built from prompt length, code fences, file references and
;;     intent verbs, bucketed into high/medium/low.
;;
;; A future Layer C (local embedding classifier) is described in the
;; README under "Next steps"; it is intentionally not implemented here.
;;
;; Usage:
;;
;;   (require 'agent-shell-model-router)
;;   (setq agent-shell-model-router-rules
;;         '((:name "quick-edit" :model "Haiku"
;;            :keywords ("typo" "rename" "format"))
;;           (:name "design" :model "Opus"
;;            :keywords ("design" "architecture" "tradeoff"))))
;;   (setq agent-shell-model-router-complexity-models
;;         '((high . "Opus") (medium . "Sonnet") (low . "Haiku")))
;;   (agent-shell-model-router-mode 1)
;;
;; Inspect a decision without sending anything:
;;
;;   M-x agent-shell-model-router-explain

;;; Code:

(require 'acp)
(require 'agent-shell)
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(defgroup agent-shell-model-router nil
  "Route `agent-shell' prompts to models by intent and complexity."
  :group 'tools
  :prefix "agent-shell-model-router-")

;;;; Customization -- Layer A (explicit rules)

(defcustom agent-shell-model-router-rules nil
  "Ordered list of routing rules (Layer A).

Each rule is a plist with the following keys:

  :name       String label for the category (shown in messages).
  :model      String matched as a substring against the session's
              available model display names, e.g. \"Opus\",
              \"Sonnet 4.6\", \"Haiku\".
  :keywords   Optional list of strings; the rule matches when any of
              them appears as a whole word in the prompt
              (case-insensitive).
  :regexp     Optional regexp; the rule matches when it matches the
              prompt (case-insensitive).
  :predicate  Optional function of one argument (the prompt string)
              returning non-nil on a match.

A rule matches when ANY of its provided matchers matches.  Rules are
tried in order and the first match wins."
  :type '(repeat (plist :key-type symbol :value-type sexp))
  :group 'agent-shell-model-router)

;;;; Customization -- Layer B (complexity heuristics)

(defcustom agent-shell-model-router-complexity-models nil
  "Alist mapping complexity buckets to models (Layer B).

Keys are the symbols `high', `medium' and `low'.  Values are model
substrings (see `agent-shell-model-router-rules' :model).

When nil, the complexity layer is disabled: if no Layer A rule
matches, the current model is kept."
  :type '(alist :key-type (choice (const high) (const medium) (const low))
                :value-type string)
  :group 'agent-shell-model-router)

(defcustom agent-shell-model-router-high-threshold 6
  "Complexity score at or above which a prompt is bucketed as `high'."
  :type 'integer
  :group 'agent-shell-model-router)

(defcustom agent-shell-model-router-medium-threshold 3
  "Complexity score at or above which a prompt is bucketed as `medium'.
Scores below this fall into the `low' bucket."
  :type 'integer
  :group 'agent-shell-model-router)

(defcustom agent-shell-model-router-complex-keywords
  '("design" "architect" "architecture" "refactor" "debug" "investigate"
    "optimize" "optimise" "prove" "analyze" "analyse" "race" "deadlock"
    "concurrency" "security" "review" "tradeoff" "plan" "benchmark")
  "Verbs/nouns that signal a more complex request (raise the score)."
  :type '(repeat string)
  :group 'agent-shell-model-router)

(defcustom agent-shell-model-router-trivial-keywords
  '("typo" "rename" "format" "fmt" "lint" "indent" "docstring" "comment")
  "Verbs/nouns that signal a trivial request (lower the score)."
  :type '(repeat string)
  :group 'agent-shell-model-router)

;;;; Customization -- guards & feedback

(defcustom agent-shell-model-router-ignore-regexps
  '("\\`[ \t\n]*hello[ \t\n]*\\'")
  "Regexps; a prompt matching any of them is NOT routed.

The default skips a lone \"hello\" greeting -- some setups auto-send
one on session init -- so it never triggers a model switch.  Matching
is case-insensitive."
  :type '(repeat regexp)
  :group 'agent-shell-model-router)

(defcustom agent-shell-model-router-min-words 0
  "Skip routing for prompts with fewer than this many words.

Useful for leaving short follow-ups (\"yes\", \"continue\", \"go on\")
on whatever model is current.  0 disables this check."
  :type 'integer
  :group 'agent-shell-model-router)

(defcustom agent-shell-model-router-verbose t
  "When non-nil, echo routing decisions and switches in the echo area."
  :type 'boolean
  :group 'agent-shell-model-router)

(defcustom agent-shell-model-router-restore-after-turn t
  "When non-nil, restore the session's previous model after the routed turn.

Routing then applies per prompt: the session is switched to the chosen
model just for that prompt and switched back once the agent finishes its
turn (the `turn-complete' event).  When nil, a routed switch is sticky
and stays in effect for subsequent prompts until another rule fires."
  :type 'boolean
  :group 'agent-shell-model-router)

;;;; Internal helpers

(defun agent-shell-model-router--word-match-p (word text)
  "Return non-nil when WORD appears as a whole word in TEXT.
Matching is case-insensitive."
  (let ((case-fold-search t))
    (string-match-p (concat "\\b" (regexp-quote word) "\\b") text)))

(defun agent-shell-model-router--word-count (prompt)
  "Return the number of whitespace-separated words in PROMPT."
  (length (split-string prompt "[ \t\n]+" t)))

(defun agent-shell-model-router--count-references (prompt)
  "Return the number of file-path-like or @-mention tokens in PROMPT."
  (let ((count 0)
        (start 0)
        (re (concat "\\(?:@[[:alnum:]._/-]+"          ; @mentions / @paths
                    "\\|[[:alnum:]._-]+/[[:alnum:]._/-]+" ; a/b/c paths
                    "\\|[[:alnum:]_-]+\\.[[:alpha:]]\\{1,5\\}\\)"))) ; foo.el
    (while (string-match re prompt start)
      (cl-incf count)
      (setq start (match-end 0)))
    count))

(defun agent-shell-model-router--rule-matches-p (rule prompt)
  "Return non-nil when RULE matches PROMPT."
  (let ((case-fold-search t)
        (keywords (plist-get rule :keywords))
        (regexp (plist-get rule :regexp))
        (predicate (plist-get rule :predicate)))
    (or (and keywords
             (seq-some (lambda (kw)
                         (agent-shell-model-router--word-match-p kw prompt))
                       keywords))
        (and regexp (string-match-p regexp prompt))
        (and (functionp predicate) (funcall predicate prompt)))))

(defun agent-shell-model-router--complexity-bucket (score)
  "Return the bucket symbol (`high'/`medium'/`low') for SCORE."
  (cond ((>= score agent-shell-model-router-high-threshold) 'high)
        ((>= score agent-shell-model-router-medium-threshold) 'medium)
        (t 'low)))

;;;; Public classification API (no side effects, no LLM call)

(defun agent-shell-model-router-complexity-score (prompt)
  "Return an integer complexity score for PROMPT (Layer B).
Higher means more complex.  Purely heuristic -- no model is called."
  (let ((case-fold-search t)
        (score 0)
        (words (agent-shell-model-router--word-count prompt)))
    ;; Length.
    (cond ((> words 120) (cl-incf score 3))
          ((> words 60)  (cl-incf score 2))
          ((> words 25)  (cl-incf score 1)))
    ;; Fenced code blocks.
    (when (string-match-p "```" prompt) (cl-incf score 2))
    ;; File references / @-mentions (capped).
    (cl-incf score (min 2 (agent-shell-model-router--count-references prompt)))
    ;; Enumerated / multi-step request.
    (when (string-match-p "^[ \t]*[0-9]+[.)]" prompt) (cl-incf score 1))
    ;; Complex intent verbs.
    (when (seq-some (lambda (w)
                      (agent-shell-model-router--word-match-p w prompt))
                    agent-shell-model-router-complex-keywords)
      (cl-incf score 2))
    ;; Trivial intent verbs pull the score down.
    (when (seq-some (lambda (w)
                      (agent-shell-model-router--word-match-p w prompt))
                    agent-shell-model-router-trivial-keywords)
      (cl-decf score 2))
    (max 0 score)))

(defun agent-shell-model-router-classify (prompt)
  "Return a routing decision for PROMPT, or nil to keep the current model.

The decision is a plist (:model MODEL :category NAME :reason STRING).
Layer A rules (`agent-shell-model-router-rules') are tried first, then
Layer B complexity buckets (`agent-shell-model-router-complexity-models')."
  (when (and (stringp prompt) (not (string-blank-p prompt)))
    (or
     ;; Layer A -- explicit rules.
     (cl-loop for rule in agent-shell-model-router-rules
              when (agent-shell-model-router--rule-matches-p rule prompt)
              return (list :model (plist-get rule :model)
                           :category (or (plist-get rule :name) "rule")
                           :reason (format "rule %S"
                                           (or (plist-get rule :name) "?"))))
     ;; Layer B -- complexity buckets.
     (when agent-shell-model-router-complexity-models
       (let* ((score (agent-shell-model-router-complexity-score prompt))
              (bucket (agent-shell-model-router--complexity-bucket score))
              (model (alist-get bucket
                                agent-shell-model-router-complexity-models)))
         (when model
           (list :model model
                 :category (format "complexity:%s" bucket)
                 :reason (format "score %d -> %s" score bucket))))))))

;;;; Guard

(defun agent-shell-model-router--ignore-p (prompt)
  "Return non-nil when PROMPT should be left on the current model."
  (let ((case-fold-search t))
    (or (and (> agent-shell-model-router-min-words 0)
             (< (agent-shell-model-router--word-count prompt)
                agent-shell-model-router-min-words))
        (seq-some (lambda (re) (string-match-p re prompt))
                  agent-shell-model-router-ignore-regexps))))

;;;; Model switching (generic, based on agent-shell/acp internals)

(defun agent-shell-model-router--available-models (shell-buffer)
  "Return available models in SHELL-BUFFER as a list of (:name :model-id) alists.

Handles two ACP shapes: the legacy `(:session :models)' list, and newer
servers (e.g. current Claude Code) that expose models only as the
\"model\" entry under `(:session :config-options)', where each option's
`:value' is the model-id and `:name' its display name.  Returns nil when
SHELL-BUFFER is not a live agent-shell."
  (when (buffer-live-p shell-buffer)
    (with-current-buffer shell-buffer
      (or
       ;; Legacy shape: list of maps already keyed by :name / :model-id.
       (map-nested-elt agent-shell--state '(:session :models))
       ;; Newer shape: config-options -> "model" select -> :options.
       (when-let* ((model-opt
                    (seq-find
                     (lambda (opt) (equal (map-elt opt :id) "model"))
                     (map-nested-elt agent-shell--state
                                     '(:session :config-options)))))
         (mapcar (lambda (opt)
                   (list (cons :name (map-elt opt :name))
                         (cons :model-id (map-elt opt :value))))
                 (map-elt model-opt :options)))))))

(defun agent-shell-model-router--resolve-model-id (shell-buffer model-name)
  "Return the model-id whose display name contains MODEL-NAME in SHELL-BUFFER.
MODEL-NAME is substring-matched (case-sensitively, as model names are)
against the session's available model display names.  Return nil when no
model matches or SHELL-BUFFER is not a live agent-shell."
  (when (and model-name (buffer-live-p shell-buffer))
    (let ((target (seq-find
                   (lambda (m)
                     (string-match-p (regexp-quote model-name)
                                     (or (map-elt m :name) "")))
                   (agent-shell-model-router--available-models shell-buffer))))
      (and target (map-elt target :model-id)))))

(defun agent-shell-model-router--model-name (shell-buffer model-id)
  "Return the display name for MODEL-ID in SHELL-BUFFER, or MODEL-ID itself."
  (or (and model-id
           (when-let* ((m (seq-find
                           (lambda (m) (equal (map-elt m :model-id) model-id))
                           (agent-shell-model-router--available-models
                            shell-buffer))))
             (map-elt m :name)))
      model-id))

(defun agent-shell-model-router--switch-to-id (shell-buffer model-id on-done)
  "Switch SHELL-BUFFER's session model to MODEL-ID, then call ON-DONE.

ON-DONE is called with one argument: non-nil if a switch request was
issued and succeeded, nil otherwise (already current, dead buffer, or
failure).  ON-DONE is ALWAYS called exactly once."
  (if (not (and model-id (buffer-live-p shell-buffer)))
      (funcall on-done nil)
    (with-current-buffer shell-buffer
      (let ((current-id (if (fboundp 'agent-shell--current-model-id)
                            ;; agent-shell--state is both a defvar-local AND a defun:
                            ;; call the function to get the current live state.
                            (agent-shell--current-model-id (agent-shell--state))
                          (map-nested-elt (if (fboundp 'agent-shell--state)
                                              (agent-shell--state)
                                            agent-shell--state)
                                          '(:session :model-id)))))
        (cond
         ((equal model-id current-id)
          (funcall on-done nil))
         ;; Newer agent-shell exposes a version-agnostic setter that uses
         ;; `session/set_config_option' (configId "model") when the agent
         ;; advertises it -- as @agentclientprotocol/claude-agent-acp >= 0.44
         ;; does -- and only falls back to the legacy `session/set_model'
         ;; request when no "model" config-option exists.  Prefer it so we
         ;; never send a `session/set_model' the agent answers with -32601.
         ((fboundp 'agent-shell--config-option-set-model-id)
          (agent-shell--config-option-set-model-id
           :model-id model-id
           :on-success (lambda () (funcall on-done t))
           :on-failure (lambda (acp-error _raw-message)
                         (message "agent-shell-model-router: model switch failed: %s"
                                  acp-error)
                         (funcall on-done nil))))
         ;; Legacy agent-shell (no config-option helper): direct request.
         (t
          (agent-shell--send-request
           :state agent-shell--state
           :client (map-elt agent-shell--state :client)
           :request (acp-make-session-set-model-request
                     :session-id (map-nested-elt agent-shell--state '(:session :id))
                     :model-id model-id)
           :buffer shell-buffer
           :on-success
           (lambda (_response)
             (when (buffer-live-p shell-buffer)
               (with-current-buffer shell-buffer
                 (let ((session (map-elt agent-shell--state :session)))
                   (map-put! session :model-id model-id)
                   (map-put! agent-shell--state :session session))
                 (when (fboundp 'agent-shell--update-header-and-mode-line)
                   (agent-shell--update-header-and-mode-line))))
             (funcall on-done t))
           :on-failure
           (lambda (acp-error _raw-message)
             (message "agent-shell-model-router: model switch failed: %s"
                      acp-error)
             (funcall on-done nil)))))))))

(defun agent-shell-model-router--restore-on-turn-complete (shell-buffer model-id)
  "Restore SHELL-BUFFER's model to MODEL-ID once the current turn completes.

Subscribes (one-shot) to the `turn-complete' event and, when it fires,
unsubscribes and switches the session back to MODEL-ID."
  (when (buffer-live-p shell-buffer)
    (let (token)
      (setq token
            (agent-shell-subscribe-to
             :shell-buffer shell-buffer
             :event 'turn-complete
             :on-event
             (lambda (_event)
               (when token
                 (agent-shell-unsubscribe :subscription token))
               (agent-shell-model-router--switch-to-id
                shell-buffer model-id
                (lambda (switched)
                  (when (and switched agent-shell-model-router-verbose)
                    (message "agent-shell-model-router: restored %s"
                             (agent-shell-model-router--model-name
                              shell-buffer model-id)))))))))))

;;;; The around advice

(defun agent-shell-model-router--around-send (orig-fn &rest args)
  "Around advice for `agent-shell--send-command' (ORIG-FN called with ARGS).

Classifies the prompt and, when a different model is warranted, switches
the session model before re-entering ORIG-FN.  The original call always
runs inside the shell buffer so its buffer-local state is intact even
when invoked from the asynchronous model-switch callback.  When
`agent-shell-model-router-restore-after-turn' is non-nil, the previous
model is restored once the agent finishes the turn."
  (let* ((prompt (plist-get args :prompt))
         (shell-buffer (or (plist-get args :shell-buffer)
                           (and (derived-mode-p 'agent-shell-mode)
                                (current-buffer))))
         (run (lambda ()
                (if (buffer-live-p shell-buffer)
                    (with-current-buffer shell-buffer (apply orig-fn args))
                  (apply orig-fn args)))))
    (if (or (not (stringp prompt))
            (not (buffer-live-p shell-buffer))
            (agent-shell-model-router--ignore-p prompt))
        (funcall run)
      (let ((decision (agent-shell-model-router-classify prompt)))
        (if (null decision)
            (funcall run)
          (let ((prev-id (with-current-buffer shell-buffer
                           (if (fboundp 'agent-shell--current-model-id)
                               (agent-shell--current-model-id (agent-shell--state))
                             (map-nested-elt agent-shell--state
                                             '(:session :model-id)))))
                (target-id (agent-shell-model-router--resolve-model-id
                            shell-buffer (plist-get decision :model))))
            (when agent-shell-model-router-verbose
              (message "agent-shell-model-router: %s [%s]"
                       (plist-get decision :category)
                       (plist-get decision :reason)))
            (if (null target-id)
                (progn
                  (when agent-shell-model-router-verbose
                    (message "agent-shell-model-router: no model matching %S"
                             (plist-get decision :model)))
                  (funcall run))
              (agent-shell-model-router--switch-to-id
               shell-buffer target-id
               (lambda (switched)
                 (when (and switched
                            agent-shell-model-router-restore-after-turn
                            (not (equal prev-id target-id)))
                   (agent-shell-model-router--restore-on-turn-complete
                    shell-buffer prev-id))
                 (funcall run))))))))))

;;;; Inspection commands

(defun agent-shell-model-router-explain-string (prompt)
  "Return a human-readable routing explanation for PROMPT (no side effects).
Designed to be called from `emacsclient --eval'."
  (let ((score (agent-shell-model-router-complexity-score prompt)))
    (cond
     ((not (stringp prompt))
      "NO PROMPT")
     ((agent-shell-model-router--ignore-p prompt)
      (format "IGNORED (ignore list / too short) | complexity=%d" score))
     (t
      (let ((decision (agent-shell-model-router-classify prompt)))
        (if (null decision)
            (format "NO CHANGE (no rule; complexity layer off) | complexity=%d"
                    score)
          (format "-> %s | %s | %s | complexity=%d"
                  (plist-get decision :model)
                  (plist-get decision :category)
                  (plist-get decision :reason)
                  score)))))))

;;;###autoload
(defun agent-shell-model-router-explain (prompt)
  "Show how PROMPT would be routed, without sending anything.
Interactively, use the active region if any, otherwise read a string."
  (interactive
   (list (if (use-region-p)
             (buffer-substring-no-properties (region-beginning) (region-end))
           (read-string "Prompt: "))))
  (message "%s" (agent-shell-model-router-explain-string prompt)))

;;;; Global minor mode

;;;###autoload
(define-minor-mode agent-shell-model-router-mode
  "Global mode that routes `agent-shell' prompts to models.

When enabled, each prompt is classified (Layer A rules then Layer B
complexity) and the session model is switched accordingly before the
prompt is sent.  No extra LLM call is made for classification."
  :global t
  :group 'agent-shell-model-router
  (if agent-shell-model-router-mode
      (advice-add 'agent-shell--send-command :around
                  #'agent-shell-model-router--around-send)
    (advice-remove 'agent-shell--send-command
                   #'agent-shell-model-router--around-send)))

(provide 'agent-shell-model-router)
;;; agent-shell-model-router.el ends here
