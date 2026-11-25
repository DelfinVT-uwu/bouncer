version     = "0.4.0"
author      = "DelfinVT"
description = "Zod-style schema validation and parsing for untrusted data in Nim"
license     = "MIT"
srcDir      = "src"

requires "nim >= 2.0.0"

task test, "run the test suite":
  exec "nim c -r --hints:off --path:src tests/test_bouncer.nim"
