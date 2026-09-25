# Phase 3 — Commands and runtime inspection

Scope now routes its main operations through a small app-owned command model. The same command IDs are used by native menus, the command palette, keyboard handling, and in-app controls.

## Use it

- Open **File → Open Trace** or press **Ctrl/Cmd+O**.
- Open **View → Command Palette** or press **Ctrl/Cmd+Shift+P**. Type part of a command, move with the arrow keys, run with Enter, or close with Escape.
- In the palette, try **Fit Whole Trace**, **Fit Selection**, **Previous Event**, **Next Event**, **Show Overview**, or **Clear Event Selection**.
- Choose **View → Runtime Inspector**, or use the **Runtime** button in the Inspector pane, to inspect Alicorn's retained nodes, bounds, dirty state, interaction state, frame counters, recent runtime events, and Scope command dispatches. The snapshot refreshes when the application next builds; it does not poll while idle.

The palette is a centered, modal quick-input over the still-visible workspace. It takes focus when opened, confines pointer and keyboard traversal, closes on Escape or a click on the backdrop, and restores the previous focus when dismissed. Its implementation and command matching remain app-local; Alicorn provides the small retained modal-overlay primitive, native menu command-ID boundary, and runtime inspection/trace snapshot APIs, but not a generic command registry or palette widget.

Native menus are enabled on Windows and macOS. Windows opts into Alicorn's integrated caption-label mode while preserving the native caption buttons; macOS uses the standard system menu bar and title bar. On Linux, use the visible **Open Trace...** and **Commands...** controls; Ctrl+O and Ctrl+Shift+P remain available as keyboard shortcuts.

## Command behavior

Commands have stable `Scope_Command_ID` values. UI controls publish those IDs; a single Scope dispatcher performs the operation. Native menus keep stable item storage for the duration of the application and refresh their enabled/checked state from current Scope state.

Transient palette input, focus, query matching, and selected result remain presentation-local. The palette query does not cross Caliber. Closing the palette restores the prior focus. Escape cancels active text composition before it dismisses the palette.

Runtime activity is bounded to 64 entries, and the displayed inspection snapshot is capped at 24 KiB. Inspecting does not activate the selected node or cause periodic work.

Recent activity lists Scope command records alongside Alicorn's bounded trace events in observed order. It is a diagnostic history, not a timestamped causal trace; Alicorn's trace events do not yet carry command IDs or explicit cause links.

## Verification

From the Alicorn checkout, run `tools/check.ps1` and `odin test native/sdl_gpu`.

From Scope, run `odin check . -collection:alicorn=../alicorn` and `odin test frontend -collection:alicorn=../alicorn`. The frontend tests cover fuzzy subsequence matching, result ordering/clamping, and command availability.
