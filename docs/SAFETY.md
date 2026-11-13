# Safety and limitations

Organizer moves files. It never deletes a file, never overwrites one and never moves a folder. This page lists exactly what it refuses to do and where its checks end.

## Places Organizer never touches

These can neither be chosen as the folder to organize nor used as the destination of a category:

- `C:\Windows`, `C:\Program Files`, `C:\Program Files (x86)`, `C:\ProgramData` and everything inside them
- `AppData` in your user folder and everything inside it
- The root of any drive (`C:\`, `D:\`, ...)
- `$Recycle.Bin`, `System Volume Information` and `Recovery` on every drive
- The `Users` folder itself and the folders of other user accounts

In addition, these cannot be chosen as the folder to organize: your user folder itself, Organizer's own folder, and any folder that looks like a program or a code project (it contains `unins000.exe`, five or more `.dll` files, or `.git`, `.svn`, `.hg`, `.vs` or `node_modules`).

Destinations are checked when a category is saved, when the plan is made, and once more immediately before each file is moved.

## Files that are left alone

A loose file is skipped and listed on the Safety page with its reason when it is:

- hidden, a system file, or `desktop.ini`
- an unfinished download (`.crdownload`, `.part`, `.partial`, `.tmp`, `.download`, `.opdownload`, `.!ut`, `.!qb`, `.aria2`)
- a program component (`.dll`, `.sys`, `.ocx`, `.drv`, `.pak`)
- an `.exe` with companion files of the same name beside it, or any `.exe` when loose `.dll` files are in the same folder
- a settings or data file that belongs to such an `.exe`
- a link or junction
- an online-only cloud file that is not stored on this PC
- open in another program at the moment of the scan

## While moving

- If a file with the same name already exists in the destination, the moved file gets ` (2)`, ` (3)` and so on.
- Before moving files to another drive, the free space on that drive is checked. If it is not enough, nothing is moved.
- A file that cannot be moved stays where it is; the rest of the run continues and the result tells you how many failed.
- Each run is written to `%LOCALAPPDATA%\Organizer\History`. The 30 most recent runs are kept.

## Undo

Undo moves every file of a run back to its original path and deletes the folders that run created, if they are empty again.

- A file that was renamed, moved or deleted after the run cannot be restored and is reported as not found.
- If a new file now has the original name, the restored file gets a number instead of replacing it.

## Limitations

- The checks reduce risk; they cannot prove that moving a particular file is harmless. Another program may remember the old path of a file in Downloads.
- "Open in another program" is checked during the scan. A file opened between the scan and the move simply fails to move and stays in place.
- Content detection reads only the first bytes of a file and recognises a limited set of formats.
- Organizer has not had an independent security audit and the release is not code-signed.
