Synthetic archive fixtures; no third-party content.

Generated with Python's zipfile/tarfile modules, except encrypted.zip, which was
created with /usr/bin/zip -P test. Its password is "test" and its member is a
six-byte file named secret. Payloads in the other valid archives are "hello".

- tree.zip: implicit/deep/hello.txt, .hidden, space % # ü.txt, nested.zip,
  and explicit empty/. No explicit implicit/ or implicit/deep/ headers.
  nested.zip contains plain text: nested archive opening is disabled.
- tree.tar, tree.tar.gz, tree.tar.bz2, tree.tar.xz: implicit/deep/hello.txt and
  a symbolic link named link whose target is ../../outside. It must never be
  followed or extracted.
- unsafe.zip: member ../escape, payload x. It must be rejected by the index.
- empty.zip: empty ZIP directory.
- corrupt.zip: plain text "not an archive".
