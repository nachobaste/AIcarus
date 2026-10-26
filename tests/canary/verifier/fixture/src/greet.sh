#!/bin/bash
# greeter used by the canary fixture
greet() {
  local name="$1"
  echo "hello $name"
}

greet "$@"
