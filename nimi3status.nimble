[Package]
name          = "nimi3status"
version       = "0.0.1"
author        = "Federico Ceratto"
description   = """Lightweight i3 status bar."""
license       = "GPLv3"

bin           = "nimi3status"

InstallFiles = """
LICENSE
example.conf.json
README.adoc
"""

[Deps]
Requires: """
nim >= 0.12.0
"""
