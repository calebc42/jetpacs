;;; glasspane-gallery.el --- Interactive widget-primitives gallery -*- lexical-binding: t; -*-

;; A live demo of the platform's rendering primitives — charts, the canvas
;; interpreter, slider, sizing/border/spacing — wired together so the
;; interactive loop is visible: the slider drives a canvas gauge, chips
;; switch the chart kind, tapping a chart point reports its value.  Reached
;; from the drawer ("Widget Gallery"), the `demo.gallery' action, or
;; `M-x glasspane-demo-gallery' — the newest of the demo commands next to
;; `glasspane-demo-setup'.
;;
;; Everything here is composed from core `eabp-*' constructors: it is also
;; the worked example that a whole visual surface is Elisp, no Kotlin.

;;; Code:

(require 'cl-lib)
(require 'eabp-widgets)
(require 'eabp-shell)
(require 'eabp-surfaces)

(defvar glasspane-gallery--open nil
  "Non-nil while the gallery overlay is showing.")
(defvar glasspane-gallery--kind "line"
  "The chart kind the gallery currently renders.")
(defvar glasspane-gallery--level 0.5
  "The gauge value (0.0-1.0) the slider last set.")

;; ─── Canvas gauge (geometry computed here, drawn by the canvas node) ─────────

(defun glasspane-gallery--arc-points (cx cy r a0 a1 n)
  "N+1 points along the arc A0→A1 degrees, centre (CX CY), radius R.
Screen y grows downward, so a top semicircle spans 180°→0°."
  (cl-loop for i from 0 to n
           for a = (+ a0 (* (- a1 a0) (/ (float i) n)))
           for rad = (degrees-to-radians a)
           collect (list (+ cx (* r (cos rad))) (- cy (* r (sin rad))))))

(defun glasspane-gallery--gauge (level)
  "A semicircular canvas gauge filled to LEVEL (0.0-1.0)."
  (let* ((w 240) (h 132) (cx 120) (cy 116) (r 95)
         (end (- 180 (* 180 (max 0.0 (min 1.0 level)))))
         (na (degrees-to-radians end))
         (nx (+ cx (* r 0.9 (cos na))))
         (ny (- cy (* r 0.9 (sin na)))))
    (eabp-canvas
     w h
     (list (eabp-draw-path (glasspane-gallery--arc-points cx cy r 180 0 44)
                           :color "#8888aa" :stroke 12)
           (eabp-draw-path (glasspane-gallery--arc-points cx cy r 180 end 44)
                           :color "#00A676" :stroke 12)
           (eabp-draw-line cx cy nx ny :color "#E64980" :stroke 3)
           (eabp-draw-circle cx cy 7 :fill t :color "#E64980")
           (eabp-draw-text cx 74 (format "%d%%" (round (* 100 level)))
                           :align "center" :size 28 :color "primary")))))

;; ─── Body ────────────────────────────────────────────────────────────────────

(defun glasspane-gallery--kind-chips ()
  "A chip rail selecting `glasspane-gallery--kind'."
  (apply #'eabp-flow-row
         (append
          (mapcar (lambda (k)
                    (eabp-chip k
                               :selected (equal k glasspane-gallery--kind)
                               :on-tap (eabp-action "demo.gallery.kind"
                                                    :args (list (cons 'kind k)))))
                  '("line" "bar" "area" "sparkline"))
          (list :spacing 8))))

(defun glasspane-gallery--body ()
  "The scrollable gallery content (a `lazy_column', so it scrolls)."
  (eabp-lazy-column
   (eabp-section-header "Chart — tap a point, switch the kind")
   (glasspane-gallery--kind-chips)
   (eabp-chart
    (list (eabp-chart-series '(3 7 4 9 6 8 5) :label "alpha" :color "#4C6FFF")
          (eabp-chart-series '(5 4 6 5 7 5 8) :label "beta"))
    :kind glasspane-gallery--kind :height 150 :summary "two sample series"
    :on-point-tap (eabp-action "demo.gallery.point"))
   (eabp-divider)
   (eabp-section-header "Slider → live canvas gauge")
   (eabp-slider "gallery.level" (eabp-action "demo.gallery.level")
                :value glasspane-gallery--level :min 0.0 :max 1.0)
   (glasspane-gallery--gauge glasspane-gallery--level)
   (eabp-divider)
   (eabp-section-header "Sizing · border · spacing · align")
   (eabp-row
    (eabp-surface (list (eabp-text "100×64"))
                  :width 100 :height 64
                  :border (eabp-border :width 2 :color "primary"))
    (eabp-surface (list (eabp-text "rounded, fills rest"))
                  :height 64 :color "surface_container" :shape "rounded"
                  :fill-fraction 1.0)
    :spacing 12 :align "center")
   (eabp-spacer :height 12)))

(defun glasspane-gallery--view (snackbar)
  "The gallery as a back-arrow nav view."
  (eabp-shell-nav-view "Widget Gallery" (glasspane-gallery--body)
                       :snackbar snackbar))

;; ─── Actions ─────────────────────────────────────────────────────────────────

(eabp-defaction "demo.gallery"
  (lambda (_args _payload)
    (setq glasspane-gallery--open t)
    (eabp-shell-push nil :switch-to "gallery")))

(eabp-defaction "demo.gallery.kind"
  (lambda (args _payload)
    (setq glasspane-gallery--kind (or (alist-get 'kind args) "line"))
    (eabp-shell-push)))

(eabp-defaction "demo.gallery.level"
  (lambda (args _payload)
    (setq glasspane-gallery--level (or (alist-get 'value args) 0.5))
    (eabp-shell-push)))

(eabp-defaction "demo.gallery.point"
  (lambda (args _payload)
    (let ((v (alist-get 'value args)))
      (when (fboundp 'eabp-shell-notify)
        (eabp-shell-notify (format "point %s = %s"
                                   (alist-get 'index v) (alist-get 'y v)))))
    (eabp-shell-push)))

;; ─── Registration ────────────────────────────────────────────────────────────

(eabp-shell-define-view "gallery"
  :builder #'glasspane-gallery--view
  :when (lambda () glasspane-gallery--open)
  :overlay (lambda () glasspane-gallery--open)
  :order 120)

;; Landing on any real view closes the overlay (mirrors the detail drill-in).
(add-hook 'eabp-shell-view-switched-hook
          (lambda (_view) (setq glasspane-gallery--open nil)))

(eabp-shell-add-drawer-item
 65 (lambda () (eabp-drawer-item "insights" "Widget Gallery"
                                 (eabp-action "demo.gallery"))))

;;;###autoload
(defun glasspane-demo-gallery ()
  "Open the interactive widget-primitives gallery on the connected phone.
The newest of the demo commands (see also `glasspane-demo-setup')."
  (interactive)
  (setq glasspane-gallery--open t)
  (if (and (fboundp 'eabp-connected-p) (eabp-connected-p))
      (progn (eabp-shell-push nil :switch-to "gallery")
             (message "Widget gallery opened on the phone"))
    (message "EABP: not connected — connect a phone, then reopen")))

(provide 'glasspane-gallery)
;;; glasspane-gallery.el ends here
