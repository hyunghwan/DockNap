<img src="Artwork/DockNap.png" alt="DockNap app icon" width="128" height="128">

# DockNap

DockNap is a macOS menu bar app for external drives. Choose the volumes you want it to unmount when your Mac goes to sleep. On wake, DockNap remounts the volumes it successfully unmounted if they are still selected and connected.

## Build and run

Build DockNap on macOS 13 or later with the Xcode Command Line Tools installed. To keep a copy in your Applications folder, run

```sh
./build.sh
mkdir -p ~/Applications
ditto build/DockNap.app ~/Applications/DockNap.app
open ~/Applications/DockNap.app
```

The local build uses ad hoc signing and requires no developer account. Run the coordinator tests with `./test.sh`.

## Choose your volumes

1. Connect your drive and open DockNap from the menu bar.
2. Check each volume you want DockNap to manage. The selection starts empty and is saved between launches. For a drive with several volumes, select each one you want unmounted.
3. Leave DockNap running. To start it automatically after you sign in, choose **Launch at Login**. You can uncheck a saved volume even while its drive is disconnected.

DockNap unmounts each selected volume and leaves the device attached so it can mount the volume again.

When DockNap finishes unmounting the selected volumes and confirms that external storage is clear, a short sound plays just before your Mac sleeps. You can then disconnect the dock. This check covers external storage across the Mac, including drives plugged in through other ports. DockNap stays silent if another external volume is still mounted, if the check is inconclusive, or if there was nothing to unmount.

**Play Unmount Sound** is on by default. Uncheck it in the menu to turn it off. The sound uses your Mac’s current audio output and volume. If you don’t hear it, check the volumes in Finder before unplugging.

On wake, DockNap waits for you to unlock your Mac before it requests a mount. While the screen is locked, macOS can reject a mount request and eject the entire drive. DockNap checks that each selected volume is still on the same connection before restoring it. If your dock cuts power during sleep, macOS can see the returning drive as newly connected and handle mounting itself.

## License

[MIT](LICENSE) © 2026 sqncs studio LLC
