# BBrbx

**Blender ⇄ Roblox Studio for rigs and animations.** Edit a weapon or viewmodel rig freely in Blender and push it to Studio in one click. Import every action at once, upload a batch to your group, and let Studio tell you when it plays something differently from Blender.

BBrbx is a fork of [RBXMonkey](https://github.com/Cautioned/Blender-Animations-Plugin) 3.1.3. It replaces the official add-on and Studio plugin and uses the same port (31337), so your existing `.blend` files and rigs keep working.

> Blender **4.2+** (developed and tested on 5.3) · Roblox Studio · GPL-3.0, like the original

---

## Contents

- [Highlights](#highlights)
- [Install](#install)
- [Import every action from Blender](#import-every-action-from-blender)
- [Upload](#upload)
- [Edit the rig in Blender](#edit-the-rig-in-blender)
- [Meshes that bend](#meshes-that-bend)
- [Resize a weapon without redoing the animation](#resize-a-weapon-without-redoing-the-animation)
- [When something plays differently](#when-something-plays-differently)
- [Where to find everything](#where-to-find-everything)
- [What is different from RBXMonkey](#what-is-different-from-rbxmonkey)
- [Limits](#limits)
- [Building from source](#building-from-source)
- [Credits](#credits)

---

## Highlights

| | |
|---|---|
| **Synchronise** | Bones you add or move in Blender appear in Studio as Motor6Ds and Bones with the exact same rest. From then on they export 1:1, with no guessed axes. |
| **Bulk import and upload** | Pick any number of actions and import each one into AnimSaves. Upload a batch to yourself or a group, keep asset IDs, and get an `AnimationIds` module. |
| **Import check** | After every import Studio compares joint poses with Blender and warns only when something is off, naming the joint and the fix. |
| **Weapon scale** | Scale the weapon bone in your animation and click Synchronise. The weapon grows in Blender and in Studio, and every animation follows. |
| **Meshes that bend** | Straps, strings and cables: Export Deform FBX, Import 3D, Append deform mesh. |
| **Only what moves a part** | Helpers, IK targets and controls stay in Blender. There is nothing to toggle. |

---

## Install

1. Download `BBrbx-x.y.z-blender.zip` and `BBrbx-x.y.z-studio.rbxm` from [Releases](../../releases).
2. **Blender:** in Edit → Preferences → Add-ons, uninstall "RBXMonkey - Roblox Importer/Exporter" (and the old "RBXMonkey Bulk Actions" if you have it). Then go to **Get Extensions → ⌄ (top right) → Install from Disk…** and pick the zip. The Studio link server starts with Blender.
3. **Studio:** put the `.rbxm` in `%LOCALAPPDATA%\Roblox\Plugins` and disable the official RBXMonkey plugin in Plugins → Manage Plugins. Restart Studio.
4. Open a `.blend` with your rig. Studio connects by itself, and the plugin header shows **Blender :31337**.

---

## Import every action from Blender

**Import/Export → Import Animation**

1. Tick the actions you want, or **All**. The list refreshes by itself when Blender restarts or opens another file, and the corner icon refreshes it by hand.
2. Optionally open **Import options** to set the default priority, loop and whether same-named saves are replaced.
3. Click **Import selected actions**. Each action lands in the rig's AnimSaves as its own animation.

Overwritten saves are copied to `ServerStorage/BBrbx_AnimBackups` first.

**Back to Blender:** play an animation in Studio and click **Export Animation → Send to Blender**. It arrives as an action with the same name, and an older action of that name is kept as "… (before Studio)".

## Upload

**Play/Upload → Save / Upload**

1. Tick saves under **Local saves (AnimSaves)**, or **All**.
2. In **Upload options**, pick yourself or a group under **Upload to** (groups where you can upload).
3. Keep **Keep the same asset ID when re-uploading** on when you update existing animations. Turn on **Write an AnimationIds ModuleScript** to get a name → id map you can `require`.
4. Click **Upload selected**. A folder of Animation objects is created and no extra copy goes into AnimSaves.

## Edit the rig in Blender

Add a bone (a laser, a sight, a bolt), move a joint in Edit Mode, or recreate a part you deleted in Studio. Then click **Import/Export → Synchronise Rig → Synchronise** in Studio.

- Missing Motor6Ds and Bones are created and moved rests are updated. Ctrl+Z undoes it in one step.
- Only bones that move a part go to Roblox: bones from Roblox, bones with weights on a skinned mesh, and bones that carry a mesh. Helpers, IK targets and controls never go.
- Interpolation set on a helper (Constant, Linear, Bezier) carries over to the bone it moves.
- A bone hung under a helper is measured from its nearest ancestor that exists in Roblox.
- Renaming bones is safe, because channels keep their Roblox name. A Shift+D copy does not overwrite the original.
- **Generate / rebuild armature** has **Keep my bones**, which keeps your bones, weights, constraints and actions.

## Meshes that bend

For straps, bow strings and cables skinned to bones:

1. Blender: **BBrbx → Export → Export Deform FBX**. The file is saved next to the `.blend`.
2. Studio: **Home → Import 3D** with default settings.
3. Studio: **Synchronise Rig → Append deform mesh**. Scale, the nested AnimationController, the rest pose and the bone parenting are handled for you.

Animations of these rigs skip poses Roblox would play anyway. A TAC50 with a strap goes from 3,416 poses to 352 per action and looks the same.

## Resize a weapon without redoing the animation

The weapon is too small next to the arms, but the animation is done:

1. In Pose Mode, scale the weapon bone (for example `Handle`). A key or a plain value both work, in any action. Akimbo guns can each get their own scale.
2. Click **Synchronise** in Studio. The biggest scale of each bone across all frames and actions is used, or the smallest if the bone was only shrunk.

The weapon grows in Blender and in Studio: parts, meshes, joints, attachments and bones. Moves inside the weapon (magazine, bolt) scale with it in every action, including saved animations in Studio (backed up first). The weapon's own motion in the hand stays the same, and the scale keys are removed because the size now lives in the rig.

- Save the `.blend` first if you want the version before scaling.
- A scale that drops to 0 and back (hiding a magazine) is ignored.
- Animations you already published need to be uploaded again.

## When something plays differently

- Read the **Import check** warning above the player. It names the joint, how far off it is in studs or degrees, and what to do.
- A different rest means **Synchronise**. A skinned mesh means re-export and **Append deform mesh**.
- Select a rig or a whole folder and click **Scan for issues** (nested AnimationController or Humanoid, missing PrimaryPart, duplicate bone names), then **Fix issues**.
- In Blender, **Utility → Rig check** gives a one-line rig status, and the active bone shows its rotation and position in Roblox axes.

---

## Where to find everything

**Studio, BBrbx plugin**

| Tab | What is there |
|---|---|
| Import/Export | Import Animation, Synchronise Rig (Synchronise, Append deform mesh, Scan / Fix issues), From file or clipboard, Export Rig, Export Animation, Export bone toggles |
| Play/Upload | Saved animations under the player, Camera, Save / Upload, Bone toggles |
| Extras | Weapon, Markers, Animation modifiers |
| Settings | Auto-connect, port, import sources, reduced motion |

**Blender, sidebar (N) → BBrbx**

| Panel | What is there |
|---|---|
| Header | Studio status, port, armature |
| Import | Rig .rbxm, Rig setup (Generate / rebuild, Keep my bones), animation from .fbx, Map from active rig, legacy .obj |
| Export | Bake without Studio (full range, to clipboard, to file), Export Deform FBX |
| Utility | Show weld bones, Rig check, Auto deform scale, active bone status and Roblox values |
| Advanced | Rig helpers (constraints, center of mass), Face, Validation, Account, About |

---

## What is different from RBXMonkey

| | RBXMonkey 3.1.3 | BBrbx |
|---|---|---|
| Connecting | Tries a few times at start, then gives up | Connects whenever Blender runs, notices when it goes away, reconnects |
| Importing actions | One timeline at a time | Any number of actions, each into AnimSaves |
| Upload | Not in the plugin | Batch upload, groups, kept IDs, `AnimationIds` module |
| Bones added in Blender | Axes guessed (a fixed 180° turn), fixed by hand in Studio | Synchronise creates them in Studio and they export exactly |
| Helpers and controls | Sent as channels | Never sent |
| Skinned meshes | No path to Roblox | Export Deform FBX + Append deform mesh |
| Wrong weapon size | Re-export the rig, lose the animations | Scale the bone, Synchronise |
| Checking an import | By eye | Automatic import check, Rig Doctor, Rig check |
| Studio → Blender | Bones without inherited rotation, bones under helpers and bones driven by constraints came back off | Come back where Studio has them |
| Overwriting saves | Lost | Backed up |
| Layout | Player / Rigging / Tools / More | Import/Export, Play/Upload, Extras, Settings, collapsible bone tree |

There is a longer list, in Polish, in [README_BBrbx.md](README_BBrbx.md).

---

## Limits

- **Roblox does not animate scale.** A bone's scale becomes a fixed size on Synchronise.
- **IK chains** coming back from Studio are still set by their IK. Studio has no IK target, so the target stays at rest.
- **A helper of a resized weapon that hangs outside the weapon** (for example on HumanoidRootPart) is exact only where the weapon is at rest. Helpers under the weapon are always exact.
- **Changes to the Studio plugin** load after a Studio restart.

---

## Building from source

- `build_plugin.bat [--install]` builds the Studio plugin with Rojo (`plugin.project.json`).
- `python tools/bb/build_addon.py` builds the Blender extension zip into `build/`.
- `lune run tools/bb/luau_check.luau` compiles every plugin file.
- Add-on tests run from the repo without installing:
  `blender -b --factory-startup --python tools/bb/blender_bootstrap.py -- unittest:test_rest_contract`
- Do not install the add-on with `blender --factory-startup -c extension install-file …`. Installing saves preferences, and with `--factory-startup` that overwrites yours with the defaults.

---

## Credits

Based on **RBXMonkey (Blender Animations Plugin)** by Cautioned: [github.com/Cautioned/Blender-Animations-Plugin](https://github.com/Cautioned/Blender-Animations-Plugin). Licensed under GPL-3.0, and BBrbx is released under the same license.
