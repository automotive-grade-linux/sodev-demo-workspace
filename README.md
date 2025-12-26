
# sodev-demo-workspace
A tentative workspace for developing the SoDeV demo.

## How to Build

**Prerequisites:** `moulin`, `ninja`

```bash
git clone --recurse-submodules https://github.com/automotive-grade-linux/sodev-demo-workspace
cd sodev-demo-workspace
./build.sh
sudo bmaptool copy --nobmap external/meta-rcar-demo/work_v4hsbc_xen/full.img /path/to/sd/device
```

## How to Boot the Target Board (Sparrow Hawk)

1. Insert the SD card created in the previous step into the board.
2. Connect **two displays** to the board:
   - One via **DisplayPort**
   - One via **MIPI-DSI connector**
3. Access the U-Boot console and set the following environment variables:

```bash
u-boot => setenv bootcmd_xen 'env default -a && env delete bootargs && load mmc 0:1 ${loadaddr} fitImage && bootm ${loadaddr}#default#dt_overlay=r8a779g3-sparrow-hawk-dsi-waveshare-panel.dtbo'
u-boot => setenv bootcmd 'run bootcmd_xen'
u-boot => saveenv
```

4. Reboot the board.


## Planned Action Items

- Replace the Android DomU with an AGL IVI guest image
- Replace the Weston desktop Linux DomU with an AGL IC guest image
- Performance and appearance tuning
