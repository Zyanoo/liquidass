# Liquid (Gl)ass
This tweak is incomplete, issues WILL happen.

> ok so ive seen that post where OP used the liquidglasskit to for the liquid glass effects. cool i guess. so i decide to release my incomplete unstable buggy unoptimized liquid glass tweak today, also because i dont have enough free time to develop it fast enough anyways. 
>
> i am also researching something pretty advanced (true backdrop sampling instead of relying on snapshots) so if the results are great then it will be 90% true to real liquid glass + applicable inside any app.
>
> contributions to this tweak are welcomed.

this tweak compared to that LiquidGlassKit based tweak is missing a lot of things including:
- music player
- passcode buttons
- control center
- etc i havent even tried that tweak out yet

## Quick explanation on how this tweak works
- right now the tweak takes an image of certain screen views then feed it to a Metal renderer, then draw the masked glass effect on top on the views (`LiquidGlassView`)
- for iOS 15 and lower it usually uses the cpbitmaps in /var/mobile/Library/SpringBoard/ for the wallpaper and sometimes fallback to snapshotting the static wallpaper view (SBFStatic... smth i forgot)
- iOS 16 posterboard is pretty problematic so sometimes it works sometimes it doesnt and everything is black
- display link and origin updates keep the glass aligned with the moving UI BUT it usually does not regenerate the underlying source image every frame, mostly moves the sampling/origin math around the existing captured texture.

## The Metal shader
- samples a blurred version of the source texture as the base body of the glass
- computes how far each fragment is from the nearest edge of the glass shape
- near the bezel, it applies stronger UV displacement using Snell's law (read https://en.wikipedia.org/wiki/Snell%27s_law) for the refraction
- got specular highlight

## so tf am i gonna do with this tweak now?
as you read the quote above (from my reddit post), im researching a way to get true backdrop sampling instead of faking it with laggy ass snapshots. the current approach is too CPU-bound, data getting constantly moved between the CPU and GPU which sucks ass.

### contributions to this tweak are welcome
