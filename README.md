# wiper
Script to automaticly wipe sata and nvme ssds using different tools.

# Dependencies: 
* nvme-cli
* hdparm
* od
* pv

`od` and `pv` can be switched to dd and hexdump by editing [fn_verify](https://github.com/brazier/wiper/blob/main/wiper.sh#L485)
also remember to edit [fn_dependencies](https://github.com/brazier/wiper/blob/main/wiper.sh#L74)

# Usage
Can also be invoked like this:
```
curl -sL https://wiper.004269.xyz | bash -s -- [options]
```
```
Usage: wiper.sh [options]

OPTIONS:
-y, --yes, --assume-yes     Asummes yes to all promts, will format the device without asking!
-l, --list                  List availible modes if used with -d, --device. If used alone list availible devices.
-d, --device <device>       Which device to wipe, can be passed multiple times.
-a, --all                   Wipe all connected devices, use together with -y, --yes for automated.
-s, --skip-verify           Skip verify after wipe.
-w, --wipefs                Additionally run wipefs _before_ the main wiping.
-b, --blkdiscard            Additionally run blkdiscard _after_ the main wipe.
-x, --except <mode>         Do not use a specific mode, usefull for when running with -a, -all. can be passed mulitple times.
-f, --force <mode>          Force a certain (lower) mode, than the highest supported. 
                            Modes:  4: Sanitize Crypto
                                    3: Sanitize Overwrite
                                    2: Sanitize Block Erase
                                    1: Crypto Erase(Secure Erase) / Enhanced Security Erase
                                    0: Format NVM / Security Erase  


Examples:
    List all availible disks
    wiper.sh --list

    List all availible modes for a disk
    wiper.sh --list --device sdx

    Wipe all availible disks without being promted, use higest availible mode other than Sanitize Overwrite, dont verify
    wiper.sh --yes --all --except 3 --skip-verify

    Multiple modes can be skipped
    wiper.sh --yes --all --except 3 --except 4 --except 1
    wiper.sh --yes --all --except 341

Important!
    * Every instance of --except are passed to all devices, position does not matter.
    * If multiple uses of --except ends up with no availible modes, the drive will fail.
    * --device takes precedence over --all.
```

# Roadmap / to-do

 - [ ] Add progressbar to fn_ssd_sanitize()
 - [ ] Add spinner to fn_nvme_erase()
 - [ ] Make the script interactive (maybe by using [bash-tui-toolkit](https://github.com/timo-reymann/bash-tui-toolkit))
 - [ ] Make modes parameter positional so that different modes can be passed to different disks.
 - [ ] Make a better verify, other than a visual human readeable one.


