# scrap-mechanic-skip-drillbot

Skip most of the Drillbot boss train fight while keeping other parts of the quest sequence intact and fully playable. Fully tested on patch 1.0.6.

## Install instructions
1. Ensure that the game is shut down.
2. Go into the game files: `[Your Steam download folder]\steamapps\common\Scrap Mechanic\Survival\Scripts\game\managers` (right-click on the game in the library -> Properties... -> Installed Files -> Browse..., then navigate into Survival -> Scripts -> game -> managers).
3. Inside `\steamapps\common\Scrap Mechanic\Survival\Scripts\game\managers`, rename `DrillbotManager.lua` to `DrillbotManager.lua.original` (in other words, add `.original` at the end) - this will allow you to easily remove the modification in the future.
4. Download `DrillbotManager.lua` from this repository, and put it into `[Your Steam download folder]\steamapps\common\Scrap Mechanic\Survival\Scripts\game\managers` (replacing the now renamed original).
5. In Steam, add the command line argument `-dev` (right-click on the game in the library -> Properties... -> General -> Launch Options -> In the field under, add `-dev`).

## Boss instructions
6. Launch the game. It might take longer to launch.
7. Load your save, start the quest, and start the train normally.
8. The Drillbot will not attack you. The only possible way of dying is not getting off the platform quickly enough after hammering the Drillbot (see below).
9. Wait for the animation of the 1st stage to finish. Hammer the Drillbot until it's invulnerable.
10. Run to the 2nd platform.
11. Wait for the animation of the 2nd stage to finish. Hammer the Drillbot until it's invulnerable.
12. Run to the 3rd platform.
13. Wait for the animation of the 3rd stage to finish. Hammer the Drillbot until it's invulnerable.
14. Run to the last, smaller platform. Hammer the Drillbot again.
15. The sequence is finished.
