;;; lispm-prebuilt-test.el --- Tests of lispm-prebuilt -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-prebuilt
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

;; A package of a test's own, in a temporary directory, publishes its
;; releases there too, read through file: URLs: nothing reaches the
;; network.  curl, gzip and tar do what they do.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lispm-prebuilt)

(defvar lispm-prebuilt-test-url nil)
(defvar lispm-prebuilt-test-source 'download)

(defun lispm-prebuilt-test--write (file text)
  "Write TEXT to FILE, making its directory."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region text nil file nil 'silent))
  file)

(defun lispm-prebuilt-test--run (program &rest args)
  (should (eql 0 (apply #'call-process program nil nil nil args))))

(defmacro lispm-prebuilt-test--with (spec &rest body)
  "Run BODY with a package of its own, in ROOT, a new directory: sources,
releases under file://ROOT/releases, and NAME defined.  SPEC is (NAME
ROOT &rest PROPERTIES), PROPERTIES replacing the package's own."
  (declare (indent 1))
  (pcase-let ((`(,name ,root . ,properties) spec))
    `(let* ((,root (file-name-as-directory (make-temp-file "lispm-prebuilt-test" t)))
            (lispm-prebuilt-test-url (concat "file://" ,root "releases"))
            (lispm-prebuilt-test-source 'download)
            (lispm-prebuilt--waiting (make-hash-table :test #'eq))
            (lispm-prebuilt--specs (make-hash-table :test #'eq))
            (,name 'lispm-prebuilt-test-module))
       (unwind-protect
           (progn
             (lispm-prebuilt-test--write (expand-file-name "native/Cargo.toml" ,root) "[package]\n")
             (lispm-prebuilt-test--write (expand-file-name "native/src/lib.rs" ,root) "// λ\n")
             (lispm-prebuilt-test--write (expand-file-name "native/src/deep/more.rs" ,root) "// more\n")
             (lispm-prebuilt-test--write (expand-file-name "native/src/notes.txt" ,root) "not a source\n")
             (apply #'lispm-prebuilt-define ,name
                    (append (list ,@properties)
                            (list :title "the test's module"
                                  :root (expand-file-name "native" ,root)
                                  :sources '("Cargo.toml" "Cargo.lock" ("src" "\\.rs\\'"))
                                  :targets '("aarch64-apple-darwin" "x86_64-apple-darwin"
                                             "x86_64-unknown-linux-gnu")
                                  :url 'lispm-prebuilt-test-url :source 'lispm-prebuilt-test-source
                                  :release "module-%v"
                                  :asset "test-module-%t%e.gz" :file "test-module-%t%e"
                                  :sums (expand-file-name "lisp/test-module-sums.eld" ,root)
                                  :pin-check "LISPM_PREBUILT_TEST_PIN_CHECK"
                                  :build '("sh" "-c" "mkdir -p target/%t && printf built > target/%t/libtest%e")
                                  :built "target/%t/libtest%e")))
             ,@body)
         (delete-directory ,root t)))))

(defun lispm-prebuilt-test--publish (name root contents &optional sums)
  "Publish CONTENTS as NAME's asset for this computer, in ROOT's releases
for the sources' version; pin it unless SUMS is `none', or pin SUMS.
Return the asset's file."
  (let* ((version (lispm-prebuilt-source-version name))
         (target (lispm-prebuilt-target name))
         (release (expand-file-name (format "releases/module-%s/" version) root))
         (asset (expand-file-name (lispm-prebuilt-asset name target) release)))
    (make-directory release t)
    (if (lispm-prebuilt--directory-p name)
        (let ((staging (make-temp-file "lispm-prebuilt-staging" t)))
          (pcase-dolist (`(,file . ,text) contents)
            (lispm-prebuilt-test--write (expand-file-name file staging) text)
            (set-file-modes (expand-file-name file staging) #o755))
          (lispm-prebuilt-test--run "tar" "-czf" asset "-C" staging ".")
          (delete-directory staging t))
      (lispm-prebuilt-test--write (file-name-sans-extension asset) contents)
      (lispm-prebuilt-test--run "gzip" "-f" (file-name-sans-extension asset)))
    (lispm-prebuilt-test--write
     (expand-file-name "SHA256SUMS" release)
     (format "%s  %s\n" (lispm-prebuilt-sha256 asset) (file-name-nondirectory asset)))
    (unless (eq sums 'none)
      (lispm-prebuilt-test--write
       (lispm-prebuilt--spec name :sums)
       (format "%S" `(:version ,version
                               ,(or (lispm-prebuilt--spec name :key) :modules)
                               ((,target . ,(or sums (lispm-prebuilt-sha256 asset))))))))
    asset))

(defun lispm-prebuilt-test--get (name)
  "Get NAME with `lispm-prebuilt-get'; return what the callback got."
  (let ((heard 'pending))
    (lispm-prebuilt-get name (lambda (file why) (setq heard (list file why))))
    (with-timeout (20 (error "lispm-prebuilt-get never called back"))
      (while (eq heard 'pending)
        (accept-process-output nil 0.02)))
    heard))

(ert-deftest lispm-prebuilt-names-its-sources ()
  (lispm-prebuilt-test--with (name root)
    (let ((native (expand-file-name "native/" root)))
      (should (equal (mapcar (lambda (file) (file-relative-name file native))
                             (lispm-prebuilt-source-files name))
                     '("Cargo.toml" "src/deep/more.rs" "src/lib.rs")))
      ;; As sha256sum writes them in native/, hashed.
      (should (equal (lispm-prebuilt-source-digest name)
                     (secure-hash 'sha256
                                  (mapconcat (lambda (file)
                                               (format "%s  %s\n" (lispm-prebuilt-sha256 (expand-file-name file native))
                                                       file))
                                             '("Cargo.toml" "src/deep/more.rs" "src/lib.rs") ""))))
      (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" (lispm-prebuilt-source-version name)))
      ;; A flat entry leaves out what is below.
      (lispm-prebuilt-define 'lispm-prebuilt-test-flat :title "t" :root native :sources '(("src" "\\.rs\\'" flat))
                             :targets '("x86_64-apple-darwin") :url 'lispm-prebuilt-test-url :source 'lispm-prebuilt-test-source
                             :release "x" :asset "x.gz" :file "x" :sums "x")
      (should (equal (mapcar (lambda (file) (file-relative-name file native))
                             (lispm-prebuilt-source-files 'lispm-prebuilt-test-flat))
                     '("src/lib.rs")))
      ;; A change of a source is another version.
      (let ((before (lispm-prebuilt-source-version name)))
        (lispm-prebuilt-test--write (expand-file-name "src/lib.rs" native) "// changed\n")
        (should-not (equal before (lispm-prebuilt-source-version name)))))))

(ert-deftest lispm-prebuilt-values-may-be-functions ()
  (lispm-prebuilt-test--with (name root)
    (let ((targets '("x86_64-apple-darwin")))
      (lispm-prebuilt-define 'lispm-prebuilt-test-late :title "t" :root (expand-file-name "native" root)
                             :sources '("Cargo.toml") :targets (lambda () targets)
                             :url 'lispm-prebuilt-test-url :source 'lispm-prebuilt-test-source
                             :release "x" :asset "x-%t.gz" :file "x" :sums "x")
      (should (equal (lispm-prebuilt-target 'lispm-prebuilt-test-late "x86_64-apple-darwin25") "x86_64-apple-darwin"))
      (setq targets '("aarch64-apple-darwin"))
      (should-not (lispm-prebuilt-target 'lispm-prebuilt-test-late "x86_64-apple-darwin25")))
    (should (eq (lispm-prebuilt--spec name :source) 'lispm-prebuilt-test-source))))

(ert-deftest lispm-prebuilt-targets-and-assets ()
  (lispm-prebuilt-test--with (name root)
    (should (file-directory-p root))
    (should (equal (lispm-prebuilt-target name "aarch64-apple-darwin25.0.0") "aarch64-apple-darwin"))
    (should (equal (lispm-prebuilt-target name "arm64-apple-darwin27.0.0") "aarch64-apple-darwin"))
    (should (equal (lispm-prebuilt-target name "x86_64-pc-linux-gnu") "x86_64-unknown-linux-gnu"))
    ;; Known, but not published for this package.
    (should-not (lispm-prebuilt-target name "aarch64-unknown-linux-gnu"))
    (should-not (lispm-prebuilt-target name "aarch64-unknown-openbsd"))
    (should (equal (lispm-prebuilt-asset name "x86_64-unknown-linux-gnu") "test-module-x86_64-unknown-linux-gnu.so.gz"))
    (should (equal (lispm-prebuilt-asset name "aarch64-apple-darwin") "test-module-aarch64-apple-darwin.dylib.gz"))
    (should (string-match (concat "\\`" (lispm-prebuilt--asset-regexp name) "\\'")
                          "test-module-x86_64-apple-darwin.dylib.gz"))
    (should (equal (match-string 1 "test-module-x86_64-apple-darwin.dylib.gz") "x86_64-apple-darwin"))))

(ert-deftest lispm-prebuilt-keeps-only-what-is-pinned ()
  (lispm-prebuilt-test--with (name root)
    (skip-unless (lispm-prebuilt-target name))
    (should-not (lispm-prebuilt-pinned-sha256 name))
    (should (string-match-p "no module is pinned" (lispm-prebuilt-why-not name)))
    (lispm-prebuilt-test--publish name root "the module")
    (should (lispm-prebuilt-pinned-sha256 name))
    ;; Pins of other sources pin nothing for these.
    (lispm-prebuilt-test--write (lispm-prebuilt--spec name :sums)
                                (format "%S" `(:version "0000000000000000"
                                                        :modules ((,(lispm-prebuilt-target name) . ,(make-string 64 ?a))))))
    (should-not (lispm-prebuilt-pinned-sha256 name))
    ;; Nor does what is no SHA-256.
    (lispm-prebuilt-test--write (lispm-prebuilt--spec name :sums)
                                (format "%S" `(:version ,(lispm-prebuilt-source-version name)
                                                        :modules ((,(lispm-prebuilt-target name) . "x")))))
    (should-not (lispm-prebuilt-pinned-sha256 name))))

(ert-deftest lispm-prebuilt-downloads-in-the-background ()
  (lispm-prebuilt-test--with (name root)
    (skip-unless (and (lispm-prebuilt-target name) (executable-find "curl") (executable-find "gzip")))
    (lispm-prebuilt-test--publish name root "the module")
    ;; What another version kept goes.
    (lispm-prebuilt-test--write (expand-file-name "native/prebuilt/0000000000000000/old" root) "old")
    (let* ((fetched nil)
           (lispm-prebuilt-fetch-function
           (let ((curl lispm-prebuilt-fetch-function))
             (lambda (url file callback &rest keys)
               (push url fetched)
               (apply curl url file callback keys)))))
      (should-not (lispm-prebuilt-file name))
      ;; Two ask; one download.
      (let ((first 'pending))
        (lispm-prebuilt-get name (lambda (file why) (setq first (list file why))))
        (should (lispm-prebuilt-getting-p name))
        (should (eq first 'pending))
        (let ((second (lispm-prebuilt-test--get name)))
          (with-timeout (10 (error "The first never heard"))
            (while (eq first 'pending) (accept-process-output nil 0.02)))
          (should (equal first second))))
      (should (= (length fetched) 1))
      (should (string-suffix-p (format "module-%s/%s" (lispm-prebuilt-source-version name)
                                       (lispm-prebuilt-asset name (lispm-prebuilt-target name)))
                               (car fetched)))
      (let ((file (lispm-prebuilt-file name)))
        (should (equal file (lispm-prebuilt-prebuilt-file name)))
        (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "the module"))
        (should-not (file-exists-p (expand-file-name "native/prebuilt/0000000000000000" root)))
        ;; There now: given at once, nothing fetched.
        (let ((heard nil))
          (lispm-prebuilt-get name (lambda (got why) (setq heard (list got why))))
          (should (equal heard (list file nil))))
        (should (= (length fetched) 1))))))

(ert-deftest lispm-prebuilt-refuses-what-is-not-pinned ()
  (lispm-prebuilt-test--with (name root)
    (skip-unless (and (lispm-prebuilt-target name) (executable-find "curl") (executable-find "gzip")))
    (lispm-prebuilt-test--publish name root "changed on the release" (make-string 64 ?b))
    (pcase-let ((`(,file ,why) (lispm-prebuilt-test--get name)))
      (should-not file)
      (should (string-match-p "SHA-256 differs" why)))
    (should-not (lispm-prebuilt-file name))
    (should-error (lispm-prebuilt-download name))
    ;; Nothing published there.
    (delete-directory (expand-file-name "releases" root) t)
    (pcase-let ((`(,file ,why) (lispm-prebuilt-test--get name)))
      (should-not file)
      (should (string-match-p "Could not download" why)))))

(ert-deftest lispm-prebuilt-downloads-waiting ()
  (lispm-prebuilt-test--with (name root)
    (skip-unless (and (lispm-prebuilt-target name) (executable-find "curl") (executable-find "gzip")))
    (lispm-prebuilt-test--publish name root "the module")
    (let ((lispm-prebuilt-fetch-function (lambda (&rest _) (error "Fetched in the background"))))
      (should (equal (lispm-prebuilt-ensure name) (lispm-prebuilt-prebuilt-file name)))
      (should (equal (lispm-prebuilt-ensure name) (lispm-prebuilt-prebuilt-file name))))))

(ert-deftest lispm-prebuilt-fetches-and-runs-for-a-package ()
  (lispm-prebuilt-test--with (name root)
    (skip-unless (and name (executable-find "curl")))
    (let ((source (lispm-prebuilt-test--write (expand-file-name "data.zip" root) "data"))
          (target (expand-file-name "fetched" root))
          (heard 'pending))
      (lispm-prebuilt-fetch (concat "file://" source) target (lambda (why) (setq heard why)))
      (with-timeout (10 (error "Never fetched"))
        (while (eq heard 'pending) (accept-process-output nil 0.02)))
      (should-not heard)
      (should (equal (with-temp-buffer (insert-file-contents target) (buffer-string)) "data"))
      (setq heard 'pending)
      (lispm-prebuilt-fetch (concat "file://" root "nowhere") target (lambda (why) (setq heard why)))
      (with-timeout (10 (error "Never failed"))
        (while (eq heard 'pending) (accept-process-output nil 0.02)))
      (should (string-match-p "Could not download" heard))
      (should-not (file-exists-p target))
      (setq heard 'pending)
      (let ((default-directory root))
        (lispm-prebuilt-run "sh" '("-c" "pwd -P; exit 3") (lambda (exit said) (setq heard (list exit said)))))
      (with-timeout (10 (error "Never ran"))
        (while (eq heard 'pending) (accept-process-output nil 0.02)))
      (should (equal heard (list 3 (concat (file-truename (directory-file-name root)) "\n")))))))

(ert-deftest lispm-prebuilt-unpacks-directories ()
  (lispm-prebuilt-test--with (name root
                              :asset "test-engine-%t.tar.gz" :files '("engine" "data.wad")
                              :noun "engine" :key :engines
                              :prebuilt (expand-file-name "engine/prebuilt" root))
    (skip-unless (and (lispm-prebuilt-target name) (executable-find "curl") (executable-find "tar")))
    (lispm-prebuilt-test--publish name root '(("engine" . "#!/bin/sh\n") ("data.wad" . "data")))
    (pcase-let ((`(,file ,why) (lispm-prebuilt-test--get name)))
      (should-not why)
      (should (equal file (expand-file-name (format "engine/prebuilt/%s/engine" (lispm-prebuilt-source-version name))
                                            root)))
      (should (file-executable-p file))
      (should (file-readable-p (expand-file-name "data.wad" (file-name-directory file)))))
    ;; An archive without the engine's data is none.
    (delete-directory (expand-file-name "engine/prebuilt" root) t)
    (lispm-prebuilt-test--publish name root '(("engine" . "#!/bin/sh\n")))
    (pcase-let ((`(,file ,why) (lispm-prebuilt-test--get name)))
      (should-not file)
      (should (string-match-p "holds no engine" why)))))

(ert-deftest lispm-prebuilt-builds-when-asked ()
  (lispm-prebuilt-test--with (name root)
    (skip-unless (lispm-prebuilt-target name))
    (let ((lispm-prebuilt-test-source 'build)
          (lispm-prebuilt-fetch-function (lambda (&rest _) (error "Fetched when building"))))
      (should-not (lispm-prebuilt-file name))
      (pcase-let ((`(,file ,why) (lispm-prebuilt-test--get name)))
        (should-not why)
        (should (equal file (lispm-prebuilt-built-file name)))
        (should (equal (lispm-prebuilt-file name) file)))
      ;; A source newer than what was built is built again.
      (set-file-times (lispm-prebuilt-built-file name) (time-subtract nil 100))
      (should-not (lispm-prebuilt-file name))
      (should (equal (lispm-prebuilt-ensure name) (lispm-prebuilt-built-file name)))
      (should (lispm-prebuilt-file name)))
    (should (string-match-p "lispm-prebuilt-test-source" (lispm-prebuilt-why-not name)))))

(ert-deftest lispm-prebuilt-pins-a-release ()
  (lispm-prebuilt-test--with (name root)
    (skip-unless (and (lispm-prebuilt-target name) (executable-find "curl") (executable-find "gzip")))
    (let* ((asset (lispm-prebuilt-test--publish name root "the module" 'none))
           (version (lispm-prebuilt-source-version name))
           (target (lispm-prebuilt-target name)))
      ;; A release lacking a target is refused.
      (should-error (lispm-prebuilt-published name lispm-prebuilt-test-url version))
      (lispm-prebuilt-define name :title "the test's module" :root (expand-file-name "native" root)
                             :sources '("Cargo.toml" "Cargo.lock" ("src" "\\.rs\\'"))
                             :targets (list target) :url 'lispm-prebuilt-test-url
                             :source 'lispm-prebuilt-test-source :release "module-%v"
                             :asset "test-module-%t%e.gz" :file "test-module-%t%e"
                             :sums (expand-file-name "lisp/test-module-sums.eld" root))
      (let ((published (lispm-prebuilt-published name lispm-prebuilt-test-url version)))
        (should (equal published (list (cons target (lispm-prebuilt-sha256 asset)))))
        (lispm-prebuilt-test--write (lispm-prebuilt--spec name :sums)
                                    (lispm-prebuilt-render-pins name version published))
        (should (equal (lispm-prebuilt-pinned-sha256 name) (lispm-prebuilt-sha256 asset)))
        (with-temp-buffer
          (insert-file-contents (lispm-prebuilt--spec name :sums))
          (should (search-forward "release module-VERSION" nil t)))))))

(provide 'lispm-prebuilt-test)
;;; lispm-prebuilt-test.el ends here
