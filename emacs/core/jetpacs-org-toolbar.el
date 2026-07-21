;;; jetpacs-org-toolbar.el --- the org keyboard toolbar as data -*- lexical-binding: t; -*-

;; The org formatting toolbar, composed as pure data (SPEC §9 "Editor
;; toolbars" in the jetpacs submodule).  The companion interprets the
;; items locally — every tap is one splice, one undo step, no Emacs
;; round-trip — so this app ships its toolbar with zero Kotlin.  It
;; replaces the reference companion's OrgEditToolbar.kt (deleted from
;; the foundation); this file is now the specification of what the org
;; toolbar contains.

;;; Code:

(require 'jetpacs-widgets)

(defconst jetpacs-org-toolbar--src-languages
  '("emacs-lisp" "python" "shell" "kotlin" "java"
    "javascript" "sql" "c" "rust" "go" "org" "text")
  "Preset languages in the src-block menu; a final item prompts free-form.")

(defun jetpacs-org-toolbar--src-item (lang)
  "A src-block menu sub-item inserting a LANG block."
  (jetpacs-toolbar-item nil lang
                     :snippet (format "#+begin_src %s\n${cursor}\n#+end_src" lang)
                     :placement "block"))

(defun jetpacs-org-toolbar ()
  "The org keyboard toolbar as a list of `jetpacs-toolbar-item's.
Attach it via `jetpacs-editor' :toolbar (the detail-view editor) or
return it from `jetpacs-files-editor-toolbar-function' (.org files).
Anything smarter than a local edit belongs in an :on-tap item — that
round-trips to Emacs through the ordinary action pipeline."
  (list
   ;; Heading (dropdown for levels)
   (jetpacs-toolbar-item "title" "H"
                      :menu (mapcar (lambda (level)
                                      (let ((stars (make-string level ?*)))
                                        (jetpacs-toolbar-item
                                         nil (format "%s Heading %d" stars level)
                                         :snippet (concat stars " ")
                                         :placement "line-start")))
                                    (number-sequence 1 6)))
   ;; TODO heading (dropdown for levels)
   (jetpacs-toolbar-item "task_alt" "TODO"
                      :menu (mapcar (lambda (level)
                                      (let ((stars (make-string level ?*)))
                                        (jetpacs-toolbar-item
                                         nil (format "%s TODO %d" stars level)
                                         :snippet (concat stars " TODO ")
                                         :placement "line-start")))
                                    (number-sequence 1 6)))
   ;; Structure: promote / demote / move up / move down
   (jetpacs-toolbar-item "format_indent_decrease" "←" :line "promote")
   (jetpacs-toolbar-item "format_indent_increase" "→" :line "demote")
   (jetpacs-toolbar-item "arrow_upward" "↑" :line "move-up")
   (jetpacs-toolbar-item "arrow_downward" "↓" :line "move-down")
   ;; Lists
   (jetpacs-toolbar-item "checklist" "☐" :snippet "- [ ] " :placement "line-start")
   ;; Progress cookie: tap = [/], long-press = [%]
   (jetpacs-toolbar-item "data_object" "[/]" :snippet "[/]"
                      :long-press (jetpacs-toolbar-item nil nil :snippet "[%]"))
   (jetpacs-toolbar-item "format_list_bulleted" "•" :snippet "- " :placement "line-start")
   (jetpacs-toolbar-item "format_list_numbered" "1." :snippet "1. " :placement "line-start")
   ;; Source block: preset languages, plus a free-form prompt
   (jetpacs-toolbar-item "code" "Src"
                      :menu (append
                             (mapcar #'jetpacs-org-toolbar--src-item
                                     jetpacs-org-toolbar--src-languages)
                             (list (jetpacs-toolbar-item
                                    nil "Custom…"
                                    :snippet "#+begin_src ${input:Language}\n${cursor}\n#+end_src"
                                    :placement "block"))))
   ;; Properties drawer
   (jetpacs-toolbar-item "data_object" "Props"
                      :snippet ":PROPERTIES:\n:END:" :placement "block")
   ;; Inline emphasis (selection-aware wraps)
   (jetpacs-toolbar-item "format_bold" "B" :snippet "*${selection}*")
   (jetpacs-toolbar-item "format_italic" "I" :snippet "/${selection}/")
   (jetpacs-toolbar-item "code" "~" :snippet "~${selection}~")
   (jetpacs-toolbar-item "format_strikethrough" "S" :snippet "+${selection}+")
   ;; Link: cursor in the target, selection becomes the description
   (jetpacs-toolbar-item "link" "Link" :snippet "[[${cursor}][${selection}]]")
   ;; Timestamp: tap = inactive [date], long-press = active <date>
   (jetpacs-toolbar-item "schedule" "TS" :snippet "[${date}]"
                      :long-press (jetpacs-toolbar-item nil nil :snippet "<${date}>"))))

(provide 'jetpacs-org-toolbar)
;;; jetpacs-org-toolbar.el ends here
