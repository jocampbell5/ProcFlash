# ProcAlert

A WoW Forever addon that shows an icon the moment a proc is up, and nothing the rest of the time.
No icon means there's nothing to react to. When the icon appears, press that button.

| Class   | Watches |
|---------|---------|
| Warrior | **Overpower** (after the target dodges), **Revenge** (after you block, dodge or parry), **Execute** (target under 20%) |
| Hunter  | **Mongoose Bite** (after the target dodges), **Counterattack** (after you parry) |
| Rogue   | **Riposte** (after you parry) |
| Druid   | **Clearcasting** from Omen of Clarity (next spell is free) |
| Mage    | **Clearcasting** from Arcane Concentration |
| Shaman  | **Clearcasting** from Elemental Focus |
| Warlock | **Shadow Trance** from Nightfall (next Shadow Bolt is instant) |

Moves only show when you can actually press them: you know the move, you're in the right stance,
you have the rage, it's off cooldown, and you have a live enemy targeted. A red-tinted icon means the
target is out of reach. The proc's name shows under its icon in silver. Every proc shows in the same spot; if two happen to be up at once,
the one listed first above shows.

Other classes, and characters without any of these, see nothing.

## Setting it up

Type `/proc`. The ProcAlert window opens, and a blue box with an icon appears on screen.

- **Move it:** drag the blue box.
- **Size:** use the slider, or scroll the mouse wheel over the box.
- **Which procs:** untick any you don't want.
- **Sound:** tick it to hear a sound when an icon appears.
- **Reset position** puts it back in the middle at the normal size.

Click **Done** (or press Esc) and the box locks. From then on the icons only appear when a proc is
up, and clicks go through them to the game. Edit Mode (Esc > Edit Mode) shows the box too.

Typed commands do the same things:

| Command | Does |
|---------|------|
| `/proc` | open or close the window |
| `/proc help` | what it's watching, and these commands |
| `/proc size 64` | icon size in pixels (16–200, normally 48) |
| `/proc sound` | sound on or off |
| `/proc revenge` | turn one off or back on (any name from the table) |
| `/proc reset` | back to the middle of the screen at the normal size |
| `/proc move`, `/proc lock` | move the box without the window |
| `/proc debug` | what the game reports for each proc, if one isn't showing when it should |

The position and settings are shared by all your characters.

## Install

Copy the `ProcAlert` folder into `World of Warcraft\_forever_\Interface\AddOns`.

## Tests

`python tests/test_procalert.py` runs the addon against a fake game (needs `pip install lupa`).
