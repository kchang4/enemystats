# Enemy Stats - Ashita v4 Addon

An Ashita v4 addon for Final Fantasy XI that displays detailed enemy statistics including combat stats, resistances, and your calculated hit rate.

## Features

- **Real-time Enemy Stats**: Shows mob ATK, DEF, EVA, HP, and level
- **Hit Rate Calculation**: Displays your accuracy vs enemy evasion with color-coded hit rate percentage
- **Dual Wield / H2H Support**: Shows both main and off-hand accuracy with separate hit rates
- **Auto-refresh ACC**: Automatically updates your accuracy when gear or buffs change
- **Gear Set Caching**: Remembers ACC values for gear sets you've used before for instant display
- **Resistance Display**: Shows physical and elemental weaknesses/resistances
- **Detection Icons**: Visual indicators for aggro type (sight, sound, scent, magic, true sight)
- **Claim Status**: Color-coded mob names (yellow=unclaimed, red=your claim, purple=others)

## Installation

1. Copy the `enemystats` folder to your Ashita `addons` folder
2. Load the addon: `/addon load enemystats`

## Commands

| Command | Description |
|---------|-------------|
| `/enemystats show` | Show the window |
| `/enemystats hide` | Hide the window |
| `/enemystats refresh` | Manually update ACC/ATT/EVA/DEF |
| `/enemystats status` | Show current tracking status |
| `/enemystats debug` | Toggle debug prints on/off |

## How It Works

### Accuracy Tracking
The addon uses `/checkparam` to get your real accuracy value from the server. This includes ALL modifiers:
- Equipment stats
- Food buffs
- Job abilities and traits
- Party buffs (Madrigal, etc.)
- Mythic/Relic/Empyrean aftermath effects

When your gear or buffs change, the addon automatically refreshes your stats.

### Hit Rate Formula
Uses the standard FFXI formula:
```
Hit Rate = 75 + floor((ACC - EVA) / 2)
Clamped to 20% minimum, 95% maximum
```

### Color Coding
- 🟢 Green: 90%+ hit rate
- 🟡 Yellow: 80-89% hit rate  
- 🔴 Red: Below 80% hit rate

## Database

The addon uses a local database of mob stats derived from server data. Stats are calculated based on:
- Mob family base stats
- Level scaling
- Mob modifiers (NM bonuses, etc.)

## Requirements

- Ashita v4
- Final Fantasy XI (works with retail and private servers)

## Credits

- **Author**: Antigravity
- Mob database derived from LandSandBoat server data

## License

MIT License
