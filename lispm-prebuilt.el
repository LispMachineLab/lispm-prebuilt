;;; lispm-prebuilt.el --- Native code of LispM's packages, downloaded and checked  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-prebuilt
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Some of LispM's packages run native code: a module Emacs loads, or a
;; program it runs.  Nobody has to build it or say where it is.  The one
;; the package's workflow built for this computer from the sources there
;; are is downloaded, and kept only when its SHA-256 is the one pinned
;; beside the package's Lisp.  Those checksums come with the Lisp, from
;; the package's signed history, not from the release, so a file changed
;; on the release after it was pinned is refused.  Building is asked for,
;; never done because a compiler happens to be there.
;;
;; A package says what it ships, once:
;;
;;   (lispm-prebuilt-define 'lispm-gl-module
;;     :title "lispm-gl's module"
;;     :root (expand-file-name "native" ...)      ; its sources are here
;;     :sources '("Cargo.toml" "Cargo.lock" ("src" "\\.rs\\'"))
;;     :targets '("aarch64-apple-darwin" "x86_64-apple-darwin")
;;     :release "gl-module-%v"                    ; under :url
;;     :asset "lispm-gl-module-%t%e.gz"           ; in the release
;;     :file "lispm-gl-module-%t%e"               ; kept, unpacked
;;     :url 'lispm-gl-module-prebuilt-url         ; variables of its own
;;     :source 'lispm-gl-module-source            ; `download' or `build'
;;     :sums (expand-file-name "lispm-gl-module-sums.eld" ...)
;;     :build '("cargo" "build" "--release" "--target" "%t")
;;     :built "target/%t/release/liblispm_gl%e")
;;
;; %t is the target, as aarch64-apple-darwin, %e the suffix of a library
;; there, .dylib or .so, and %v the version of the sources: the first 16
;; digits of the SHA-256 of what sha256sum writes for them in :root.  An
;; asset ending in .tar.gz is unpacked into a directory, which must hold
;; the :files it names, the first the one to run; one ending in .gz is
;; one file, unzipped.  Downloads are kept in prebuilt/VERSION/ of :root,
;; or :prebuilt, those of other versions removed.
;;
;; Then, for each, the same:
;;
;;   `lispm-prebuilt-get'       the file, downloaded and checked in the
;;                              background, then a callback: Emacs does
;;                              not wait
;;   `lispm-prebuilt-ensure'    the file, Emacs waiting for it, for code
;;                              that cannot wait
;;   `lispm-prebuilt-load'      a module, loaded
;;   `lispm-prebuilt-batch-pin' the pins of a release, written, for a
;;                              workflow or `make pin'
;;
;; In the background, downloads go through `lispm-prebuilt-fetch-function':
;; curl, as a process of Emacs's own; lispm-kernel advises it to have its
;; kernel fetch instead.  Unpacking runs through lispm-agent's `lispm-exec'
;; where it is there, else as a process of Emacs's own.  A package fetches
;; and runs what else it needs in the background with them too:
;; `lispm-prebuilt-fetch' and `lispm-prebuilt-run'.

;;; Code:

(require 'cl-lib)
(require 'format-spec)
(require 'seq)
(require 'subr-x)

(declare-function lispm-exec "lispm-exec" (program args callback &rest keys))

(defgroup lispm-prebuilt nil
  "Native code of LispM's packages, downloaded and checked."
  :group 'applications
  :prefix "lispm-prebuilt-")

(defcustom lispm-prebuilt-timeout 300
  "Seconds a download may take before it fails."
  :type 'integer)

(defvar lispm-prebuilt-fetch-function #'lispm-prebuilt-fetch-with-curl
  "The function downloading for `lispm-prebuilt-get', in the background.
It is called with URL, FILE and CALLBACK, and the keyword :timeout,
seconds.  It returns at once, and calls CALLBACK later with nil once
FILE holds what URL does, or with a sentence saying why not, FILE
removed.  lispm-kernel advises it, with `add-function', to have its
kernel fetch.")

(defconst lispm-prebuilt-target-configurations
  '(("aarch64-apple-darwin" . "\\`\\(?:aarch64\\|arm64\\)-apple-darwin")
    ("x86_64-apple-darwin" . "\\`x86_64-apple-darwin")
    ("aarch64-unknown-linux-gnu" . "\\`aarch64-[^-]+-linux-gnu\\'")
    ("x86_64-unknown-linux-gnu" . "\\`x86_64-[^-]+-linux-gnu\\'"))
  "The targets known, and the `system-configuration' each is published for.")

(defvar lispm-prebuilt--specs (make-hash-table :test #'eq)
  "What each package ships, by name, a plist of `lispm-prebuilt-define'.")

(defvar lispm-prebuilt--waiting (make-hash-table :test #'eq)
  "The callbacks waiting for a download under way, by name, oldest first.")

;;;; Defining

(defun lispm-prebuilt-define (name &rest properties)
  "Say what NAME, a symbol, ships: PROPERTIES, as the Commentary shows.
:title       what it is called in messages, as \"lispm-gl's module\"
:noun        what it is, \"module\" by default, as \"engine\"
:root        the directory of its sources, which name them
:sources     its sources: file names, and (DIRECTORY REGEXP) for the
             files matching REGEXP under DIRECTORY, and (DIRECTORY
             REGEXP flat) for those in DIRECTORY itself
:targets     the targets it is published for
:url         the variable holding where its releases are
:source      the variable holding `download' or `build'
:release     the release of the sources of version %v
:asset       what is published for target %t: .gz, or .tar.gz
:file        a .gz asset's file, kept unpacked
:files       a .tar.gz asset's files, the first the one to run
:prebuilt    where downloads are kept, by default prebuilt/ of :root
:sums        the file of pinned checksums
:key         the key of the pins' alist there, :modules by default
:build       the command building it in :root, a list of strings
:built       what that builds for target %t, a file name in :root
:build-needs the program building needs, by default the command's
:pin-check   the environment variable asking `lispm-prebuilt-batch-pin'
             only to check
A value may be a function, called for it each time it is needed, as for
one a variable holds that a test binds.  Return NAME."
  (dolist (required '(:title :root :sources :targets :url :source :release :asset :sums))
    (unless (plist-get properties required)
      (error "lispm-prebuilt-define of %s lacks %s" name required)))
  (unless (or (plist-get properties :file) (plist-get properties :files))
    (error "lispm-prebuilt-define of %s lacks :file or :files" name))
  (puthash name properties lispm-prebuilt--specs)
  name)

(defun lispm-prebuilt--spec (name property)
  "Return PROPERTY of what NAME ships; one given as a function, the value
it returns now."
  (let* ((spec (or (gethash name lispm-prebuilt--specs)
                   (error "No prebuilt %s is defined" name)))
         (value (plist-get spec property)))
    (if (and (functionp value) (not (symbolp value)))
        (funcall value)
      value)))

(defun lispm-prebuilt--title (name)
  (lispm-prebuilt--spec name :title))

(defun lispm-prebuilt--noun (name)
  (or (lispm-prebuilt--spec name :noun) "module"))

(defun lispm-prebuilt--source (name)
  "Return where NAME comes from, `download' or `build'."
  (symbol-value (lispm-prebuilt--spec name :source)))

(defun lispm-prebuilt--url (name)
  "Return where NAME's releases are, without a slash at the end."
  (string-trim-right (symbol-value (lispm-prebuilt--spec name :url)) "/+"))

(defun lispm-prebuilt--directory-p (name)
  "Return non-nil when NAME's asset unpacks into a directory."
  (string-suffix-p ".tar.gz" (lispm-prebuilt--spec name :asset)))

(defun lispm-prebuilt--expand (template &optional target version)
  "Return TEMPLATE with %t TARGET, %e its suffix and %v VERSION."
  (format-spec template `((?t . ,(or target ""))
                          (?e . ,(if target (lispm-prebuilt-suffix target) ""))
                          (?v . ,(or version "")))))

;;;; Sources and their version

(defun lispm-prebuilt-source-files (name)
  "Return NAME's sources there are, sorted."
  (let ((root (lispm-prebuilt--spec name :root)))
    (sort (seq-filter
           #'file-regular-p
           (mapcan (lambda (entry)
                     (pcase entry
                       ((pred stringp) (list (expand-file-name entry root)))
                       (`(,directory ,regexp . ,flat)
                        (let ((directory (expand-file-name directory root)))
                          (and (file-directory-p directory)
                               (if (car flat)
                                   (directory-files directory t regexp)
                                 (directory-files-recursively directory regexp)))))))
                   (lispm-prebuilt--spec name :sources)))
          #'string<)))

(defun lispm-prebuilt-sha256 (file)
  "Return the SHA-256 of FILE's bytes, in hex."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun lispm-prebuilt-source-digest (name)
  "Return the SHA-256 of NAME's sources, in hex, or nil without them.
It is that of what sha256sum writes for them in their :root: for each,
in order, a line of its SHA-256, two spaces and its name."
  (when-let* ((files (lispm-prebuilt-source-files name)))
    (let ((root (lispm-prebuilt--spec name :root)))
      (secure-hash 'sha256
                   (mapconcat (lambda (file)
                                (format "%s  %s\n" (lispm-prebuilt-sha256 file)
                                        (file-relative-name file root)))
                              files "")))))

(defun lispm-prebuilt-source-version (name)
  "Return the version of NAME's sources, or nil without them: the first 16
digits of `lispm-prebuilt-source-digest'.  What is downloaded for them
is published, pinned and kept under it."
  (when-let* ((digest (lispm-prebuilt-source-digest name)))
    (substring digest 0 16)))

;;;; Pinned checksums

(defun lispm-prebuilt-pins (name)
  "Return what NAME's :sums file pins: a plist whose :version is the
version of the sources pinned, and whose :key, :modules by default, is
an alist of a SHA-256 for each target; nil when nothing is pinned."
  (let ((file (lispm-prebuilt--spec name :sums)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((pins (ignore-errors (read (current-buffer)))))
          (and (listp pins) pins))))))

(defun lispm-prebuilt-pinned-sha256 (name &optional target)
  "Return the SHA-256 pinned for NAME of these sources for TARGET, by
default this computer's, or nil when none is pinned for them."
  (when-let* ((target (or target (lispm-prebuilt-target name)))
              (version (lispm-prebuilt-source-version name))
              (pins (lispm-prebuilt-pins name))
              ((equal (plist-get pins :version) version))
              (sha256 (cdr (assoc target (plist-get pins (or (lispm-prebuilt--spec name :key) :modules))))))
    (and (stringp sha256) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256) sha256)))

;;;; Targets and files

(defun lispm-prebuilt-target (name &optional configuration)
  "Return the target NAME is published for on a computer Emacs was built
for as CONFIGURATION, by default this one's `system-configuration', or
nil when it is published for none there."
  (let ((configuration (or configuration system-configuration))
        (targets (lispm-prebuilt--spec name :targets)))
    (car (seq-find (lambda (known)
                     (and (member (car known) targets)
                          (string-match-p (cdr known) configuration)))
                   lispm-prebuilt-target-configurations))))

(defun lispm-prebuilt-suffix (target)
  "Return the file name suffix of a library for TARGET."
  (if (string-suffix-p "-apple-darwin" target) ".dylib" ".so"))

(defun lispm-prebuilt-asset (name target)
  "Return the name of what NAME publishes for TARGET."
  (lispm-prebuilt--expand (lispm-prebuilt--spec name :asset) target))

(defun lispm-prebuilt--prebuilt-directory (name)
  "Return the directory NAME's downloads are kept in, by version."
  (or (lispm-prebuilt--spec name :prebuilt)
      (expand-file-name "prebuilt" (lispm-prebuilt--spec name :root))))

(defun lispm-prebuilt--main (name target)
  "Return the name of NAME's file for TARGET in what is kept of it."
  (if (lispm-prebuilt--directory-p name)
      (car (lispm-prebuilt--spec name :files))
    (lispm-prebuilt--expand (lispm-prebuilt--spec name :file) target)))

(defun lispm-prebuilt--kept-directory (name)
  "Return the directory NAME's download for these sources is kept in, or
nil without sources."
  (when-let* ((version (lispm-prebuilt-source-version name)))
    (expand-file-name version (lispm-prebuilt--prebuilt-directory name))))

(defun lispm-prebuilt-prebuilt-file (name)
  "Return where NAME downloaded for these sources is kept, there or not,
or nil when it is published for no target here or there are no sources
to name its version."
  (when-let* ((target (lispm-prebuilt-target name))
              (directory (lispm-prebuilt--kept-directory name)))
    (expand-file-name (lispm-prebuilt--main name target) directory)))

(defun lispm-prebuilt--complete-p (name file)
  "Return non-nil when FILE, NAME's, is there whole: readable, and for an
asset unpacked into a directory, runnable, its other :files beside it."
  (and file (file-readable-p file)
       (or (not (lispm-prebuilt--directory-p name))
           (and (file-executable-p file)
                (seq-every-p (lambda (other)
                               (file-readable-p (expand-file-name other (file-name-directory file))))
                             (cdr (lispm-prebuilt--spec name :files)))))))

(defun lispm-prebuilt-built-file (name)
  "Return what building NAME makes for this computer, there or not, or nil."
  (when-let* ((target (lispm-prebuilt-target name))
              (built (lispm-prebuilt--spec name :built)))
    (expand-file-name (lispm-prebuilt--expand built target) (lispm-prebuilt--spec name :root))))

(defun lispm-prebuilt--stale-p (name)
  "Return non-nil when a source of NAME is newer than what was built."
  (let ((built (lispm-prebuilt-built-file name)))
    (and built (file-exists-p built)
         (seq-some (lambda (file) (file-newer-than-file-p file built))
                   (lispm-prebuilt-source-files name)))))

(defun lispm-prebuilt-file (name)
  "Return NAME's file current for the sources, or nil: when building,
what was built unless a source is newer; else what was downloaded and
checked for them."
  (let ((file (if (eq (lispm-prebuilt--source name) 'build)
                  (and (not (lispm-prebuilt--stale-p name)) (lispm-prebuilt-built-file name))
                (lispm-prebuilt-prebuilt-file name))))
    (and (lispm-prebuilt--complete-p name file) file)))

(defun lispm-prebuilt--build-needs (name)
  (or (lispm-prebuilt--spec name :build-needs) (car (lispm-prebuilt--spec name :build))))

(defun lispm-prebuilt--unpacker (name)
  (if (lispm-prebuilt--directory-p name) "tar" "gzip"))

(defun lispm-prebuilt-why-not (name)
  "Return why NAME cannot be had, a sentence."
  (let ((version (lispm-prebuilt-source-version name))
        (noun (lispm-prebuilt--noun name)))
    (cond ((not (lispm-prebuilt-target name))
           (format "no %s is published for %s" noun system-configuration))
          ((not version)
           (format "the %s's sources, which name the %s to download, are not there" noun noun))
          ((eq (lispm-prebuilt--source name) 'build)
           (if (executable-find (lispm-prebuilt--build-needs name))
               (format "building made no %s: see %s" noun (lispm-prebuilt--build-buffer name))
             (format "building the %s needs %s" noun (lispm-prebuilt--build-needs name))))
          ((not (lispm-prebuilt-pinned-sha256 name))
           (format "no %s is pinned for these sources (version %s); set `%s' to `build' to build one"
                   noun version (lispm-prebuilt--spec name :source)))
          ((not (executable-find "curl")) (format "downloading the %s needs curl" noun))
          ((not (executable-find (lispm-prebuilt--unpacker name)))
           (format "unpacking the %s needs %s" noun (lispm-prebuilt--unpacker name)))
          (t (format "no %s is there" noun)))))

;;;; Building, when asked to

(defun lispm-prebuilt--build-buffer (name)
  (format "*%s build*" name))

(defun lispm-prebuilt-build (name)
  "Build NAME with its :build command, Emacs waiting; return what it built,
or signal why there is none.  What the command says is in the buffer
*NAME build*."
  (let ((target (lispm-prebuilt-target name))
        (command (lispm-prebuilt--spec name :build)))
    (unless (and target command (executable-find (lispm-prebuilt--build-needs name))
                 (lispm-prebuilt-source-files name))
      (user-error "Building %s needs %s, its sources and a known computer"
                  (lispm-prebuilt--title name) (lispm-prebuilt--build-needs name)))
    (let ((default-directory (file-name-as-directory (lispm-prebuilt--spec name :root)))
          (buffer (get-buffer-create (lispm-prebuilt--build-buffer name)))
          (title (lispm-prebuilt--title name)))
      (with-current-buffer buffer (erase-buffer))
      (message "Building %s…" title)
      (unless (and (eql 0 (apply #'call-process (car command) nil buffer nil
                                 (mapcar (lambda (argument) (lispm-prebuilt--expand argument target))
                                         (cdr command))))
                   (lispm-prebuilt--complete-p name (lispm-prebuilt-built-file name)))
        (error "%s could not be built: see %s" title (buffer-name buffer)))
      (message "Building %s…done" title)
      (lispm-prebuilt-built-file name))))

;;;; Downloading, checked

(defun lispm-prebuilt--plan (name)
  "Return what downloading NAME takes, a plist of :url, :asset, :sha256,
:file and :directory, or a sentence saying why it cannot be."
  (let ((file (lispm-prebuilt-prebuilt-file name))
        (sha256 (lispm-prebuilt-pinned-sha256 name)))
    (if (not (and file sha256 (executable-find "curl")
                  (executable-find (lispm-prebuilt--unpacker name))))
        (lispm-prebuilt-why-not name)
      (let* ((target (lispm-prebuilt-target name))
             (asset (lispm-prebuilt-asset name target)))
        (list :url (format "%s/%s/%s" (lispm-prebuilt--url name)
                           (lispm-prebuilt--expand (lispm-prebuilt--spec name :release)
                                                   nil (lispm-prebuilt-source-version name))
                           asset)
              :asset asset :sha256 sha256 :file file
              :directory (directory-file-name (file-name-directory file)))))))

(defun lispm-prebuilt--checked (name plan archive)
  "Signal unless ARCHIVE, NAME's download as PLAN has it, is the one pinned."
  (unless (equal (lispm-prebuilt-sha256 archive) (plist-get plan :sha256))
    (error "%s is not the %s pinned for these sources: its SHA-256 differs, so it was refused"
           (plist-get plan :asset) (lispm-prebuilt--noun name))))

(defun lispm-prebuilt--unpack-command (name archive)
  "Return the command unpacking ARCHIVE, NAME's, in its own directory."
  (if (lispm-prebuilt--directory-p name)
      (list "tar" "-xzf" archive "-C" (expand-file-name "unpacked" (file-name-directory archive)))
    (list "gzip" "-d" "-f" archive)))

(defun lispm-prebuilt--install (name plan archive)
  "Keep what was unpacked from ARCHIVE, NAME's, as PLAN says, and remove
what was kept of other versions; return NAME's file.  It is renamed into
place, so it is there whole or not at all."
  (let* ((directory (plist-get plan :directory))
         (file (plist-get plan :file))
         (parent (file-name-directory directory)))
    (make-directory parent t)
    (if (lispm-prebuilt--directory-p name)
        (let ((unpacked (expand-file-name "unpacked" (file-name-directory archive))))
          (unless (lispm-prebuilt--complete-p
                   name (expand-file-name (car (lispm-prebuilt--spec name :files)) unpacked))
            (error "%s holds no %s" (plist-get plan :asset) (lispm-prebuilt--noun name)))
          (when (file-directory-p directory)
            (delete-directory directory t))
          (rename-file unpacked directory))
      (make-directory directory t)
      (copy-file (file-name-sans-extension archive) (concat file ".part") t)
      (rename-file (concat file ".part") file t))
    (dolist (old (directory-files parent t "\\`[^.]"))
      (when (and (file-directory-p old)
                 (not (string= (directory-file-name old) directory)))
        (delete-directory old t)))
    file))

(defun lispm-prebuilt-download (name)
  "Download NAME built for this computer from the sources there are, Emacs
waiting, check it against the SHA-256 pinned for it, and keep it; return
its file, or signal why there is none."
  (let ((plan (lispm-prebuilt--plan name))
        (title (lispm-prebuilt--title name)))
    (when (stringp plan)
      (user-error "%s cannot be downloaded: %s" title plan))
    (let* ((temporary (make-temp-file "lispm-prebuilt" t))
           (archive (expand-file-name (plist-get plan :asset) temporary)))
      (unwind-protect
          (progn
            (message "Downloading %s…" title)
            (unless (eql 0 (call-process "curl" nil nil nil "--fail" "--silent" "--show-error" "--location"
                                         "--retry" "2" "--max-time" (number-to-string lispm-prebuilt-timeout)
                                         "--output" archive (plist-get plan :url)))
              (error "Could not download %s" (plist-get plan :url)))
            (lispm-prebuilt--checked name plan archive)
            (when (lispm-prebuilt--directory-p name)
              (make-directory (expand-file-name "unpacked" temporary)))
            (let ((command (lispm-prebuilt--unpack-command name archive)))
              (unless (eql 0 (apply #'call-process (car command) nil nil nil (cdr command)))
                (error "%s could not be unpacked" (plist-get plan :asset))))
            (prog1 (lispm-prebuilt--install name plan archive)
              (message "Downloading %s…done" title)))
        (delete-directory temporary t)))))

;;;; Downloading in the background

(defun lispm-prebuilt-run (program args callback)
  "Run PROGRAM with ARGS in the background, then call CALLBACK with its exit
code, or a sentence saying why it did not run or exit, and what it said.
lispm-agent's `lispm-exec' runs it where it is there, else Emacs."
  (if (fboundp 'lispm-exec)
      (lispm-exec program args (lambda (exit output errors) (funcall callback exit (concat errors output))))
    (let ((buffer (generate-new-buffer " *lispm-prebuilt*" t)))
      (condition-case err
          (make-process
           :name program :buffer buffer :command (cons program args)
           :connection-type 'pipe :noquery t
           :sentinel (lambda (process _event)
                       (unless (process-live-p process)
                         (let ((said (with-current-buffer buffer (buffer-string))))
                           (kill-buffer buffer)
                           (funcall callback
                                    (if (eq (process-status process) 'exit)
                                        (process-exit-status process)
                                      (format "%s ended by signal %s" program (process-exit-status process)))
                                    said)))))
        (error (kill-buffer buffer)
               (run-at-time 0 nil callback (error-message-string err) ""))))))

(defun lispm-prebuilt-fetch (url file callback)
  "Download URL into FILE in the background, through
`lispm-prebuilt-fetch-function', at most `lispm-prebuilt-timeout'
seconds; then call CALLBACK with nil, or with why it failed, FILE
removed.  For what a package downloads beside its native code, as
lispm-doom's Freedoom."
  (funcall lispm-prebuilt-fetch-function url file callback :timeout lispm-prebuilt-timeout))

(cl-defun lispm-prebuilt-fetch-with-curl (url file callback &key (timeout lispm-prebuilt-timeout))
  "Download URL into FILE with curl, in the background, at most TIMEOUT
seconds; then call CALLBACK with nil, or with why it failed, FILE removed.
This is the default `lispm-prebuilt-fetch-function'."
  (let ((default-directory (file-name-directory file)))
    (lispm-prebuilt-run
     "curl" (list "--fail" "--silent" "--show-error" "--location" "--retry" "2"
                  "--max-time" (number-to-string timeout) "--output" file url)
     (lambda (exit said)
       (if (eql exit 0)
           (funcall callback nil)
         (ignore-errors (delete-file file))
         (funcall callback (format "Could not download %s: %s" url
                                   (if (stringp exit) exit (string-trim said)))))))))

(defun lispm-prebuilt--finish (name file why)
  "End NAME's download: call the callbacks waiting with FILE, or with WHY
it failed."
  (let ((waiting (gethash name lispm-prebuilt--waiting)))
    (remhash name lispm-prebuilt--waiting)
    (if why
        (message "%s could not be downloaded: %s" (lispm-prebuilt--title name) why)
      (message "Downloading %s…done" (lispm-prebuilt--title name)))
    (dolist (callback waiting)
      (with-demoted-errors "lispm-prebuilt: %S"
        (funcall callback file why)))))

(defun lispm-prebuilt--download-later (name)
  "Download NAME in the background, check it and keep it, then call the
callbacks waiting for it."
  (let ((plan (lispm-prebuilt--plan name)))
    (if (stringp plan)
        (lispm-prebuilt--finish name nil plan)
      (let* ((temporary (make-temp-file "lispm-prebuilt" t))
             (archive (expand-file-name (plist-get plan :asset) temporary)))
        (cl-flet ((done (file why)
                    (delete-directory temporary t)
                    (lispm-prebuilt--finish name file why)))
          (message "Downloading %s…" (lispm-prebuilt--title name))
          (funcall
           lispm-prebuilt-fetch-function (plist-get plan :url) archive
           (lambda (why)
             (if why
                 (done nil why)
               (condition-case err
                   (progn
                     (lispm-prebuilt--checked name plan archive)
                     (when (lispm-prebuilt--directory-p name)
                       (make-directory (expand-file-name "unpacked" temporary)))
                     (let ((command (lispm-prebuilt--unpack-command name archive))
                           (default-directory temporary))
                       (lispm-prebuilt-run
                        (car command) (cdr command)
                        (lambda (exit _said)
                          (if (not (eql exit 0))
                              (done nil (format "%s could not be unpacked" (plist-get plan :asset)))
                            (condition-case err
                                (done (lispm-prebuilt--install name plan archive) nil)
                              (error (done nil (error-message-string err)))))))))
                 (error (done nil (error-message-string err))))))
           :timeout lispm-prebuilt-timeout))))))

(defun lispm-prebuilt-get (name callback)
  "Get NAME's file, then call CALLBACK with it and nil, or with nil and a
sentence saying why there is none.  A file current for the sources is
given at once; when building, it is built, Emacs waiting, as building is
asked for; else it is downloaded, checked and kept in the background,
Emacs not waiting, through `lispm-prebuilt-fetch-function'.  Those who
ask meanwhile wait for the same download."
  (let ((file (lispm-prebuilt-file name)))
    (cond (file (funcall callback file nil))
          ((eq (lispm-prebuilt--source name) 'build)
           (pcase-let ((`(,built . ,why)
                        (condition-case err
                            (cons (lispm-prebuilt-build name) nil)
                          (error (cons nil (error-message-string err))))))
             (funcall callback built why)))
          ((gethash name lispm-prebuilt--waiting)
           (puthash name (append (gethash name lispm-prebuilt--waiting) (list callback))
                    lispm-prebuilt--waiting))
          (t (puthash name (list callback) lispm-prebuilt--waiting)
             (lispm-prebuilt--download-later name))))
  nil)

(defun lispm-prebuilt-getting-p (name)
  "Return non-nil while NAME is downloaded in the background."
  (and (gethash name lispm-prebuilt--waiting) t))

(defun lispm-prebuilt-prefetch (name)
  "Download NAME in the background when it is to be downloaded and is not
there, so that it is there once it is needed."
  (unless (or (eq (lispm-prebuilt--source name) 'build)
              (lispm-prebuilt-file name)
              (stringp (lispm-prebuilt--plan name)))
    (lispm-prebuilt-get name #'ignore)))

;;;; For code that cannot wait

(defun lispm-prebuilt-ensure (name)
  "Return NAME's file, getting it first when it is not there, Emacs
waiting: built when building, else downloaded and checked.  Signal why
when it cannot be had."
  (or (lispm-prebuilt-file name)
      (if (eq (lispm-prebuilt--source name) 'build)
          (lispm-prebuilt-build name)
        (lispm-prebuilt-download name))))

(defun lispm-prebuilt-load (name feature)
  "Load NAME, a module, unless FEATURE, which it provides, is there,
getting it first, Emacs waiting, when it is not there."
  (unless (featurep feature)
    (let ((file (lispm-prebuilt-ensure name)))
      (module-load file)
      (unless (featurep feature)
        (error "%s is not %s" file (lispm-prebuilt--title name))))))

;;;; In batch: a workflow's

(defun lispm-prebuilt--asset-regexp (name)
  "Return a regexp matching what NAME publishes, the target its group 1."
  (let ((case-fold-search nil))
    (replace-regexp-in-string
     "%e" "\\\\(?:\\\\.dylib\\\\|\\\\.so\\\\)"
     (replace-regexp-in-string "%t" "\\\\(.+?\\\\)" (regexp-quote (lispm-prebuilt--spec name :asset)) t)
     t)))

(defun lispm-prebuilt--fetch-now (url file)
  "Download URL into FILE with curl, Emacs waiting, or signal an error."
  (unless (eql 0 (call-process "curl" nil nil nil "--fail" "--silent" "--show-error" "--location"
                               "--retry" "2" "--max-time" (number-to-string lispm-prebuilt-timeout)
                               "--output" file url))
    (error "Could not download %s" url)))

(defun lispm-prebuilt-published (name url version)
  "Return the alist of target and SHA-256 of NAME's release of VERSION under
URL, each asset downloaded and found to be the one its SHA256SUMS lists,
and one there for every target NAME is published for.  Signal an error
otherwise."
  (let* ((tag (lispm-prebuilt--expand (lispm-prebuilt--spec name :release) nil version))
         (release (format "%s/%s/" (string-trim-right url "/+") tag))
         (directory (make-temp-file "lispm-prebuilt-pin" t))
         (sums (expand-file-name "SHA256SUMS" directory))
         (pattern (concat "\\`\\([0-9a-f]\\{64\\}\\) [ *]" (lispm-prebuilt--asset-regexp name) "\\'"))
         (published nil))
    (unwind-protect
        (progn
          (lispm-prebuilt--fetch-now (concat release "SHA256SUMS") sums)
          (dolist (line (split-string (with-temp-buffer (insert-file-contents sums) (buffer-string))
                                      "\n" t "[ \t\r]+"))
            (unless (string-match pattern line)
              (error "SHA256SUMS of %s lists %S, not a %s" tag line (lispm-prebuilt--noun name)))
            (let* ((sha256 (match-string 1 line))
                   (target (match-string 2 line))
                   (asset (lispm-prebuilt-asset name target))
                   (file (expand-file-name asset directory)))
              (lispm-prebuilt--fetch-now (concat release asset) file)
              (unless (equal (lispm-prebuilt-sha256 file) sha256)
                (error "%s is not the %s SHA256SUMS lists: refusing to pin it"
                       asset (lispm-prebuilt--noun name)))
              (push (cons target sha256) published)))
          (let ((missing (seq-remove (lambda (target) (assoc target published))
                                     (lispm-prebuilt--spec name :targets))))
            (when missing
              (error "%s has no %s for %s" tag (lispm-prebuilt--noun name) (string-join missing ", "))))
          (sort published (lambda (a b) (string< (car a) (car b)))))
      (delete-directory directory t))))

(defun lispm-prebuilt-render-pins (name version published)
  "Return the text of NAME's :sums file pinning PUBLISHED, of VERSION."
  (let ((file (file-name-nondirectory (lispm-prebuilt--spec name :sums)))
        (tag (lispm-prebuilt--expand (lispm-prebuilt--spec name :release) nil version))
        (noun (lispm-prebuilt--noun name)))
    (concat (format ";;; %s --- The %ss %s downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each %s of the release %s, as published: what
;; lispm-prebuilt downloads for these sources.  One whose SHA-256 is not
;; the one here is refused.  `lispm-prebuilt-batch-pin' writes it once
;; the workflow has published that release.

" file noun name noun (replace-regexp-in-string (regexp-quote version) "VERSION" tag t t))
            (format "(:version %S\n %s (%s))\n" version (or (lispm-prebuilt--spec name :key) :modules)
                    (mapconcat (lambda (entry) (format "(%S . %S)" (car entry) (cdr entry)))
                               published "\n           ")))))

(defun lispm-prebuilt-batch-pin (name)
  "Pin NAME's published assets of these sources, for Emacs in batch.
It writes NAME's :sums file from the release of their version under its
:url, each asset checked against the release's SHA256SUMS; run it once
the workflow has published the release, and commit the file with the
release of the package that ships it.  With NAME's :pin-check variable
set in the environment it writes nothing and exits with 1 when the file
pins these sources otherwise than the release has them; a file pinning
other sources passes, with a notice, as it does between a change of the
sources and the next release."
  (let* ((version (or (lispm-prebuilt-source-version name) (error "No sources here")))
         (pins (lispm-prebuilt-pins name))
         (file (lispm-prebuilt--spec name :sums))
         (key (or (lispm-prebuilt--spec name :key) :modules))
         (tag (lispm-prebuilt--expand (lispm-prebuilt--spec name :release) nil version))
         (url (lispm-prebuilt--url name))
         (check (lispm-prebuilt--spec name :pin-check)))
    (condition-case error
        (if (and check (getenv check))
            (cond ((not (equal (plist-get pins :version) version))
                   (message "::notice::%s pins %s, not the sources' %s: pin it once %s is published"
                            (file-name-nondirectory file)
                            (if (plist-get pins :version)
                                (lispm-prebuilt--expand (lispm-prebuilt--spec name :release)
                                                        nil (plist-get pins :version))
                              "nothing")
                            version tag))
                  ((equal (lispm-prebuilt-published name url version)
                          (sort (copy-sequence (plist-get pins key))
                                (lambda (a b) (string< (car a) (car b)))))
                   (message "%s pins %s as published" (file-name-nondirectory file) tag))
                  (t (error "%s differs from the release %s" (file-name-nondirectory file) tag)))
          (let ((published (lispm-prebuilt-published name url version)))
            (with-temp-file file
              (insert (lispm-prebuilt-render-pins name version published))))
          (message "%s pins %s" (file-name-nondirectory file) tag))
      (error (message "%s" (error-message-string error))
             (kill-emacs 1)))
    (kill-emacs 0)))

(provide 'lispm-prebuilt)
;;; lispm-prebuilt.el ends here
