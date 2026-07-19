;;; jetpacs-demo.el --- First-run welcome tab and on-device walkthrough -*- lexical-binding: t; -*-

;; The foundation's own onboarding.  Two pieces:
;;
;;   1. A "Start" tab that exists only before the walkthrough has ever
;;      been generated (and can be dismissed for good).  It teaches the
;;      single most important control on the screen — the M-x button —
;;      by making the user's first M-x invocation the thing that creates
;;      the rest of the tour.
;;
;;   2. `jetpacs-setup-demo', which writes a three-file guided tour into
;;      `jetpacs-demo-directory' and opens it in the phone editor:
;;      walkthrough.org (the whole app, screen by screen, for Emacs
;;      newcomers), org-basics.org (an org-mode course pitched at
;;      Obsidian/Logseq switchers, demonstrating every feature in its
;;      own text — including a live org-agenda exercise), and
;;      hello-app.el (a complete beginner-commented Tier 1 app to load,
;;      tap, edit, and reload).
;;
;; The files ship *inside the bundle* as string constants rather than as
;; repo files because Emacs's home on Android is app-private storage —
;; adb can't push into it, but Emacs itself can write there.  Setup
;; always overwrites exactly its own files (and touches nothing else),
;; so a mangled tour resets to pristine by running the command again.
;; Day-named dates in the content shift to land relative to the run day
;; (see `jetpacs-demo--date-anchor'), so the org course's agenda
;; exercise always has something scheduled today.
;;
;; The welcome tab needs no persisted "seen it" flag: it shows while
;; `jetpacs-demo-directory' does not exist and `jetpacs-demo-show-welcome'
;; is non-nil.  Generating the tour retires the tab; deleting the demo
;; folder brings it back; the skip button persists the defcustom off.

;;; Code:

(require 'jetpacs)
(require 'jetpacs-widgets)
(require 'jetpacs-surfaces)
(require 'jetpacs-shell)
(require 'jetpacs-files)
(require 'jetpacs-settings)

(defcustom jetpacs-demo-directory "~/jetpacs-demo/"
  "Directory `jetpacs-setup-demo' writes the walkthrough files into.
Must lie within `jetpacs-files-roots' to be reachable from the phone's
Files browser (the default is inside the Home root).  While this
directory does not exist, the first-run welcome tab is offered."
  :type 'directory :group 'jetpacs)

(defcustom jetpacs-demo-show-welcome t
  "When non-nil, offer the first-run Start tab until the tour exists.
The tab's skip button persists this to nil; the tour itself stays
available either way via \\[jetpacs-setup-demo]."
  :type 'boolean :group 'jetpacs)

;; ─── The walkthrough files ───────────────────────────────────────────────────

(defconst jetpacs-demo--files
  '(("walkthrough.org" . "#+title: The Jetpacs walkthrough
#+filetags: :tour:

Welcome!  This file is the guided tour of everything on this
phone.  It is long on purpose — read it in order once, then
keep it around as a reference, or delete the whole jetpacs-demo
folder when you are done (deleting it brings the Start tab
back; the tab's Skip button retires it for good).  You created
this file yourself a moment ago by running the command
jetpacs-setup-demo, and running that command again rewrites the
tour files back to pristine at any time.

If you are coming from Obsidian or Logseq: welcome especially.
You will feel at home faster than you expect, and the second
tour file, org-basics.org (sitting next to this one), maps
everything you know — vaults, wikilinks, tags, daily notes —
onto org-mode.  This file covers the app itself.

* 1. The big idea

Most phone apps are the program.  This one is not: the program
is Emacs — a text-and-everything environment from 1985 that
people still organize their lives in — running on this device,
and the app you are looking at is a *screen* for it.  Every
card, button, and list here was described by Emacs and sent
over; every tap is sent back.  When Emacs changes, the screen
follows, live.

Why care?  Because Emacs is thousands of small, named commands
operating on plain text files that you own.  Nothing here is
locked in an app's database.  And because the screens are
built from your Emacs, the app grows when you add things to
Emacs — you will load a whole new app into it from a text
file in chapter 13, without installing anything.

* 2. Emacs words vs. normal words

Emacs is older than the vocabulary the rest of computing
settled on, so it has its own.  The table below is most of
what you need (and it is also your first org-mode table —
this tour is itself an org file):

| Emacs says | It means                                   |
|------------+--------------------------------------------|
| command    | one named action, e.g. calendar            |
| M-x        | \"run a command by typing its name\"         |
| buffer     | anything open: a file, a list, output      |
| minibuffer | where Emacs asks questions (here: dialogs) |
| kill, yank | cut, paste                                 |
| kill ring  | clipboard history (plural clipboard!)      |
| major mode | a file type's behavior, e.g. org-mode      |
| point      | the cursor position                        |
| elisp      | Emacs's language; apps are written in it   |
| package    | an Emacs add-on (a plugin)                 |
| init file  | your config, ~/.emacs.d/init.el            |
| ~          | shorthand for the home folder              |
| C-, M-     | key shorthand: Ctrl-, Alt- (on desktops)   |

Keep one idea above all: *everything is a command*.  Menus and
buttons here are just shortcuts to commands, and any command —
including the thousands with no button — is reachable by name.
That is the next chapter.

* 3. The screen you are looking at

Three regions, on every main screen:

- *Top bar* — the screen's title, plus buttons.  On the main
  tabs it ends with the M-x button: the one showing a tiny
  >_ command prompt.  (One exception: while you are inside a
  folder, the Files top bar shows the folder's path with a
  back arrow — back out to the Files home screen and the
  button returns.)  Detail screens, like this editor, swap
  in a back arrow on the left instead.
- *Bottom bar* — the tabs: Files and Eval (plus the Start
  tab that retired itself when you ran the setup command).
  Apps you install later bring their own tab sets, reached
  through the menu's Apps entry — chapter 13.
- *The menu* — on a tab screen, tap the ☰ button top-left,
  or swipe in from the left edge (the swipe works even when
  a back arrow occupies that corner).  This drawer is the
  master list of destinations:

  - Manage apps — install app bundles (ch. 13)
  - Buffers — everything Emacs has open (ch. 5)
  - Messages — Emacs's own activity log
  - Project — a dashboard for a folder of work (ch. 10)
  - Databases — SQL sessions (ch. 11)
  - Tools — bookmarks, clipboard history, a shell… (ch. 9)
  - Settings — one screen: Jetpacs, Emacs, and each app (ch. 12)
  - Refresh data — re-fetch everything from Emacs

Two habits worth forming: main tabs refresh when you pull
down, and detail screens are left with the back arrow.  If a
screen ever seems stale, the drawer's \"Refresh data\" gets a
fresh copy of everything.

And one comfort, early: when Emacs is off or unreachable, the
app still opens and shows the last thing it saw — screens are
cached.  Taps that need Emacs simply do nothing until the
connection returns; it reconnects by itself.

* 4. M-x — run anything by name

The M-x button — the >_ in the top bar — is the most
important control in the app.  Tap it and a search box opens
over *every command this Emacs offers* (a short denylist of
desktop-only noise — mouse and scroll commands and the like —
stays hidden; the Eval tab can still reach anything).  Type a
few letters and the list filters as you type; tap a result
and it runs.  Cancel, and nothing happens at all.

Try it right now:

- [ ] Tap the back arrow to leave this editor.  (Nothing to
      save yet — but know for later: the back arrow never
      saves.)  If the top bar now shows this folder's path,
      tap its back arrow once more — the >_ button lives on
      the Files home screen.
- [ ] Tap the >_ button and type: calen
- [ ] Tap calendar in the list.

The phone hops to the Eval tab, which records the run: \"M-x
calendar\", then \"Command executed.\"  That looks anticlimactic
— where did the calendar go?  Commands do their work inside
Emacs: it built a calendar *buffer*.  The next chapter goes
to find it.  (Come back here the same way every time: Files
tab, jetpacs-demo folder, walkthrough.org.)

One more thing M-x teaches you: when a command needs input,
Emacs asks, and every question appears here as a dialog — a
text box, a yes/no choice, or another filtering picker like
M-x itself.  Nothing ever hangs waiting on an invisible
keyboard: dismiss a question and the command simply cancels
(yes/no questions answer \"no\"), and an unanswered dialog
gives up after a minute.

* 5. Buffers — everything Emacs has open

A *buffer* is Emacs's word for \"a thing currently open\".
Files are on disk; buffers are the live working copies, and
every list or bit of program output lives in one too.  (The
phone editor works through a hidden copy of its own, so the
file you are reading won't show in the list — but everything
commands create, and every file the desktop side opens,
does.)

Leave this editor with the back arrow, open the menu (☰),
and tap *Buffers*.  Cards, one per buffer — a ● marks
unsaved changes, and the small line under each name is the
file it belongs to (or a line count, for buffers that aren't
files).  Find *Calendar* — your M-x created it — and tap it.

A month grid, drawn by a text program four decades old,
readable on a phone.  This is the app's quiet superpower: it
can display *any* Emacs buffer, in your theme's colors, with
Emacs's own links and buttons turned into taps.  Three
things to know while you are inside a buffer view:

- The *Sections* button (top bar) jumps to a chapter,
  function, or heading of the buffer via a filtering picker.
- The *keyboard button* (bottom right) opens a searchable
  palette of the commands and menu entries that buffer
  offers.  This is how you use a mode's features without
  memorizing its keys.
- It is live — a buffer you are viewing re-renders within a
  second of changing in Emacs, so long output (a compile, a
  search) streams onto your phone as it happens.

One habit to know: the back arrow (or a back swipe) leaves a
buffer view, and Buffers always reopens on the list, never
mid-buffer.

- [ ] Extra credit: tap the >_ button, run describe-function,
      and answer its question with jetpacs-setup-demo.  Then
      menu → Buffers → *Help*.  Emacs's built-in
      documentation renders as a readable page, and every
      cross-reference in it is tappable.  All of Emacs is
      documented like this, from inside itself.

* 6. Files — your files, on your terms

The Files tab lands in Emacs's home folder on this device.
Folders first, then files; tap a folder to enter it, tap a
file to edit it.  The ⋮ on each card renames or deletes; the
\"New\" button creates a file or folder; \"..\" goes up a level.

Worth knowing:

- Paths here are written like ~/jetpacs-demo — the ~ is the
  home folder, the very screen the Files tab starts on.
- Emacs on Android lives in a private home folder.  The
  *Shared storage* card (when it appears) is the bridge to
  the rest of your phone — /sdcard, Documents, Downloads.
- The magnifier in the top bar searches *file contents*:
  every line containing your words, in the folder you are
  looking at and below it (huge scans stop early and say
  so).  Tap a hit to read it in context, then step
  hit-to-hit with the arrows in the top bar.  This is your
  \"search the vault\" equivalent.
- The app refuses to leave its allowed folders (home, your
  config, your org folder, shared storage) — a guardrail,
  not a limitation.

* 7. The editor

You are in it.  A plain, honest text editor with an Emacs
engine behind it:

- The header shows the file's name and state — \"saved\" or
  \"● modified\" — with Undo, Redo, Revert, and *Save*.  Save
  is the important one: *the back arrow does not save*, and
  it discards unsaved edits without asking.  Save first.
- The colors are not decoration guesses: Emacs itself
  highlights the file (this one as org-mode) and sends the
  colors over, in your theme.
- Completion: pause after typing a couple of letters and
  chips appear above the keyboard; tap one to finish the
  word.  In a plain file the chips are words already in the
  file; in code, the real symbols of the language.
- In elisp files, Emacs even proof-reads live: mistakes get
  underlined a few seconds after you stop typing, and the
  line above the keyboard documents whatever the cursor is
  on.

Exercises, right here in this list:

- [ ] Flip this checkbox to [X] by editing the text
- [ ] On the empty line under \"Type here:\", type walk,
      pause, and accept a chip — it offers \"walkthrough\", a
      word this file is full of

  Type here:

- [ ] Tap Save, and watch the header flip from \"● modified\"
      back to \"saved\"

Saving also reports back — a \"Saved walkthrough.org\"
message pops up at the bottom of this very screen; those
messages are called snackbars.  Emacs mirrors its own short status lines
to your phone too, as toasts — the brief notes Android
floats near the bottom.  When something seems silent, the
Messages screen in the menu holds the recent log (the last
hundred lines of Emacs's own record).

* 8. Eval — talk to Emacs directly

The Eval tab (short for *evaluate*) is a direct line to
Emacs: type a fragment of elisp — Emacs's own language —
into the box at the bottom, tap the send button, and the
result appears above, newest first.

- [ ] Switch to the Eval tab, type (+ 1 2 3), and send it.
      Emacs answers 6.
- [ ] Now try (jetpacs-shell-notify \"Hello from Emacs!\") —
      the greeting pops up at the bottom of the screen,
      raised by the same machinery every screen here uses.

Comforts worth knowing: the input box is a real elisp editor
(completion chips and live proof-reading included); every
history card has copy and re-run buttons; the last three
results stay in the variables *, ** and ***; and the
trash-can button up top clears the history.  Respect it like
a command line — Eval can do anything Emacs can — but the
tour itself is unbreakable: jetpacs-setup-demo restores it.

Between M-x (commands by name) and Eval (raw elisp), nothing
in Emacs is out of the phone's reach.

* 9. Tools — the drawer of useful things

Menu → Tools.  Six entries, each an Emacs feature wearing a
phone skin:

- *Bookmarks* — named saved places (a file, a position).
  Tap one to jump there.  Make them on desktop, use them
  here.
- *Kill ring* — the clipboard history.  Everything recently
  cut or copied in Emacs, newest first; the copy button on
  each card puts it on your *phone's* clipboard.  Copying a
  paragraph from Emacs into a text message goes through
  here.
- *Shell* — a real command line where your Emacs runs (on
  this phone, if that is where it lives), rendered as a
  transcript with an input row.  Enter sends; the stop
  button interrupts a stuck command.
- *Remote hosts* — your other machines, over SSH.  Servers
  from your ~/.ssh/config appear automatically; each offers
  its Files and a Shell.  The connection password is asked
  for on the phone.  Browsing your home server from the
  couch is exactly what this is for.
- *Processes* and *Timers* — what Emacs is running and what
  it has scheduled.  A peek behind the curtain.

* 10. Project — a home base for a folder of work

Menu → Project.  A *project* is just a folder Emacs
recognizes (usually by its .git directory).  Tap *Switch
project* to pick one — the dashboard then keeps that project
until you switch again (opening files from the Files tab
does not change it):

- *Find file* — type a path fragment, submit, and the list
  narrows to the project files that match.
- *Grep* — search the whole project by regular expression
  (a pattern language for search); results are tappable,
  with next/previous stepping.
- *Compile* — run the project's build command; output
  streams into a buffer you can watch live.
- *Shell* — a command line already in the project folder.
- *Version control* — the project's git status (with the
  Magit package installed, the full Magit experience — its
  menus appear as touch dialogs of toggles and buttons).
- *Switch project* — every project Emacs remembers, one tap
  away.

If it says \"No project here\", it means exactly that — switch
to a known project.  And if you don't program at all, this
chapter and the next will keep; skip freely.

* 11. Databases

Menu → Databases.  A front end for Emacs's SQL support.
Tapping a saved connection opens a database REPL — a
back-and-forth transcript: type a query, read the answer.
Back on the Databases screen, an *Active session* section
has appeared, with *List tables* to ask the session what it
contains.  No saved connections?  The *New connection* card
starts a session for any database product Emacs supports, no
elisp needed; saved favorites are defined in elisp via
sql-connection-alist.

* 12. Settings, themes, and the iceberg

The menu has *two* settings entries, and the difference
matters:

*Settings* is one screen.  At the top sits *Companion theme*
— what this app looks like — because it spans both worlds.
Below it, one entry per place settings live: *Jetpacs*
first, *Emacs* second, then each app you've installed.

- *Jetpacs* — the Android app's own settings: permissions,
  notifications, pairing, offline data, dialog style, and
  the app/system knobs.  Works even while Emacs is off.
- *Emacs* — settings that live in Emacs, rendered as a phone
  screen.  Changes are saved into the connected Emacs's own
  configuration file (custom.el) — the same mechanism
  desktop Emacs uses, not an app-private store.

*Companion theme* decides what this app looks like:

- Default — the app's own scheme, Emacs purple.
- Material — colors derived from your wallpaper (Android
  12+).
- Emacs — mirror the theme of Emacs itself; the app then
  recolors live every time Emacs changes theme.

(Under *Jetpacs*: *Dialog style* — how Emacs's questions
render.  Under *Emacs*: *Auto-reconnect* and a read-only
build-features row, a quick health check of what this Emacs
can do.)

Below the sections sit four doorway cards:

- *Packages* — Emacs's add-on library (this is where
  \"plugins\" live; thousands of them, maintained for
  decades).  Tap \"Refresh archives\" once, then search,
  install, uninstall.  Tap any package for its description.
- *Automations* — device triggers: \"when the charger
  connects, at 7am, when the network changes — tell
  Emacs.\"  Triggers are defined in your init file; this
  screen enables, tests, and inspects them.
- *Customize* — the iceberg.  The curated settings above
  are a handful; Emacs itself has options for *everything*,
  organized in groups, and this browser walks all of them.
  It says so itself: many are desktop options that won't
  change the phone experience — but this is the same
  system desktop Emacs users live in.
- *Modus Themes* — pick the theme *of Emacs* (not of the
  app — that is Companion theme, at the top of Settings).
  The modus family
  ships inside Emacs: carefully designed, high-contrast
  themes, light (\"operandi\") and dark (\"vivendi\"), with
  style switches to taste.  The \"Mirror on phone\" chip
  connects the two worlds: pick a theme, mirror it, and
  the whole app dresses to match your Emacs.

- [ ] Try it: Settings → Emacs → Modus Themes → pick one →
      Mirror on phone.  Change your mind freely — it
      re-mirrors on every switch.

* 13. Apps — teach the phone new tricks

Everything so far ships with the foundation.  Jetpacs apps
are elisp files that add whole new screens — and the third
file of this tour is one.  Open hello-app.el from this
folder and read it first: under seventy lines, half of them
comments.  Then load it into the running Emacs:

- [ ] Go to the Eval tab and run:

  (load \"~/jetpacs-demo/hello-app.el\")

  (Type it exactly — straight quotes from the keyboard, not
  curly ones.)

- [ ] Open the menu — a new entry, *Apps*, appeared.  Tap
      it: two apps now, Jetpacs and Hello.  Open Hello and
      tap its button a few times.
- [ ] Make it yours: open hello-app.el in the editor,
      change the CHANGE ME greeting, Save, run the load
      line again.  Apps → Hello: your words on screen.

No rebuild, no store, no restart — a text file became an app
while both were running.  That is the whole product in one
exercise.  (Tidy up with (jetpacs-app-unregister \"hello\") in
Eval, if you like.)

Real apps arrive the same way, just packaged: an app bundle
is an .el file dropped into /sdcard/Documents/jetpacs, and
menu → *Manage apps* lists and installs what it finds there.
(One Android quirk: a downloaded bundle sometimes arrives
renamed to .el.txt — rename it back to .el and it appears.)
Mind the consent dialog and mean it: \"This is Emacs Lisp:
once installed it runs with full access to your Emacs and
files, now and on every start.\"  Install only what you
trust.  (App bundles and Emacs *packages* — chapter 12 —
are different things: bundles are Jetpacs apps; packages
extend Emacs itself.)

Screens are not the limit, either: apps can post
notifications, set exact-time reminders, pin launcher
shortcuts, and fill Quick Settings tiles — that is what the
permission rows in Settings → Jetpacs are about.

The flagship app is *Glasspane*, which turns org files into
a full notes app — foldable outlines, agenda, capture,
flashcards.  If the org chapter below hooks you, that is
the next thing to install.

* 14. Your notes — org-mode

Everything in this phone's world is plain text, and the
dialect Emacs people use for notes, tasks, and life is
org-mode.  The file next to this one — *org-basics.org* — is
a complete beginner's course, written for people who know
Obsidian or Logseq: what maps to what, how TODO keywords,
priorities, tags, dates, and properties work, and what an
\"agenda\" even is (you will summon a real one from this very
tour).  It demonstrates every feature in its own text, so
read it in this editor and poke at it as you go.

(The core app you are using now edits org as text, with real
org highlighting.  Rich org rendering — folding, agenda
views, tap-to-toggle checkboxes — is what Glasspane adds.)

* 15. When you outgrow the phone

This app is a companion, and honest about it: the full Emacs
experience — split windows, the agenda, Magit, writing your
own commands — lives on a desktop.  The good news: you have
been using real Emacs this whole time.  Your settings live
in a plain config file — copy your Emacs config to the
desktop and they come along.  Your org files are already the
right format.  The commands you met through M-x have the
same names everywhere, forever.

When you get curious:

- Install Emacs on any computer — free, every OS.
- Run its built-in interactive tutorial: C-h t (key
  shorthand: hold Ctrl and press h, then press t) — an
  hour, at your own pace.
- Add the packages you already tried from the phone.
- Keep the phone paired: desktop for deep work, this app
  for everywhere else.

* 16. Cheat sheet

| I want to…               | Do this                        |
|--------------------------+--------------------------------|
| run any Emacs command    | the >_ button (M-x)            |
| see what's open          | menu → Buffers                 |
| read Emacs's log         | menu → Messages                |
| browse and edit files    | Files tab                      |
| search inside files      | Files tab → magnifier          |
| run elisp by hand        | Eval tab                       |
| copy Emacs text to phone | menu → Tools → Kill ring       |
| a command line           | menu → Tools → Shell           |
| reach my other machines  | menu → Tools → Remote hosts    |
| work on a repo           | menu → Project                 |
| change the app's look    | Settings → Companion theme     |
| change Emacs's theme     | Settings → Emacs → Modus Themes|
| install Emacs add-ons    | Settings → Emacs → Packages    |
| install Jetpacs apps     | menu → Manage apps             |
| reset this tour          | M-x jetpacs-setup-demo         |
| retire this tour         | delete jetpacs-demo in Files,  |
|                          | then Skip the Start tab        |

Thanks for reading this far.  Go make the tour messy — it
reverts with one command, and everything else here is yours.
")
    ("org-basics.org" . "#+title: Org-mode basics — for Obsidian and Logseq people
#+author: The Jetpacs tour
#+filetags: :tour:
#+todo: TODO NEXT WAIT | DONE CANCELLED

This file is a crash course in org-mode, the plain-text format
Emacs people keep their lives in.  If you come from Obsidian or
Logseq you already believe the important part — your notes
should be plain text files you own, on your own device, readable
by any program, forever.  Org is the same idea, older and
deeper: it dates from 2003, it is built into Emacs, and a good
chunk of Logseq — its TODO keywords, priorities, and org file
support — was borrowed from it directly.

Two things before we start:

1. This file demonstrates everything it teaches.  Every feature
   below is written in real org syntax, so the file is its own
   cheat sheet.  Scroll slowly and look at how each thing is
   typed.
2. Org is just text.  There is no database, no export step, no
   lock-in.  If you stop using it, your files still read fine in
   Notepad.  (Your Obsidian instincts apply unchanged.)

* The Rosetta table

A quick mapping from the words you know to the words org uses:

| You know (Obsidian/Logseq)   | Org calls it                  |
|------------------------------+-------------------------------|
| vault / graph                | a folder of .org files        |
| note / page                  | a file, or a heading          |
| # Heading (markdown)         | * Heading (stars)             |
| **bold**  *italic*           | *bold*  /italic/              |
| - [ ] task / TODO block      | - [ ] checkbox, or a TODO     |
| #tag                         | :tag: on a heading            |
| Properties (YAML), key:: val | #+keywords and :PROPERTIES:   |
| =[[wikilink]]=               | =[[file:note.org][a link]]=   |
| daily notes / journals       | dates + the agenda            |
| Dataview / Bases / {{query}} | the agenda (a computed view)  |
| plugins                      | packages (written in elisp)   |

Logseq users have a head start: Logseq's TODO keywords and
[#A] priorities were lifted straight from org, its page
properties are close cousins of org's, and classic file-based
Logseq can even store its whole graph as .org files —
imperfectly, but enough that you may already write org without
knowing it.

* Headings are the skeleton

A line starting with stars is a heading; more stars, deeper
level.  Where markdown uses #, ##, ###, org uses *, **, ***.

** Like this second-level heading
*** And this third-level one

Unlike a markdown file, an org file is an *outline* the whole
way down.  On desktop Emacs (and in the Glasspane app) you fold
and unfold headings like Logseq blocks, move whole subtrees up
and down, and narrow the view to one branch.  In this phone
editor you simply see the text — which is the point: it is only
text.

* Markup inside a line

Org emphasis wraps words in punctuation, one character each
side:

- *bold* — asterisks
- /italic/ — slashes
- _underline_ — underscores
- =verbatim= — equals signs, for literal text
- ~code~ — tildes, for code-ish words like ~M-x~
- +strikethrough+ — plus signs

They only trigger around whole words, so a stray underscore in
a name like my_file_name does not italicize your paragraph — a
common markdown gripe org does not share.

(One more thing about =verbatim=: it is also how this file
shows syntax without triggering it.  When an exercise tells
you to type something, never type the = signs.)

* Lists and checkboxes

Plain lists use - or + or numbers:

1. Ordered items renumber themselves on desktop
2. when you add or move lines
   - and lists nest by indentation
   - like you would expect

Description lists pair a term with its meaning:

- org :: the format you are reading about
- elisp :: the language Emacs (and Jetpacs) is written in

Checkboxes are list items with [ ] or [X], exactly like the
checkboxes you know — with progress counting built in, no
Tasks plugin needed:

** Try it here [1/3]
- [X] Read this far
- [ ] Edit one of these boxes from [ ] to [X]
- [ ] Notice the [1/3] above does not update by itself here —
      on desktop, one key combo (C-c C-c: Ctrl+c, twice)
      reticks it

That [1/3] is a \"statistics cookie\".  Write [/] or [%] after a
heading and org keeps score of the checkboxes below it.

* TODO — tasks are just headings

Any heading can become a task by starting it with a keyword:

** TODO buy oat milk
** DONE read the walkthrough
CLOSED: [2026-07-17 Fri 21:04]

TODO and DONE are the defaults.  The #+todo: line at the top of
this file defines a richer set — TODO, NEXT, WAIT, then DONE
and CANCELLED after the bar (states after | count as finished).
Logseq's NOW / LATER / DOING are the same mechanism with
different words.

** NEXT an example of a custom state
** WAIT blocked on someone else
** CANCELLED an example of the other done-state

The keyword is literally part of the text.  Change TODO to DONE
by editing the word, here on the phone or anywhere else.  On
desktop a single key cycles a heading through your states —
and once you ask org to log completions (a setting called
org-log-done), it timestamps each one; the CLOSED line above
is what that looks like.

* Priorities

A cookie right after the keyword ranks a task:

** TODO [#A] pay rent
** TODO [#B] reply to Sam
** TODO [#C] reorganize the garage, someday

A, B, C by default.  The agenda (below) sorts by these.  Logseq
users: yes, identical syntax — that is where Logseq got it.

* Tags

Tags sit at the end of a heading line, wrapped in colons:

** Call the dentist                             :phone:errand:

Two rules worth knowing:

- Tags *inherit*: a heading under a :work: heading is also
  :work:, so you tag the project once, not every task.
- The #+filetags: line at the top of this file tags the whole
  file (this one is :tour:), like tags in frontmatter.

Tags are case-sensitive — :Work: and :work: are different — so
pick a convention and stay with it.

* Dates, and what an \"agenda\" even is

This is org's superpower, and the thing hardest to see from a
markdown world, so take it slowly.

An org timestamp is a date in angle brackets:

<2026-07-20 Mon>

On a heading of its own, a bare date — with a time if you
like, <2026-07-20 Mon 10:00> — marks an *appointment*: it
shows up in the agenda at that time.  Meetings use this;
tasks use the two keywords below, attached on the line under
the heading:

** TODO water the plants
SCHEDULED: <2026-07-18 Sat +1w>

** TODO file the expense report
DEADLINE: <2026-07-31 Fri>

- SCHEDULED means \"start (or do) it that day\".
- DEADLINE means \"it is due that day\" — warnings begin days
  before.
- The +1w is a *repeater*: when you mark it DONE, the date
  hops forward one week and the task comes back.  +1d, +1m,
  +1y all work.  This is how people do habits in org.

Square-bracket stamps like [2026-07-17 Fri] are *inactive*:
notes for the record, invisible to scheduling.  The CLOSED
line earlier is one.

Now the payoff.  The *agenda* is a live view that scans all
your org files and shows, for today (or the week), everything
scheduled, due, or overdue — sorted by time and priority.
Think of it as a saved Dataview/Logseq query, except it is
built in and every org user's daily home screen.  Your daily
note stops being a page you write and becomes a view org
computes for you.  (Its one-file cousin is the *sparse tree*:
fold a single file down to just the headings matching a
search.)

Desktop Emacs and the Glasspane app render agendas richly —
but you can summon a plain one right now, from this file:

1. In the Eval tab, run:
   (setq org-agenda-files (list \"~/jetpacs-demo/\"))
2. Tap the >_ button and run org-agenda.  A question box
   appears — answer with the single letter a.
3. Open the menu → Buffers → *Org Agenda*: this very file's
   tasks, laid out over the week — \"water the plants\" is
   scheduled today.

(The tour re-anchors its dates to today every time
jetpacs-setup-demo runs, so there is always something due.)

* Properties — data on your notes

Obsidian frontmatter and Logseq's key:: values map to two org
mechanisms, one per scope:

1. File-level: the #+keyword lines at the very top of this
   file (#+title:, #+author:, #+filetags:).  Metadata about
   the whole file.

2. Heading-level: a :PROPERTIES: drawer directly under a
   heading, holding KEY: VALUE pairs for just that subtree:

** The Jetpacs project
:PROPERTIES:
:ID:       9f2c1a34-tour-demo-heading-id
:STARTED:  [2026-07-14 Tue]
:EFFORT:   2h
:END:

That block is called a *drawer* — a labeled, foldable pocket
of metadata that stays out of your prose.  Keys are yours to
invent.  On desktop, properties are queryable (\"show every
heading with :EFFORT: under 1h\"), like Dataview fields.

The :ID: property deserves a special mention — next section.

* Links

The full form is two pairs of brackets, target then label:

- Web: [[https://orgmode.org][the org-mode site]]
- Another file: [[file:walkthrough.org][the app tour]]
- A heading anywhere, by its :ID: property:
  [[id:9f2c1a34-tour-demo-heading-id][the properties example]]

That last one is the org answer to wikilinks, with a twist
worth appreciating: the link points at the heading's ID, not
its name — rename the heading, even move it to another org
file Emacs knows about, and the link still resolves.  No
rename-refactor anxiety.

Images ride the same syntax: a link to an image file on its
own line — =[[file:photo.png]]= — displays the picture inline
on desktop and in Glasspane (this phone editor shows the link
as text).  For heavier attachments, org-attach files things
under a heading.

Footnotes exist too[fn:1], with the definition wherever you
like (this one is at the bottom of the file).

* Tables that calculate

Type | between cells; on desktop, TAB realigns the whole table
as you go (the neat columns below were made that way, not by
counting spaces):

| item     | qty | price | total |
|----------+-----+-------+-------|
| coffee   |   2 |  9.50 | 19.00 |
| filters  |   1 |  4.25 |  4.25 |
|----------+-----+-------+-------|
| together |     |       | 23.25 |
#+tblfm: @>$4=vsum(@I..@II)

The #+tblfm: line is a *formula*: the last cell is the sum of
the totals column, recomputed by Emacs on demand.  A plain-text
table that is also a tiny spreadsheet — no plugin.

* Blocks — quoting and code

#+begin_quote
Block syntax fences off regions, like triple-backticks in
markdown.  This one is a quote block.
#+end_quote

#+begin_src emacs-lisp
;; A source block, with a language tag.  On desktop (and in
;; Glasspane) org can EXECUTE these and insert the result
;; below — notes that compute, called \"babel\".
(+ 1 2 3)
#+end_src

#+begin_example
Example blocks hold literal text, untouched by org.
#+end_example

* Odds and ends you will meet

- A line of five dashes is a horizontal rule:

-----

- Lines starting with \"# \" are comments — visible in the file,
  dropped from every export.

# like this one

- Export: on desktop, org converts to HTML, PDF, Markdown,
  and slides from the same file.  Your notes are also your
  documents.

* Bringing your vault over

You do not have to start empty:

- From Obsidian: pandoc converts markdown to org in bulk
  (pandoc -f markdown -t org).  Start with a handful of
  active notes rather than the whole vault — conversion is
  a chance to prune.
- From Logseq: classic file-based Logseq can already keep
  its graph in org format.
- Getting files onto the phone: copy them into shared
  storage (the walkthrough's Files chapter shows the
  /sdcard bridge), or point a sync tool at your org folder.
- Syncing: these are plain text files — Syncthing, git, or
  any file-sync service works.  Nothing here needs a
  proprietary sync.

* Where org goes from here

Everything above is the format.  The ecosystem on top is where
people get hooked:

- The *agenda*, once your TODOs and dates accumulate.
- *Capture*: a hotkey that files a thought into an inbox
  without leaving what you were doing.
- *Refile*: send a heading to the right file with a
  keystroke — the org version of dragging blocks between
  pages.
- *Archive*: sweep finished tasks into a side file, keeping
  your working files lean.
- *org-roam*: backlinks and graph over org files, if you want
  your Obsidian workflow verbatim.
- *Time tracking*: clock in on any heading; :LOGBOOK: drawers
  record the minutes.
- *Spaced repetition*, *habit tracking*, *invoicing from clock
  tables* — it is a deep well.

On this phone, the Glasspane app renders org files as a real
notes app — foldable outlines, agenda, capture, flashcards.
On desktop, Emacs does all of it.  Either way the files stay
plain text, synced however you like, owned by you.

When you are ready to try the desktop side, the walkthrough's
last chapter has a gentle route in.

* Footnotes

[fn:1] Footnote definitions look like this.  Org renumbers and
navigates them for you on desktop.
")
    ("hello-app.el" . ";;; hello-app.el --- Your first Jetpacs app: load, tap, edit, reload

;; This is a COMPLETE Jetpacs app.  Load it into the running Emacs
;; from the phone's Eval tab:
;;
;;   (load \"~/jetpacs-demo/hello-app.el\")
;;
;; An app launcher appears (menu -> Apps) with a new app, Hello.
;; No restart, no install step: registering an app on a live
;; session refreshes the phone by itself.
;;
;; Then make it yours: change the CHANGE ME line below, tap Save,
;; run the load line again, and reopen Hello.

(require 'jetpacs-core)

;; State lives in Emacs, not on the phone.  The screen below is
;; rebuilt from these two variables on every push.  `defvar' keeps
;; its value when the file reloads (the tap count survives);
;; `defconst' re-applies on every load, so your greeting edit shows.

(defvar my-hello-taps 0
  \"How many times the big button has been tapped.\")

(defconst my-hello-greeting \"Hello from your own app!\" ; <- CHANGE ME
  \"The headline the Hello screen shows.\")

(defun my-hello--body ()
  \"Build the screen: plain data describing widgets.\"
  (jetpacs-column
   (jetpacs-card
    (list (jetpacs-column
           (jetpacs-text my-hello-greeting 'title)
           (jetpacs-text (format \"Built inside %s\" (emacs-version))
                      'caption))))
   (jetpacs-card
    (list (jetpacs-column
           (jetpacs-text (format \"Taps so far: %d\" my-hello-taps)
                      'headline)
           (jetpacs-button \"Tap me\" (jetpacs-action \"hello.tap\")))))))

(with-jetpacs-owner \"hello\"

  ;; The button above names the action \"hello.tap\"; this handler
  ;; decides what that means.  The phone can only name actions,
  ;; never send code.
  (jetpacs-defaction \"hello.tap\"
    (lambda (_args _payload)
      (setq my-hello-taps (1+ my-hello-taps))
      (jetpacs-shell-notify (format \"Tap %d!\" my-hello-taps))
      (jetpacs-shell-push)))

  ;; A view is a named screen; :tab puts it in the bottom bar
  ;; while the Hello app is open.
  (jetpacs-shell-define-view \"hello\"
    :builder (lambda (snackbar)
               (jetpacs-shell-tab-view \"hello\" (my-hello--body)
                                    :snackbar snackbar))
    :tab '(:icon \"waving_hand\" :label \"Hello\")
    :order 5)

  ;; And the app itself: a launcher card owning that view.
  (jetpacs-defapp \"hello\" :label \"Hello\" :icon \"waving_hand\"
               :views '(\"hello\")))

;; Undo everything:  (jetpacs-app-unregister \"hello\")

;;; hello-app.el ends here
"))
  "Alist of (FILENAME . CONTENT) written by `jetpacs-setup-demo'.")

;; ─── Relative dates ──────────────────────────────────────────────────────────

(defconst jetpacs-demo--date-anchor "2026-07-18"
  "The \"today\" the tour files above were authored against.
Setup shifts every day-named timestamp by (today − anchor) days at
write time, so org-basics.org's date examples keep their authored
spread — something scheduled today, a deadline weeks out — relative
to the day the command runs, and its agenda exercise always has
something due.  Editing tour dates means re-anchoring this to the
new authoring day.")

(defun jetpacs-demo--noon (date)
  "Encoded noon of DATE (\"YYYY-MM-DD\"); noon dodges DST date flips."
  (encode-time 0 0 12
               (string-to-number (substring date 8 10))
               (string-to-number (substring date 5 7))
               (string-to-number (substring date 0 4))))

(defun jetpacs-demo--shift-dates (content days)
  "CONTENT with every day-named \"YYYY-MM-DD Day\" date moved DAYS forward.
One rewrite covers every org form in the tour — active and inactive
stamps, CLOSED lines, repeaters — because all of them carry the
day-named date; whatever follows it (a time, a repeater cookie) rides
along untouched.  Day names are recomputed in the C locale to match
the authored style."
  (if (zerop days) content
    (let ((system-time-locale "C"))
      (replace-regexp-in-string
       "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} \\(?:Mon\\|Tue\\|Wed\\|Thu\\|Fri\\|Sat\\|Sun\\)"
       (lambda (stamp)
         (format-time-string
          "%Y-%m-%d %a"
          (time-add (jetpacs-demo--noon (substring stamp 0 10))
                    (days-to-time days))))
       content t t))))

(defun jetpacs-demo--date-shift ()
  "Days from the tour's authoring anchor to today."
  (- (time-to-days (current-time))
     (time-to-days (jetpacs-demo--noon jetpacs-demo--date-anchor))))

;; ─── Setup ───────────────────────────────────────────────────────────────────

;;;###autoload
(defun jetpacs-setup-demo (&optional dir)
  "Write the guided tour into DIR (default `jetpacs-demo-directory') and open it.
Overwrites exactly the files named in `jetpacs-demo--files' — anything
else in the directory is untouched — so re-running resets the tour to
pristine.  On a connected phone the walkthrough opens in the editor;
the navigation is deferred past the calling action's own push (M-x
lands on the Eval tab after every command — this must land later).
Returns the directory written to."
  (interactive)
  (let ((dir (file-name-as-directory
              (expand-file-name (or dir jetpacs-demo-directory))))
        ;; The tour text is non-ASCII (em-dashes); pin utf-8 so no
        ;; platform default can make write-region prompt.
        (coding-system-for-write 'utf-8))
    (make-directory dir t)
    (let ((shift (jetpacs-demo--date-shift)))
      (dolist (spec jetpacs-demo--files)
        (write-region (jetpacs-demo--shift-dates (cdr spec) shift)
                      nil (expand-file-name (car spec) dir)
                      nil 'silent)))
    (when (jetpacs-connected-p)
      (run-at-time
       0.1 nil
       (lambda ()
         ;; The welcome tab just lost its reason to exist; make "files"
         ;; the logical tab before the retired name can go stale, then
         ;; land the user in the walkthrough itself.
         (jetpacs-shell-push "files")
         (jetpacs-shell-notify
          (format "The tour lives in %s — this file is yours to edit"
                  (abbreviate-file-name (directory-file-name dir))))
         (jetpacs-files-open (expand-file-name (caar jetpacs-demo--files)
                                               dir)))))
    (when (called-interactively-p 'interactive)
      (message "Jetpacs walkthrough written to %s" dir))
    dir))

;; The verb-order twin, for muscle memory from the Glasspane app's
;; `glasspane-demo-setup' (and either spelling is findable from M-x).
(defalias 'jetpacs-demo-setup #'jetpacs-setup-demo)

;; ─── The welcome tab ─────────────────────────────────────────────────────────

(defun jetpacs-demo--welcome-p ()
  "Non-nil while the welcome tab should be offered.
Stateless: the tour not existing IS the first-run condition."
  (and jetpacs-demo-show-welcome
       (not (file-directory-p (expand-file-name jetpacs-demo-directory)))))

(defun jetpacs-demo--welcome-view (snackbar)
  "The first-run Start tab: name the M-x button, prompt the tour command."
  (jetpacs-shell-tab-view
   "welcome"
   (jetpacs-lazy-column
    (jetpacs-card
     (list (jetpacs-column
            (jetpacs-text "Welcome to Jetpacs" 'title)
            (jetpacs-text
             (concat "Your phone is now a screen for Emacs.  Every screen "
                     "here is built by the Emacs you paired with, and "
                     "follows it live.")
             'body))))
    (jetpacs-card
     (list (jetpacs-column
            (jetpacs-row
             (jetpacs-icon "terminal")
             (jetpacs-text "This button is M-x" 'headline))
            (jetpacs-text
             (concat "Emacs is thousands of commands, each with a name, and "
                     "the terminal-shaped button in the top bar runs any of "
                     "them: tap it, type a few letters, tap the match.  It "
                     "rides the top bar of every tab, and it is how you "
                     "reach anything not already on screen.")
             'body))))
    (jetpacs-card
     (list (jetpacs-column
            (jetpacs-text "Try it now" 'headline)
            (jetpacs-text "1. Tap the terminal button in the top bar." 'body)
            (jetpacs-text "2. Type: jetpacs-setup-demo" 'body)
            (jetpacs-text "3. Tap the match." 'body)
            (jetpacs-text
             (concat "It writes a guided tour — three small files — onto "
                     "this device and opens it.  This tab retires once the "
                     "tour exists; the same command brings the tour back "
                     "anytime.")
             'caption))))
    (jetpacs-button "Skip the tour"
                 (jetpacs-action "jetpacs.demo.skip" :when-offline "drop")
                 :variant "text"))
   :snackbar snackbar))

(jetpacs-shell-define-view "welcome"
  :builder #'jetpacs-demo--welcome-view
  :tab '(:icon "flag" :label "Start")
  :when #'jetpacs-demo--welcome-p
  :order 10)  ; leftmost tab — the landing view on a fresh install

;; ─── Wire actions ────────────────────────────────────────────────────────────

(jetpacs-defaction "jetpacs.demo.setup"
  ;; Allowlisted and argument-free: always writes the fixed file set into
  ;; `jetpacs-demo-directory' — nothing on the wire chooses paths or content.
  (lambda (_ _) (jetpacs-setup-demo)))

(jetpacs-defaction "jetpacs.demo.skip"
  (lambda (_ _)
    ;; Persisted through the settings seam (surfaces the no-custom-file
    ;; case) — a skip that silently un-skipped on restart would be worse
    ;; than no button.
    (jetpacs-settings-save-variable 'jetpacs-demo-show-welcome nil)
    ;; The tab the user is standing on just disappeared; land on Files.
    (jetpacs-shell-push "files")))

(jetpacs-settings-register-section
 "Welcome tour"
 '((jetpacs-demo-show-welcome
    :label "Offer the Start tab until the tour exists")))

(provide 'jetpacs-demo)
;;; jetpacs-demo.el ends here
