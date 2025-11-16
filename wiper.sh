#!/usr/bin/env bash

set -e

fn_usage() {
    cat << EOF
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

EOF
    exit 0
}

fn_main() {
    fn_parse_params "$@" 
    fn_setup_colors
    fn_dependensies
    fn_init_devices
    fn_check_support
    fn_frozen
    fn_init_wipe
    fn_confirmation
    [[ $wipefs -eq 1 ]] && fn_wipefs
    fn_wipe
    [[ $blkdiscard -eq 1 ]] && fn_blkdiscard
    [[ $verify -eq 1 ]] && fn_verify
}
fn_dependensies () {
    local deps=(
        "nvme"
        "hdparm"
        "pv"
        "od"
        )

   fn_status_msg info "Checking dependencies..."
    for dep in ${deps[@]}; do
        type $dep >/dev/null 2>&1 || { fn_status_msg warn "I require $dep but it's not installed."; local failed=1; }
    done
    [[ $failed -ne 1 ]] && echo -e "OK\n" || { fn_status_msg err "Install the above and rerun this script. Aborting"; }
}

fn_parse_params() {
    [[ $# -eq 0 ]] && fn_usage

    #Set defults
    assume_yes=0
    wipefs=0
    blkdiscard=0
    force=0
    verify=1
    except=()
    devices=()
    
     while :; do
        case "${1-}" in
            -y|--yes|--assume-yes)
            assume_yes=1
            ;;
            -l|--list)
            list=1
            ;;
            -a|--all)
            all=1
            ;;
            -f|--force)
            force_mode="$2"
            shift
            ;;
            -s|--skip-verify)
            verify=0
            ;;
            -x|--except)
            except+=("$2")
            shift
            ;;
            -d|--device)
            devices+=("$2")
            shift
            ;;
            -w|--wipefs)
            wipefs=1
            ;;
            -b|--blkdiscard)
            blkdiscard=1
            ;;
            -*|--*)
            echo "Unknown option: $1"
            fn_usage
            exit 1
            ;;
            *)
            break
            ;;
        esac
        shift
    done
}
    
fn_setup_colors() {
    ANSI_RED="\033[0;31m"
    ANSI_AQUA="\033[38;5;44m"
    ANSI_YELLOW="\033[0;33m"
    ANSI_LT_AQUA="\033[38;5;30m"
    ANSI_ERROR="\033[1;37;41m"
    ANSI_RESET="\033[m"
}

fn_status_msg() {
    case $1 in
        ok)
        echo -e "[$ANSI_LT_AQUA \U2713 ok $ANSI_RESET] $2"
        ;;
        err)
        echo -e "[$ANSI_RED \U2718 error $ANSI_RESET] $ANSI_ERROR $2 $ANSI_RESET"
        ;;
        warn)
        echo -e "[$ANSI_YELLOW \U26A0 warning $ANSI_RESET] $2"
        ;;
        imp)
        echo -e "[$ANSI_AQUA ! important $ANSI_RESET] $2"
        ;;
        info)
        echo -e "[$ANSI_LT_AQUA info $ANSI_RESET] $2"
        ;;
        *)
        echo -e "$1 $2"
    esac
}

fn_confirmation() {
    echo -n "Are you sure you want to wipe: ${devices[@]}? [y/N]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [[ "$answer" == "" || "$answer" != "${answer#[Nn]}" ]]; then
            fn_status_msg err "Aborted."
            exit 0
        fi
    else
        echo -e
    fi
}

fn_prog_bar() {
    local progress=$(($1*100/$2))
    printf '['
    if [[ $progress -gt 0 ]]; then
        printf '%.s#' $(seq $progress)
    fi

    if [[ $progress -lt 100 ]]; then
        printf '%.s ' $(seq $((100-$progress)))
    fi
    printf '] '
    printf "$progress%%"
    printf "\r"
}

fn_init_devices() {
    if [[ ${#devices[@]} == 0 ]] && [[ -n $list ]] && [[ -z $all ]]; then
        lsblk -d -o NAME
        exit 0
    fi
    if [[ -n $all ]] && [[ ${#devices[@]} == 0 ]]; then
        mapfile -t devices <<< $(lsblk -d -o NAME)
        unset 'devices[0]'
    fi
}

fn_check_support() {
    declare -Ag modes
    declare -Ag function
    for device in ${devices[@]}; do
         
        if [[ "$device" == "nvme"?* ]]; then
            function[$device]="fn_nvme"
            local features
            features="$(nvme id-ctrl -H /dev/$device)" 
        elif [[ "$device" == "sd"? ]]; then
            function[$device]="fn_ssd"
            local features
            features="$(hdparm -I /dev/$device)"
        else
            echo "Wrong device type $device"
            exit 1
        fi
        echo "SUPPORTED MODES FOR [$device]:"   
        case "$features" in 

            # Sanitize ssd & nvme
            # SSD FEATURE SET | NVME FEATURE SET
            *CRYPTO_SCRAMBLE_EXT* | *"Crypto Erase Sanitize Operation Supported"* )
            echo "[4] Sanitize Crypto Scrable supported"
            modes[$device]+=4
            ;;&

            *"OVERWRITE_EXT"* | *"Overwrite Sanitize Operation Supported"* )
            echo "[3] Sanitize Overwrite supported"
            modes[$device]+=3
            ;;&

            *"BLOCK_ERASE_EXT"* | *"Block Erase Sanitize Operation Supported"* )
            echo "[2] Sanitize Block Erase supported"
            modes[$device]+=2
            ;;&

            # nvme Secure erase (nvme format)
            *"Crypto Erase Supported"* )
            echo "[1] Crypto Erase Supported as part of Secure Erase"
            modes[$device]+=1
            ;;&

            *"Format NVM Supported"* )
            echo "[0] Format Supported"
            modes[$device]+=0
            ;;&

            # SSD Security erase
            *"ENHANCED SECURITY ERASE UNIT"* )
            echo "[1] Enhanced Security erase supported"
            modes[$device]+=1
            ;;&

            *"SECURITY ERASE UNIT"* )
            echo "[0] Security erase supported"
            modes[$device]+=0
            ;;

        esac
        if [[ -z ${modes[$device]} ]]; then
            fn_status_msg warn "No supported modes."
            local failed+=( "$device" )
        fi
        echo -e
    done
    [[ -z $failed ]] || fn_status_msg err "The drive(s): ${failed[*]} failed"
    [[ -z $list ]] || exit 0
}

fn_init_wipe() {
    declare -Ag mode
    declare -Ag method
    for device in ${devices[@]}; do
        if [[ -n $force_mode ]] && [[ ${modes[$device]} == *${force_mode}* ]]; then
            fn_status_msg info "Forcing mode [$force_mode] on ${device}"
            mode[$device]="$force_mode"
        elif [[ -n $force_mode ]]; then
            fn_status_msg warn "Mode [$force_mode] not supported by ${device}"
            failed+=( ${device} )
        else
            if [[ ${failed[@]} != *${device}* ]]; then
                for i in ${except[@]}; do
                    modes[$device]="${modes[$device]/$i}"
                done
                case ${modes[$device]} in
                    *4*) mode[$device]=4 ;;
                    *3*) mode[$device]=3 ;;
                    *2*) mode[$device]=2 ;;
                    *1*) mode[$device]=1 ;;
                    *0*) mode[$device]=0 ;;
                    *) failed+=( "${devices[$i]}" ) ;;
                esac
                fn_status_msg info "Using using mode [${mode[$device]}] on $device"

               
            fi 

        fi
        case ${mode[$device]} in
            2|3|4)
            method[$device]="sanitize"
            echo "here"
            ;;
            0|1)
            method[$device]="erase"
            echo "here2"
        esac
    done
    [[ -z $failed ]] || fn_status_msg err "The drive(s): ${failed[*]} failed"
    source methods.sh
}

fn_wipe() {
    for device in ${devices[@]}; do
       "${function[$device]}_${method[$device]}" "$device" "${mode[$device]}" ##eg. fn_nvme_sanitize nvme0 4
    done
}

fn_frozen() {
    for device in ${devices[@]}; do
        if [[ "$device" == "sd"? ]]; then
            i=1
            times=5
            local status="$(hdparm -I /dev/$device)"
            while :; do
                if [[ $status == *"not"?"frozen"* ]]; then
                    fn_status_msg ok "Not Frozen"
                    break
                elif [[ $status == *"frozen"* ]]; then
                    fn_status_msg err "Frozen"
                    fn_status_msg info "Trying to unfreeze, going to sleep"
                    sleep 1
                    rtcwake -m mem -s 5
                fi
                if [[ $i -gt $times ]];then
                    echo -n "Tried unfreezing $device $i times: Continue? [Y/n]: "
                    read answer < /dev/tty
                    i=0
                    if [[ "$answer" != "${answer#[Nn]}" ]]; then
                        fn_status_msg warn "Aborted."
                        exit 0
                    fi
                fi
            ((i++))
            done
        fi
    done
}

#Optional methods to run in addition to the main versions.
fn_wipefs() {
    for device in ${devices[@]}; do
        wipefs -fa "/dev/$device"
    done
}

fn_blkdiscard() {
    for device in ${devices[@]}; do
        blkdiscard "/dev/$device"
    done
}

##The different methods for wiping the discs follow
fn_nvme_sanitize() {
    nvme sanitize -a $1 /dev/$device
    exit
    echo "Sanitizing /dev/$2:"
    while :; do
        local STATUSCODE=$(nvme sanitize-log /dev/$2 | grep -oP '.*SSTAT\) :  \K(.*)')
        local PROGRESS=$(nvme sanitize-log /dev/$2 | grep -oP '.*SPROG\) :  \K(.*)')

        if [[ $PROGRESS -le 65535 && $STATUSCODE == "0x1" ]]; then
            fn_prog_bar "$PROGRESS" "65535"
        elif [[ $STATUSCODE == "0x101" ]]; then
            echo "Drive /dev/$2 successfully sanitized($STATUSCODE)"
            break
        else 
            echo "Error($STATUSCODE)"
            break
        fi
    done
}

fn_nvme_erase() {
    local ses=$2+1
    nvme format "/dev/$1" -n 0xffffffff -ses="$ses"
}

fn_ssd_sanitize() {
    local arg
    case $2 in
        4)
        arg="--sanitize-crypto-scramble"
        ;;
        3)
        arg="--sanitize-overwrite-passes 1 --sanitize-overwrite hex:11111111"
        ;;
        2)
        arg="--sanitize-block-erase"
        ;;
    esac    
    hdparm --sanitize-status "/dev/$1"
    hdparm --yes-i-know-what-i-am-doing "$arg" "/dev/$1"
    hdparm --sanitize-status "/dev/$1"
}

fn_ssd_erase() {
    # spinner frames
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    local arg

    case $2 in
        1)
        fn_status_msg info "Running Enhanced Security Erase on $1"
        arg="--security-erase-enhanced"
        ;;
        0)
        fn_status_msg info "Running Security Erase on $1"
        arg="--security-erase"
        ;;
    esac
    fn_status_msg info "Setting password \"p\" on $1"
    hdparm --user-master u --security-set-pass p /dev/$1 >> /dev/null
    (   
        fn_status_msg info "Erasing $1"
        hdparm --user-master u --security-erase p /dev/$1 >> /dev/null
        echo -e
    ) &
    local pid=$!

    while kill -0 $pid 2>/dev/null; do
        printf "\r%s" "${spinner:i++%${#spinner}:1}"
        sleep 0.05
    done
    printf "\r"

    # capture exit status
    wait "$pid"
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        fn_status_msg err "Security erase failed. Exit code: $exit_code"
        exit 1
    fi
    fn_status_msg info "Unlocking $1 with password \"p\""
    hdparm --user-master u --security-unlock p /dev/$1 >> /dev/null
}
fn_verify() {
        for device in ${devices[@]}; do
            fn_status_msg info "Verifying $device"
            #dd if=/dev/$1 bs=8192 status=progress | hexdump
            pv -tpreb /dev/sda | od
            #cmp -i 100 /path/to/block-device /dev/zero
            #dd if=/path/to/block-device bs=1 skip=100 | cmp - /dev/zero
        done
}

fn_main "$@"
