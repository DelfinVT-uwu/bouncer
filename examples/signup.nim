## A realistic parse: a signup payload off the wire. Run it with:
##   nim c -r examples/signup.nim
##
## It shows the two things bouncer is for — rejecting bad input with clear,
## field-by-field errors, and handing back a cleaned-up value for good input.

import bouncer

let signup = obj({
  "name":     str().trim().min(2).max(50),
  "email":    str().email(),
  "age":      integer().coerce().min(18),      # arrives as text from a form
  "role":     str().oneOf(["admin", "user"]).default("user"),
  "referrer": str().optional()
})

echo "--- bad input ---"
let bad = signup.safeParse("""
  {"name":"A","email":"nope","age":"16"}""")
if not bad.ok:
  for issue in bad.issues:
    echo "  ", issue
# name: must be at least 2 characters
# email: must be a valid email
# age: must be >= 18

echo "--- good input (note the cleanup) ---"
let good = signup.safeParse("""
  {"name":"  Delfin  ","email":"d@x.com","age":"20","junk":"x"}""")
echo "  ", good.value
# {"name":"Delfin","email":"d@x.com","age":20,"role":"user"}
#   trimmed, coerced, defaulted, and "junk" dropped
