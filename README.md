# Empty Folder Cleaner (Free Pascal / Lazarus)

Finds empty folders (including entire empty folder trees) and deletes them –
as a **native application without any runtime** for **Windows 7 to Windows 11**
(32 and 64 bit).

## About

| | |
|---|---|
| Version | **0.2.0** |
| Author | **mogeldev** |
| Website | <https://mogeldev.github.io/> |
| License | MIT (see [LICENSE](LICENSE)) |

In the app, "About…" shows the same details; the exe also carries them as
version info (file properties → Details). For a new release, update the
version in two places: `APP_VERSION` in `MainForm.pas` and the version info
in `EmptyFolderCleaner.lpi` (`MajorVersionNr`/`MinorVersionNr`/`RevisionNr`,
`ProductVersion`).

## Building

Requirements: Lazarus 3.x/4.x with FPC 3.2.2. Building for the other
architecture needs the Lazarus cross-compiler add-on
(e.g. `lazarus-…-cross-i386-win32-win64.exe` for the 64-bit installation).

| Build mode | Output | Use |
|---|---|---|
| `Debug` (default) | `EmptyFolderCleaner.exe` | Development (debug info, range/overflow checks) |
| `Release-Win32` | `bin\EmptyFolderCleaner-x86.exe` | 32-bit Windows (e.g. Windows 7 x86) |
| `Release-Win64` | `bin\EmptyFolderCleaner-x64.exe` | 64-bit Windows (recommended, see WOW64 below) |

**With the Lazarus IDE:** open `EmptyFolderCleaner.lpi`, choose the build mode,
press `Shift+F9` (Build).

**On the command line**

```powershell
lazbuild --build-mode=Release-Win32 EmptyFolderCleaner.lpi
lazbuild --build-mode=Release-Win64 EmptyFolderCleaner.lpi
```

Each release exe is a single file without debug info that can be copied to any
target machine.

## Files

| File | Purpose |
|---|---|
| `EmptyFolderCleaner.lpi` | Lazarus project file (build modes, manifest) |
| `EmptyFolderCleaner.lpr` | Program entry point |
| `MainForm.pas` | All logic (scan, delete, UI) |
| `MainForm.lfm` | Form layout (editable in the Lazarus designer) |

## Usage

1. Choose the **start folder** via "Browse…" (relative paths are converted to
   absolute ones).
2. **Scan** – the scan runs in a background thread; the UI stays responsive.
   The progress bar runs as a marquee.
3. Empty folders found appear checked in the list.
4. **Delete checked** – by default to the **Recycle Bin** ("Move to Recycle
   Bin" checkbox). Unchecked, folders are deleted permanently; the
   confirmation then defaults to "No". The progress bar shows the status,
   **Cancel** stops the deletion.
5. Double-clicking an entry opens the folder in Explorer.
6. **About…** shows version, author and website (clickable link).

## What counts as "empty"?

A folder is empty if it contains **no files** – not even in its subfolders.
A folder that only contains empty subfolders is therefore detected as well,
so entire empty trees disappear. Hidden files (e.g. `desktop.ini`,
`Thumbs.db`) count as files.

## Safety

- **Warning for system areas:** if the start folder is a drive root, or
  contains or lies within `%SystemRoot%`, the program folders,
  `%ProgramData%`, `%APPDATA%` or `%LOCALAPPDATA%`, the program asks before
  scanning. Windows or programs expect some empty folders there.
- Every folder is checked again right before deletion: only folders that are
  really empty are removed.
- Deletion always goes **deepest first** (children before their parents) –
  the scan already produces this order.
- **Links/junctions** are not followed (no endless loops) and never reported
  as empty.
- Unreadable folders are treated as **not empty** to be safe.
- If the scan stops because of an error, the status bar reports
  "Scan incomplete"; the entries found up to that point are valid.
- Errors are collected and shown with their cause at the end (the first 20)
  instead of aborting.
- **Recycle Bin on network/USB drives:** if a drive has no Recycle Bin,
  Windows deletes permanently without asking. Since only empty folders are
  affected, no data is lost.

## Windows 7 to 11

- **Manifest** (themes, `asInvoker`, DPI awareness "True") is embedded by
  Lazarus. Without it the marquee would not animate, and a 32-bit exe would be
  subject to UAC file virtualization (VirtualStore).
- **High DPI:** `Application.Scaled` plus manifest – sharp on Windows 10/11.
  Buttons size themselves to their captions.
- **WOW64:** on 64-bit Windows a 32-bit exe sees `SysWOW64` instead of
  `C:\Windows\System32`. Use the x64 exe on 64-bit systems.
- **Long paths (> 260 characters):** scanning and permanent deletion use the
  `\\?\` prefix and therefore work on Windows 7 too. The Recycle Bin
  (`SHFileOperationW`) does not support long paths; such folders are reported
  as errors.
- **Message boxes** are native Windows message boxes, so their buttons follow
  the Windows display language.

## Technical notes

- **Threading without UI access:** the scan thread never touches controls; it
  only fills its own `TStringList`. The form polls it with a `TTimer`
  (150 ms) and frees the thread only after `WaitFor`.
- **Deletion runs in the UI thread** with `Application.ProcessMessages` about
  every 100 ms; closing the window cancels the deletion first.
- **Recycle Bin:** via `SHFileOperationW` from `shell32.dll`. The structure is
  declared locally (`TSHFileOpStructW`). Note: `shellapi.h` uses byte packing
  on 32-bit and natural alignment on 64-bit – hence `{$PACKRECORDS 1}` or `C`.
- **No `Windows` unit:** it would hide `SysUtils.FindClose`.
- **The form variable is `FormMain`**, not `MainForm` – otherwise it would
  clash with the unit of the same name.
- **Deleting without the Recycle Bin:** `RemoveDir` from `SysUtils`.
- Only the `LCL` package is required (incl. `LazUtils`), no extra packages.

## Look

LCL draws with **native Win32 controls**. That looks classic and follows the
current Windows theme – but it is not a Fluent/Material design. A modern look
would need a skin library for Lazarus (e.g. BGRAControls or LCL styles); this
is deliberately left out so the project builds without extra packages.

## Test status

Compiled with **Lazarus 4.8 / FPC 3.2.2** (all three build modes without
errors or warnings) and tested on **Windows 11 (150 % scaling)** as 32- and
64-bit:

- The exe headers require at most Windows 7 (subsystem 4.0); no statically
  imported API is newer than Windows 7. The manifest is embedded.
- Automated test through the real form: scan (nested, Unicode, path > 260
  characters, hidden file, junction), system-area warning, permanent
  deletion, layout at default and minimum width – passed.
- **Read-only** empty folders: permanent deletion clears and, on failure,
  restores the read-only attribute – tested incl. path > 260 characters.
- Not tested: Recycle Bin mode and a real Windows 7 machine – check once on
  Windows 7 (x86) before distributing.
