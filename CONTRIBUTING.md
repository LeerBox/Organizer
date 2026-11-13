# Contributing

Thanks for helping make Organizer better.

- **Keep it safe.** Changes that move, rename or delete files must come with a test in `Tests/Test-OrganizerEngine.ps1` and must never weaken a guard described in `docs/SAFETY.md`.
- **Keep the split.** Sorting rules and file operations live in `OrganizerEngine.psm1`; `Organizer.ps1` is user interface only.
- **Keep it portable.** Windows PowerShell 5.1, no external modules, no network calls.
- **Run the tests** before sending a pull request:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-OrganizerEngine.ps1
  ```

For bug reports, include your Windows version and remove personal paths from screenshots.
