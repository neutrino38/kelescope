# Les tests du chargeur recompilent le meme module a chaque scenario.
Code.put_compiler_option(:ignore_module_conflict, true)

ExUnit.start()
