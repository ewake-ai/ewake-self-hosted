#!/usr/bin/env bash
# Every name src/core/config.ts wraps in requireEnv() must be handed to every
# runtime that boots the image. config is imported by src/core/logger, so a
# missing one throws at import and the process exits before its handler runs —
# db-migrate first, since it gates every deploy.
#
# This has cost two outages: the base-URL split, and JWT_SECRET/ORCHESTRATOR_SECRET
# (back#3360, ported as ewake-self-hosted#19 only after a customer-shaped install
# failed mid-apply). Neither was visible in a plan: terraform cannot know what the
# image requires.
#
# Usage: check-required-env.sh <company_stack dir> [names file]
set -euo pipefail

MODULE="${1:?usage: $0 <company_stack dir> [names file]}"
NAMES_FILE="${2:-}"

# The four runtimes that boot the image. Each must deliver every required name,
# either in its own env/secrets list or via the shared base-env local it splices.
RUNTIMES="ecs_task.tf db_migrate.tf lambdas/reactive.tf lambdas/scheduled/locals.tf"

if [ -n "$NAMES_FILE" ]; then
  NAMES=$(grep -vE '^\s*(#|$)' "$NAMES_FILE")
elif [ -f src/core/config.ts ]; then
  NAMES=$(grep -oE "requireEnv\('[A-Z0-9_]+'\)" src/core/config.ts | sed "s/requireEnv('//;s/')//" | sort -u)
else
  echo "error: no names file given and src/core/config.ts not found" >&2
  exit 2
fi

[ -n "$NAMES" ] || { echo "error: no required env names found" >&2; exit 2; }

# Names carried by the shared base-env local, if this repo has one (back#3407).
# A runtime that splices it inherits them; one that does not must spell them out.
SHARED_BLOCK=$(awk '/core_base_env = \{/,/^  \}/' "$MODULE"/*.tf 2>/dev/null || true)
SHARED_NAMES=$(printf '%s' "$SHARED_BLOCK" | grep -oE '^\s+[A-Z0-9_]+' | tr -d ' ' || true)

fail=0
for name in $NAMES; do
  for rt in $RUNTIMES; do
    f="$MODULE/$rt"
    [ -f "$f" ] || { echo "MISSING FILE  $f"; fail=1; continue; }
    if grep -q "\b$name\b" "$f"; then continue; fi
    # Not spelled out — accept it only if this runtime splices the shared local
    # and the shared local carries it.
    if grep -q 'core_base_env' "$f" && printf '%s\n' "$SHARED_NAMES" | grep -qx "$name"; then continue; fi
    echo "FAIL  $name is not delivered to $rt"
    fail=1
  done
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "Every requireEnv() name must reach all four runtimes. Add it to the env or"
  echo "secrets list of the file named above, or to the shared base-env local."
  exit 1
fi

echo "OK  $(printf '%s\n' "$NAMES" | wc -l | tr -d ' ') required env names delivered to all four runtimes"
