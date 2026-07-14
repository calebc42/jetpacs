# The binding layer — declarative data-views

Most app screens are the same shape: *run a query, render each result with a
card template, lay the cards out as a list, board, or calendar.* The binding
layer lets a Tier 1 (and the no-code composer) express that **as data** instead
of as an elisp `:builder` — a **named source** for the data and a declarative
**`:spec`** for the view.

This is a *local authoring* layer: a `:spec` compiles, on device, to ordinary
wire nodes and actions. It is **not** part of the wire protocol (SPEC), and it
never widens the command-dispatch boundary — the compiled output obeys SPEC
§5/§9 like any other node tree. The template language is **closed-vocabulary
data**: field accessors and named transforms only, no expressions or lambdas;
actions are referenced by name. `jetpacs-lint-view-spec` proves it.

Since **API 1.5.0**. The static vocabulary (layouts, transforms, spec keys,
chrome kinds, source field types) is published in `docs/contract.json` under
`binding` for editors to consume.

## Sources — the data (`jetpacs-source.el`)

A **source** produces a list of item alists. Register one with a `:query`
thunk (the only funcall; it runs server-side and is never serialized) plus
machine-readable `:params` and `:fields` metadata:

```elisp
(jetpacs-defsource "myapp.tasks"
  :params '((:name query :type "text" :required t))
  :fields '((:name "headline"  :type "text")
            (:name "todo"      :type "enum" :values ["TODO" "NEXT" "DONE"])
            (:name "scheduled" :type "date")
            (:name "tags"      :type "string-list")
            (:name "ref"       :type "ref"))
  :query (lambda (p) (my/run-query (alist-get 'query p)))
  :cache-key (lambda (_p) (my/mtime)))
```

- **Field/param types are domain-neutral**: `text number boolean date
  string-list enum ref` (an `enum` needs a `:values` vector). A source
  *normalizes* engine data — Org timestamps → ISO dates, TODO keywords, tags →
  string lists — into these canonical types before core sees them.
- **Uncached by default.** Supply `:cache-key` to memoise one result per
  `(name, canonical-params, token)`; a query that errors is never cached.
  `jetpacs-source-invalidate` drops cached rows.
- Sources are **owned** (wrap registration in `with-jetpacs-owner`), so
  `jetpacs-app-unregister` tears them down.
- `jetpacs-source-catalog` enumerates sources for an editor (metadata only).

## Views — the `:spec` (`jetpacs-spec.el`)

`jetpacs-shell-define-view` takes a `:spec` plist instead of a `:builder`
(exactly one is required). A `:spec` describes a **complete view** — body plus
chrome:

```elisp
(jetpacs-shell-define-view "myapp.tasks"
  :tab '(:icon "check" :label "Tasks") :order 20
  :spec '(:source "myapp.tasks"
          :params ((query . "todo:TODO"))
          :layout "list"                         ; list | board | calendar
          :template <RAW-NODE-AST>               ; the per-item card
          :header   <RAW-NODE-AST>               ; optional (list only)
          :group-by (:field "todo" :order ["TODO" "NEXT" "DONE"] :empty-last t)
          :empty-state (:icon "inbox" :title "All clear")
          :chrome (:kind "tab" :fab <NODE>)))    ; or (:kind "nav" :title T :back "files")
```

Spec keys: `:source :params :layout :template :header :group-by :empty-state
:chrome`. Chrome kinds: `tab` (bottom-bar destination) and `nav` (back-arrow
screen); `:fab`/`:actions` in chrome are **static**. Dynamic gating stays on
`jetpacs-shell-define-view`'s own `:when`/`:overlay` predicates (those are code,
not data).

### Templates are raw node data with placeholders

A template is authored as a **raw wire node** (ordinary constructors aren't
promised to preserve placeholders). Any leaf may be a **placeholder**:

```elisp
((bind . "headline"))                 ; the raw field value
((bind . "scheduled") (as . "date-label"))
```

Transforms (`as`, default `raw`) are a closed set:

| transform | effect |
|---|---|
| `raw` | the value unchanged |
| `string` | coerced to a string |
| `date` | an ISO date, validated |
| `date-label` | an ISO date → `"Mon D"` |
| `tags-list` | a string-list → space-joined |
| `count` | length of a list/vector |
| `bool` | JSON `true`/`false` |
| `ref` | a ref locator object (for an action's args) |

A placeholder that resolves to nil **drops its containing attribute/child**, so
optional fields degrade cleanly. A bound field that the source doesn't declare
is a **lint error**, not a render crash.

Actions in a template reference a handler **by name**; their `args` may bind
fields (including the whole `ref`), and a single `_spread` entry merges a bound
object under literal keys:

```elisp
(on_tap . ((action . "heading.tap") (args . ((bind . "ref")))))
(on_pick . ((action . "heading.todo-set")
            (args . ((_spread . ((bind . "ref"))) (state . ((bind . "todo")))))))
```

### Layouts

| layout | shape |
|---|---|
| `list` | optional header, then one template per item, in a lazy column |
| `calendar` | ISO-date groups (`:group-by :field`) ascending, unscheduled last; each a date header + its item templates |
| `board` | one column per group value; order from an explicit `:order` vector, else the source field's `enum` `:values`, else encounter order; the empty group last when `:empty-last` |

> **v1 limitation.** A board card's per-card *"move to column X"* menu needs the
> whole column set inside each card (cross-item context) — beyond a per-item
> template. A board view that needs it keeps a `:builder`. Everything else
> (list, calendar, board grouping + tap) is declarative.

## Forms (`jetpacs-form*`)

A dialog's seed → read → clear lifecycle, without the hand-rolled generation
counter. `jetpacs-form` (owner+namespace-keyed), `jetpacs-form-field-id`
(rotates on reset — the rotation is what empties the on-device widget),
`jetpacs-form-value`, `jetpacs-form-seed` (seed-if-absent), `jetpacs-form-reset`,
`jetpacs-form-dispose`. `jetpacs-app-unregister` disposes an app's forms.

## Capability fallback (`jetpacs-node-or`)

`(jetpacs-node-or "month_grid" (my/grid) (my/list))` renders the primary when
the connected companion advertises the node, else the fallback — one branch
runs, locally, never wire data. A companion that sent no catalog is treated
permissively (primary); disconnected or catalog-omits takes the fallback.

## Enumeration for editors

`jetpacs-source-catalog` and `jetpacs-action-catalog` (with `:args`/`:doc`
metadata on `jetpacs-defaction`) let an editor list a pack's sources and
actions. Together with `docs/contract.json`'s `binding` block, that is
everything the composer needs to bind a view without reading elisp.
