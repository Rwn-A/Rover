package main

import "core:os"

import "../compiler"

main :: proc() {
   if len(os.args) <= 1 do compiler.fatal("Not enough arguments: expected filepath")

   main_file := os.args[1]

   if ok := compiler.compile(main_file); !ok {
      os.exit(1)
   }
}