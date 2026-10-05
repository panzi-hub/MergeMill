# Test Cases — skills/*/SKILL.md frontmatter contract (#27)

Each distributed skill relies on its `SKILL.md` YAML frontmatter being
parseable by skills.sh / Agent CLIs: `name` must match the skill's directory
basename and `description` must be non-empty. Before this change nothing in
`tests/unit/` parsed frontmatter, so a malformed field was only discovered at
install time.

This change adds a deterministic, network-free, read-only unit test that
enumerates every `skills/*/` directory and validates its `SKILL.md`, locking
the contract:

- frontmatter opens with `---` on line 1 and closes with a later standalone `---`;
- `name:` exists, is non-empty, and equals the skill directory basename;
- `description:` exists and is non-empty (inline scalar OR a YAML block scalar
  `>` / `|` with at least one non-blank body line before the block ends at the
  next dedented line).

Test runner: `bash tests/unit/test-skills-frontmatter.sh`
(auto-discovered by `tests/run-unit-tests.sh` via the `tests/unit/test-*.sh`
glob; not added to `SERIAL_TESTS` — it only reads the tree and writes to a
`mktemp -d` namespace, so it is concurrency-safe).

## E2E

N/A — this change adds a static assertion test only; there is no user
interface or user flow to exercise end-to-end.

## Positive scenarios (real `skills/` tree)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-SKILLFM-001 | the registered skill directories back the shipped set (`MergeMill-common`, `MergeMill-dev`, `MergeMill-dispatcher`, `MergeMill-review`, `create-issue`) — an anti-vacuity guard so a mass deletion can't let enumeration pass on an empty set (list to be extended when a skill is added) | all present |
| TC-SKILLFM-002 | every discovered `skills/*/SKILL.md` opens with `---` and has a closing `---` | PASS per skill |
| TC-SKILLFM-003 | every discovered `skills/*/SKILL.md` has a non-empty `name:` equal to its directory basename | PASS per skill |
| TC-SKILLFM-004 | every discovered `skills/*/SKILL.md` has a non-empty `description:` | PASS per skill |
| TC-SKILLFM-005 | overall exit code is 0 when every per-skill assertion passed (derived from the `FAIL` counter, not a separate directory-level assertion) | exit 0 |

## Negative scenarios (mktemp-scoped fixtures)

Fixtures are written under a fresh `mktemp -d`; the real `skills/` tree is
never modified (isolation contract in `tests/unit/README.md`). Each fixture is
run through the same validator used for the positive phase and must return
non-zero, with the expected failing assertion named in its output.

| ID | Fixture | Expected |
|----|---------|----------|
| TC-SKILLFM-101 | `SKILL.md` with no `---` frontmatter at all | validator rc != 0, fails the delimiter assertion |
| TC-SKILLFM-102 | frontmatter `name:` set to a value != directory basename | validator rc != 0, fails the name assertion |
| TC-SKILLFM-103 | frontmatter `description:` with an empty inline value | validator rc != 0, fails the description assertion |
| TC-SKILLFM-104 | frontmatter `description: >` block indicator with a blank body | validator rc != 0, fails the description assertion |
| TC-SKILLFM-105 | `description: >` with an empty body immediately followed by an indented sibling key (mirrors the `hooks:` layout in `skills/MergeMill-review/SKILL.md`) | validator rc != 0, fails the description assertion |
| TC-SKILLFM-106 | a skill directory containing no `SKILL.md` at all | validator rc != 0, fails the `SKILL.md exists` assertion |

TC-SKILLFM-104 and TC-SKILLFM-105 together guard the block-scalar path the
real tree exercises. Every shipped skill uses a `>` folded scalar, so a
simplistic parser that accepts a bare `>` indicator as "non-empty" accepts the
real tree *and* the TC-SKILLFM-104 fixture while still rejecting the
TC-SKILLFM-103 inline-empty fixture — only TC-SKILLFM-104 discriminates that
parser. TC-SKILLFM-105 additionally pins the block-scalar *boundary*: a parser
that keeps scanning past a dedented `hooks:` line and counts its indented
children as description body wrongly accepts an empty description (verified:
the pre-fix parser returned rc 0 on this fixture; the fix returns rc 1).

## Test cases document checklist

- [x] Scenarios for existing skills passing (TC-SKILLFM-001..005)
- [x] Missing-frontmatter fixture fails (TC-SKILLFM-101)
- [x] Name/directory mismatch fixture fails (TC-SKILLFM-102)
- [x] Empty-description fixtures fail (TC-SKILLFM-103, TC-SKILLFM-104, TC-SKILLFM-105)
- [x] Missing-`SKILL.md` fixture fails (TC-SKILLFM-106)
