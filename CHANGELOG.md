## [1.0.0] 2026-07-05

### Changed

- Admin menu
  - There are now separate menu items for the ban and unban actions.
  - Ban and unban actions only list targetable players which are currently
    unbanned or banned respectively.
- Admin commands
  - `sm_banspray` and `sm_unbanspray` open a menu when they are invoked with no
    arguments.
  - `sm_banspray_steamid` accepts "allowed" or "banned" instead of "0" or "1" in
    its second argument.
- Console variable renames
  - `sm_bannedsprays_remove` to `sm_bannedsprays_autoremove`
  - `sm_bannedsprays_tmploc` to `sm_bannedsprays_delete_loc`
  - `sm_bannedsprays_tracedist` to `sm_bannedsprays_targeting_radius`
  - `sm_bannedsprays_protection` to `sm_bannedsprays_occlusion_radius`
  - `sm_bannedsprays_auth` to `sm_bannedsprays_assume_banned`

### Added

- Admin menu
  - An item to delete sprays
- Chat commands
  - The `!spray` chat user command to view spray information.
- Console variables
  - `sm_bannedsprays_adminflag_ban` controls which admins may ban or unban
    sprays. This defaults to the ban permission flag ('c').
  - `sm_bannedsprays_adminflag_delete` controls which admins may delete sprays.
    This defaults to the kick permission flag ('d').

### Removed

- Admin commands
  - `sm_banspray_list` (this information is available in the admin menu now)
- Console variables
  - `sm_bannedsprays_display`
  - `sm_bannedsprays_warntype`
  - `sm_bannedsprays_tracerate`
  - `sm_bannedsprays_debug`
- Dependencies
  - multicolors

## [0.5.3] 2026-01-28

### Fixed

- A bug where the Steam ID was cut off by one character.

## [0.5.2] 2026-01-28

### Changed

- Updated plugin information.
- Removed unused code.

### Fixed

- Fixed multiple prototype mismatch errors.

## [0.5.1] 2026-01-27

### Changed

- Updated to new indeterminate array syntax.

## [0.5.0] 2026-01-27

### Changed

- Updated code to transitional syntax.

## [0.4.6] 2026-01-27

### Changed

- Cleaned up CVars for readability.

## [0.4.5] 2026-01-27

### Removed

- Old regex for Steam2 AuthId.

## [0.4.4] 2026-01-27

### Changed

- Changed AuthID verification to SteamID64.

## [0.4.3] 2026-01-27

### Changed

- Replaced deprecated GetClientAuthString

## [0.4.2] 2026-01-27

### Fixed

- Fixed array length logic error.

## [0.4.1] 2026-01-27

### Removed

- Additional unused code.

## [0.4.0] 2026-01-27

### Removed

- Includes autoexecconfig and updater.

## [0.3.8] 2015-01-21

### Fixed

- CVar description for sm_bannedsprays_version

## [0.3.7] 2013-11-23

### Added

- Spray protection (code credit to MasterOfTheXP) (https://forums.alliedmods.net/member.php?u=152150)

## [0.3.6] 2013-10-24

### Added

- LogAction functionality.

## [0.3.5]

### Added

- Updater functionality.
- AutoExecConfig include.

## [0.3.4] 2013-09-30

### Added

- Command to perform offline spray bans with SteamID sm_banspray_steamid
- Lateload function.
- Translation file for phrases.
- REGEX to validate SteamID

### Changed

-	Switched from colors.inc to morecolors.inc

## [0.3.3] 2013-06-20

### Changed

- Command from `sm_removespray` to `sm_deletespray`.

## [0.3.2] 2013-06-17

### Added

- Added command "sm_removespray" to remove spray without banning sprays.  Either aim at a spray and use the command or provide a player's name and the spray will be removed.

## [0.3.1] 2013-06-12

### Added

- option to turn on spray tracing so when aiming at spray it will display who sprayed it including their name, steamID, and time sprayed.  All controlled with CVars.

## [0.3.0] 2013-06-08

### Added

- CVar to allow or restrict sprays before client(s) authorized.
- Ability to remove any sprays a player sprayed if they're banned.

## [0.2.0] 2013-02-07

### Added

- CVar `sm_banspray_list` for admins to check if anyone connected to the server is banned from using sprays.

## [0.1.0]

- Initial beta release.
