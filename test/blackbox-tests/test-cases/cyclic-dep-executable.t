Reports module dependency cycles inside executables.

  $ cat > dune-project <<EOF
  > (lang dune 3.20)
  > EOF

  $ cat > dune <<EOF
  > (executable (name foo))
  > EOF

  $ cat > foo.ml <<EOF
  > open Bar
  > open Baz
  > EOF

  $ cat > bar.ml <<EOF
  > open Baz
  > EOF

  $ cat > baz.ml <<EOF
  > open Bar
  > EOF

  $ dune build
  Error: dependency cycle between modules in _build/default:
     Bar
  -> Baz
  -> Bar
  [1]

