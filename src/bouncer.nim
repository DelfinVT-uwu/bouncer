## bouncer — Zod-style schema validation for Nim.
##
## Build a schema as a value, then parse untrusted data (JSON, forms, config)
## against it. You get back either the validated data or a list of issues, each
## with the exact path where it failed.
##
## ```nim
## import bouncer, std/json
##
## let user = obj({
##   "name":  str().min(3).max(50),
##   "email": str().email(),
##   "age":   integer().min(18),
##   "tags":  arr(str()).optional()
## })
##
## let r = user.safeParse("""{"name":"Al","email":"nope","age":15}""")
## if not r.ok:
##   for issue in r.issues:
##     echo issue        # name: must be at least 3 characters
##                       # email: must be a valid email
##                       # age: must be >= 18
## ```

import bouncer/core
export core
