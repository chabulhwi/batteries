import Lean.Util.SearchPath
import Batteries.Tactic.Lint
import Batteries.Data.Array.Basic

open Lean Core Elab Command Batteries.Tactic.Lint
open System (FilePath)

/-- The list of `nolints` pulled from the `nolints.json` file -/
abbrev NoLints := Array (Name × Name)

/-- Read the given file path and deserialize it as JSON. -/
def readJsonFile (α) [FromJson α] (path : System.FilePath) : IO α := do
  let _ : MonadExceptOf String IO := ⟨throw ∘ IO.userError, fun x _ => x⟩
  liftExcept <| fromJson? <|← liftExcept <| Json.parse <|← IO.FS.readFile path

/-- Serialize the given value `a : α` to the file as JSON. -/
def writeJsonFile [ToJson α] (path : System.FilePath) (a : α) : IO Unit :=
  IO.FS.writeFile path <| toJson a |>.pretty.push '\n'

/--
Usage: `runLinter [--update] [Batteries.Data.Nat.Basic]`

Runs the linters on all declarations in the given module (or `Batteries` by default).
If `--update` is set, the `nolints` file is updated to remove any declarations that no longer need
to be nolinted.
-/
unsafe def main (args : List String) : IO Unit := do
  let (update, args) :=
    match args with
    | "--update" :: args => (true, args)
    | _ => (false, args)
  let some module :=
      match args with
      | [] => some `Batteries
      | [mod] => match mod.toName with
        | .anonymous => none
        | name => some name
      | _ => none
    | IO.eprintln "Usage: runLinter [--update] [Batteries.Data.Nat.Basic]" *> IO.Process.exit 1
  searchPathRef.set compile_time_search_path%
  let mFile ← findOLean module
  unless (← mFile.pathExists) do
    -- run `lake build module` (and ignore result) if the file hasn't been built yet
    let child ← IO.Process.spawn {
      cmd := (← IO.getEnv "LAKE").getD "lake"
      args := #["build", s!"+{module}"]
      stdin := .null
    }
    _ ← child.wait
  -- If the linter is being run on a target that doesn't import `Batteries.Tactic.List`,
  -- the linters are ineffective. So we import it here.
  let lintModule := `Batteries.Tactic.Lint
  let lintFile ← findOLean lintModule
  unless (← lintFile.pathExists) do
    -- run `lake build +Batteries.Tactic.Lint` (and ignore result) if the file hasn't been built yet
    let child ← IO.Process.spawn {
      cmd := (← IO.getEnv "LAKE").getD "lake"
      args := #["build", s!"+{lintModule}"]
      stdin := .null
    }
    _ ← child.wait
  let nolintsFile : FilePath := "scripts/nolints.json"
  let nolints ← if ← nolintsFile.pathExists then
    readJsonFile NoLints nolintsFile
  else
    pure #[]
  withImportModules #[module, lintModule] {} (trustLevel := 1024) fun env =>
    let ctx := { fileName := "", fileMap := default }
    let state := { env }
    Prod.fst <$> (CoreM.toIO · ctx state) do
      let decls ← getDeclsInPackage module.getRoot
      let linters ← getChecks (slow := true) (runAlways := none) (runOnly := none)
      let results ← lintCore decls linters
      if update then
        writeJsonFile (α := NoLints) nolintsFile <|
          .qsort (lt := fun (a, b) (c, d) => a.lt c || (a == c && b.lt d)) <|
          .flatten <| results.map fun (linter, decls) =>
          decls.fold (fun res decl _ => res.push (linter.name, decl)) #[]
      let results := results.map fun (linter, decls) =>
        .mk linter <| nolints.foldl (init := decls) fun decls (linter', decl') =>
          if linter.name == linter' then decls.erase decl' else decls
      let failed := results.any (!·.2.isEmpty)
      if failed then
        let fmtResults ←
          formatLinterResults results decls (groupByFilename := true) (useErrorFormat := true)
            s!"in {module}" (runSlowLinters := true) .medium linters.size
        IO.print (← fmtResults.toString)
        IO.Process.exit 1
      else
        IO.println "-- Linting passed."
