;;; agent-shell-model-router-tests.el --- Tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Wanderson Ferreira

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for the Layer B complexity heuristic, focused on the
;; conservative ("fail toward the stronger model") behavior introduced by
;; the baseline floor, the strong-complex keyword override, the
;; complex-dominates-trivial rule, and stem matching.
;;
;; Run non-interactively:
;;
;;   emacs -batch -L . -l agent-shell-model-router-tests.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-shell-model-router)

(defmacro asmr-tests--with-defaults (&rest body)
  "Run BODY with the conservative defaults and a known model map.
Binds the rules to nil so Layer A never interferes with Layer B tests."
  (declare (indent 0))
  `(let ((agent-shell-model-router-rules nil)
         (agent-shell-model-router-baseline-score 3)
         (agent-shell-model-router-high-threshold 6)
         (agent-shell-model-router-medium-threshold 3)
         (agent-shell-model-router-complexity-models
          '((high . "Opus") (medium . "Sonnet") (low . "Haiku"))))
     ,@body))

(defun asmr-tests--model (prompt)
  "Return the model PROMPT would route to under Layer B."
  (plist-get (agent-shell-model-router-classify prompt) :model))

;;;; Baseline floor (P0a): uncertain prompts route to the medium model.

(ert-deftest asmr-tests-baseline-default-is-medium-threshold ()
  "The shipped baseline equals the shipped medium threshold."
  (should (= agent-shell-model-router-baseline-score
             agent-shell-model-router-medium-threshold)))

(ert-deftest asmr-tests-unsignalled-prompt-scores-baseline ()
  (asmr-tests--with-defaults
    (should (= (agent-shell-model-router-complexity-score "fix the bug") 3))))

(ert-deftest asmr-tests-unknown-prompt-routes-medium-not-low ()
  "A prompt of unknown difficulty must not land on the weakest model."
  (asmr-tests--with-defaults
    (should (equal (asmr-tests--model "fix the bug") "Sonnet"))
    (should (equal (asmr-tests--model "make this work") "Sonnet"))))

(ert-deftest asmr-tests-baseline-zero-restores-fail-low ()
  "Setting the baseline to 0 reproduces the previous behavior."
  (asmr-tests--with-defaults
    (let ((agent-shell-model-router-baseline-score 0))
      (should (= (agent-shell-model-router-complexity-score "fix the bug") 0))
      (should (equal (asmr-tests--model "fix the bug") "Haiku")))))

;;;; Strong-complex override (P0b): high-stakes domains force `high'.

(ert-deftest asmr-tests-strong-keyword-forces-high ()
  (asmr-tests--with-defaults
    (should (equal (asmr-tests--model "review this for security issues")
                   "Opus"))
    (should (equal (asmr-tests--model "is there a race condition here?")
                   "Opus"))))

(ert-deftest asmr-tests-strong-override-beats-low-score ()
  "A strong keyword promotes even when the numeric score is only medium."
  (asmr-tests--with-defaults
    ;; "migration" is strong but not in the score-bumping complex list,
    ;; so the score stays at baseline (3 -> medium) yet the bucket is high.
    (should (= (agent-shell-model-router-complexity-score "do the migration")
               3))
    (should (equal (asmr-tests--model "do the migration") "Opus"))))

;;;; Stem matching (P1b): inflected forms still count.

(ert-deftest asmr-tests-stem-matches-inflections ()
  "\"deadlocking\" must trigger the \"deadlock\" strong keyword."
  (asmr-tests--with-defaults
    (should (equal (asmr-tests--model "why is this deadlocking?") "Opus"))
    (should (agent-shell-model-router--stem-match-p "debug" "debugging this"))))

(ert-deftest asmr-tests-stem-still-requires-leading-boundary ()
  "Stem matching keeps the leading word boundary (no mid-word matches)."
  (should-not (agent-shell-model-router--stem-match-p "race" "embrace it"))
  (should-not (agent-shell-model-router--stem-match-p "race" "trace the call")))

;;;; Complex dominates trivial (P1a).

(ert-deftest asmr-tests-trivial-alone-demotes ()
  (asmr-tests--with-defaults
    (should (= (agent-shell-model-router-complexity-score "fix typo") 1))
    (should (equal (asmr-tests--model "fix typo") "Haiku"))
    (should (equal (asmr-tests--model "rename this variable") "Haiku"))))

(ert-deftest asmr-tests-complex-signal-blocks-trivial-demotion ()
  "A trivial verb must not cancel a real complexity signal."
  (asmr-tests--with-defaults
    (let ((prompt "rename foo and redesign the concurrency model"))
      ;; concurrency is both complex (+2) and strong (force high); the
      ;; trivial "rename" decrement is suppressed.
      (should (= (agent-shell-model-router-complexity-score prompt) 5))
      (should (equal (asmr-tests--model prompt) "Opus")))))

;;;; Regression: strong signals still reach high via score alone.

(ert-deftest asmr-tests-long-rich-prompt-is-high ()
  (asmr-tests--with-defaults
    (let ((prompt (concat "Please design and benchmark a new approach.\n"
                          "```\n(some code)\n```\n"
                          "See src/core/engine.el and @notes.org")))
      (should (equal (asmr-tests--model prompt) "Opus")))))

(provide 'agent-shell-model-router-tests)
;;; agent-shell-model-router-tests.el ends here
