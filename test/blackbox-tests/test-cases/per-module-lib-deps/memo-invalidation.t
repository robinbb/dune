Memo-based ocamldep must invalidate correctly when a module's source
changes the set of libraries it references.

The per-module filter (#4572) consults ocamldep to decide which
inter-library .cmi deps each module requires. When that ocamldep call
is memoised on the source file's content digest (rather than emitted
as a build rule producing .d / .all-deps), the memo cell must
re-evaluate whenever the source changes. This test exercises that
invariant by alternating a consumer between "uses LibB" and "doesn't
use LibB", then checking that downstream rebuilds respect the current
reference set.

  $ cat > dune-project <<EOF
  > (lang dune 3.0)
  > EOF

  $ mkdir libB
  $ cat > libB/dune <<EOF
  > (library
  >  (name libB))
  > EOF
  $ cat > libB/libB.ml <<EOF
  > let base_value = 1000
  > EOF
  $ cat > libB/libB.mli <<EOF
  > val base_value : int
  > EOF

  $ mkdir libA
  $ cat > libA/dune <<EOF
  > (library
  >  (name libA)
  >  (libraries libB))
  > EOF
  $ cat > libA/a_uses_b.ml <<EOF
  > let get_base () = LibB.base_value
  > EOF
  $ cat > libA/a_uses_b.mli <<EOF
  > val get_base : unit -> int
  > EOF
  $ cat > libA/a_toggle.ml <<EOF
  > let value () = 42
  > EOF
  $ cat > libA/a_toggle.mli <<EOF
  > val value : unit -> int
  > EOF

  $ cat > dune <<EOF
  > (executable
  >  (name main)
  >  (libraries libA))
  > EOF
  $ cat > main.ml <<EOF
  > let () =
  >   print_int (LibA.A_uses_b.get_base ());
  >   print_int (LibA.A_toggle.value ())
  > EOF

Initial build establishes baseline memo state.

  $ dune build ./main.exe

With a_toggle not referencing LibB, changing LibB's interface must not
force a_toggle to recompile.

  $ cat > libB/libB.mli <<EOF
  > val base_value : int
  > val extra : unit -> string
  > EOF
  $ cat > libB/libB.ml <<EOF
  > let base_value = 1000
  > let extra () = "hello"
  > EOF

  $ dune build ./main.exe
  $ dune trace cat | jq -s 'include "dune"; [.[] | targetsMatchingFilter(test("A_toggle"))] | length'
  0

Now edit a_toggle.ml to reference LibB. The memo cell for a_toggle's
ocamldep output must invalidate on the source change, so the filter
sees the new LibB reference and subsequent LibB changes propagate.

  $ cat > libA/a_toggle.ml <<EOF
  > let value () = LibB.base_value + 42
  > EOF

  $ dune clean
  $ dune build ./main.exe

Perturb LibB again to measure downstream impact in the new state.

  $ cat > libB/libB.mli <<EOF
  > val base_value : int
  > val extra : unit -> string
  > val more : int
  > EOF
  $ cat > libB/libB.ml <<EOF
  > let base_value = 1000
  > let extra () = "hello"
  > let more = 7
  > EOF

  $ dune build ./main.exe
  $ dune trace cat | jq -s 'include "dune"; [.[] | targetsMatchingFilter(test("A_toggle"))] | length' | awk '{print ($1 > 0 ? "recompiled" : "not-recompiled")}'
  recompiled

Revert a_toggle to be independent again. The memo must invalidate back,
so a subsequent LibB-only change stops propagating to a_toggle.

  $ cat > libA/a_toggle.ml <<EOF
  > let value () = 42
  > EOF

  $ dune clean
  $ dune build ./main.exe

  $ cat > libB/libB.mli <<EOF
  > val base_value : int
  > val extra : unit -> string
  > val more : int
  > val yet_more : string
  > EOF
  $ cat > libB/libB.ml <<EOF
  > let base_value = 1000
  > let extra () = "hello"
  > let more = 7
  > let yet_more = "y"
  > EOF

  $ dune build ./main.exe
  $ dune trace cat | jq -s 'include "dune"; [.[] | targetsMatchingFilter(test("A_toggle"))] | length'
  0

Null-build idempotency: with no source changes, rebuild must be a no-op.

  $ dune build ./main.exe
  $ dune trace cat | jq -s 'include "dune"; [.[] | targetsMatchingFilter(test("A_toggle"))] | length'
  0
