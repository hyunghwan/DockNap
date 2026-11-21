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

DockNap unmounts each selected volume and leaves the device attached so it can mount the volume again. A busy volume can stay mounted. Before physically unplugging a dock, check that all its volumes have finished unmounting.

On wake, DockNap waits for you to unlock your Mac before it requests a mount. While the screen is locked, macOS can reject a mount request and eject the entire drive. DockNap checks that each selected volume is still on the same connection before restoring it. If your dock cuts power during sleep, macOS can see the returning drive as newly connected and handle mounting itself.

## License

[MIT](LICENSE) © 2026 sqncs studio LLC
